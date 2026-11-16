import UIKit
import WebKit
import Photos
import PhotosUI
import Vision
import CoreImage
import AVFoundation
import Speech
import MediaPlayer
import UniformTypeIdentifiers

/// Parte do iPhone só do app Mosaico.
/// Recados da página (window.webkit.messageHandlers.mz.postMessage({cmd: ...}) devolve uma resposta):
///   permissao, albuns, fotos, analisar, info, baixarRosto, grade, compor, escolher, apagar, listar, existe, vibrar,
///   cameraLigar, cameraDesligar, vozLigar, vozDesligar
/// Avisos para a página: window.__mzEvento({tipo: 'texto'|'cameraFim'|'voz'|'vozFim', ...})
/// Imagens para a página pelo endereço mzfoto://
///   mzfoto://mini?id=...          miniatura quadrada (64 px) guardada no celular
///   mzfoto://foto?id=...&s=400&m=fill|fit   foto da Fototeca no tamanho pedido
///   mzfoto://arq?n=pasta/nome.jpg arquivo guardado pelo app (rostos, bebês, mosaico pronto)
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply, WKURLSchemeHandler,
                        PHPickerViewControllerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    typealias Resposta = (Any?, String?) -> Void

    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    let fila = DispatchQueue(label: "mosaico.trabalho", qos: .userInitiated)
    var escolhaArquivo: EscolhaArquivo?
    var telaPublica: UIViewController? { tela }
    func arqPublico(_ n: String) -> URL { arq(n) }
    private let filaImg = DispatchQueue(label: "mosaico.imagens", qos: .userInitiated, attributes: .concurrent)
    private let gerente = PHImageManager.default()
    private var parados = Set<ObjectIdentifier>()

    private var cores: [String: [Int]] = [:]   // id -> [r, g, b, boa(1/0)]
    private var coresLidas = false
    private let travaCores = NSLock()

    private var escolhaResposta: Resposta?
    private var escolhaNome = ""
    private var escolhaRosto = false
    private var escolhaVarias = 0, escolhaPasta = ""

    // câmera (leitura de texto)
    private var sessao: AVCaptureSession?
    private let filaCam = DispatchQueue(label: "mosaico.camera")
    private var camGiro = 0
    private var camFim: DispatchWorkItem?

    // microfone (fala)
    private var motor: AVAudioEngine?
    private var pedidoVoz: SFSpeechAudioBufferRecognitionRequest?
    private var tarefaVoz: SFSpeechRecognitionTask?
    private var vozFim: DispatchWorkItem?

    // MARK: ligar ao app
    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "mz")
        config.setURLSchemeHandler(self, forURLScheme: "mzfoto")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
        esconderBarraDoTeclado(webView)
        galeria.urlMini = { [weak self] id in self?.nomeMini(id) ?? URL(fileURLWithPath: "/") }
        galeria.urlArq = { [weak self] n in self?.arq(n) ?? URL(fileURLWithPath: "/") }
        galeria.evento = { [weak self] d in self?.evento(d) }
        galeria.instalar(em: webView)
        volume.aviso = { [weak self] in self?.evento(["tipo": "volume"]) }
        volume.instalar(em: webView)
    }
    private let galeria = GaleriaNativa()
    private let volume = VolumeEspiao()

    /// Tira a barrinha "∧ ∨ OK" que o iPhone põe em cima do teclado (o Notas falso tem a própria barra).
    private func esconderBarraDoTeclado(_ webView: WKWebView) {
        guard let alvo = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }),
              let base = object_getClass(alvo) else { return }
        let nomeNovo = String(cString: class_getName(base)) + "_SemBarra"
        var nova: AnyClass? = NSClassFromString(nomeNovo)
        if nova == nil, let n = objc_allocateClassPair(base, nomeNovo, 0) {
            // em cima do teclado: nada, ou a barrinha do Notas (Aa, lista, tabela, clipe, caneta), que sobe e desce junto com o teclado
            let bloco: @convention(block) (AnyObject) -> AnyObject? = { _ in PonteExtra.barraNotasLigada ? PonteExtra.barraNotas : nil }
            class_addMethod(n, NSSelectorFromString("inputAccessoryView"), imp_implementationWithBlock(bloco), "@@:")
            // o teclado pode abrir sozinho (sem tocar na tela): o Notas falso abre já com o teclado, igual ao de verdade
            for nomeSel in ["_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:",
                            "_elementDidFocus:userIsInteracting:blurPreviousNode:changingActivityState:userObject:"] {
                let sel = NSSelectorFromString(nomeSel)
                guard class_getInstanceMethod(base, sel) != nil else { continue }
                let original = class_getMethodImplementation(base, sel)
                typealias Orig = @convention(c) (AnyObject, Selector, UnsafeRawPointer?, Bool, Bool, UInt64, AnyObject?) -> Void
                let chamar = unsafeBitCast(original, to: Orig.self)
                let foco: @convention(block) (AnyObject, UnsafeRawPointer?, Bool, Bool, UInt64, AnyObject?) -> Void = { eu, no, interagindo, borrar, estado, obj in
                    chamar(eu, sel, no, PonteExtra.tecladoSozinho || interagindo, borrar, estado, obj)
                }
                class_addMethod(n, sel, imp_implementationWithBlock(foco), method_getTypeEncoding(class_getInstanceMethod(base, sel)!))
            }
            objc_registerClassPair(n)
            nova = n
        }
        if let n = nova { object_setClass(alvo, n) }
    }

    static var barraNotasLigada = false
    static var tecladoSozinho = false
    static let barraNotas: UIView = BarraNotasView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 60))

    // MARK: pastas
    private lazy var docs: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var pastaMinis: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("minis")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var arqCores: URL { pastaMinis.appendingPathComponent("cores2.json") }

    private func arq(_ nome: String) -> URL {
        let limpo = nome.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return docs.appendingPathComponent(limpo)
    }

    private func nomeMini(_ id: String) -> URL {
        let seguro = id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return pastaMinis.appendingPathComponent(seguro + ".jpg")
    }

    private func gravar(_ dados: Data, _ url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? dados.write(to: url, options: .atomic)) != nil
    }

    private func evento(_ d: [String: Any]) {
        guard let j = try? JSONSerialization.data(withJSONObject: d), let s = String(data: j, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web?.evaluateJavaScript("window.__mzEvento&&window.__mzEvento(\(s))", completionHandler: nil)
        }
    }

    // MARK: recados da página
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping Resposta) {
        let responder: Resposta = { valor, erro in DispatchQueue.main.async { replyHandler(valor, erro) } }
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else {
            return responder(nil, "recado inválido")
        }
        func txt(_ k: String) -> String { (m[k] as? String) ?? "" }
        func num(_ k: String, _ padrao: Double) -> Double { (m[k] as? NSNumber)?.doubleValue ?? padrao }

        switch cmd {
        case "permissao":
            permissao(responder)
        case "albuns":
            fila.async { responder(self.albuns(), nil) }
        case "fotos":
            let album = txt("album")
            fila.async { responder(self.fotos(album.isEmpty ? nil : album), nil) }
        case "analisar":
            let ids = (m["ids"] as? [String]) ?? []
            fila.async { responder(self.analisar(ids), nil) }
        case "info":
            let id = txt("id")
            fila.async { responder(self.info(id), nil) }
        case "baixarRosto":
            baixarRosto(txt("url"), nome: txt("nome"), responder)
        case "escolherFoto":   // várias fotos candidatas: guarda a mais de frente
            escolherFoto((m["urls"] as? [String]) ?? [], nome: txt("nome"), responder)
        case "telaCobrir":   // congela o que está na tela (a tela de início) por cima de tudo, para trocar por baixo
            telaCobrir(); responder(true, nil)
        case "telaAbrir":    // o app novo cresce do ícone até a tela cheia, por cima da tela de início
            telaAbrir(CGFloat(num("x", 0)), CGFloat(num("y", 0)), CGFloat(num("s", 60)), responder)
        case "telaFechar":   // congela o app na tela (a página troca para a tela de início por baixo)
            telaFechar(CGFloat(num("x", 0)), CGFloat(num("y", 0)), CGFloat(num("s", 60)), responder)
        case "telaFecharVai":   // e agora o app encolhe até o ícone, como no iOS 26
            telaFecharVai(CGFloat(num("x", 0)), CGFloat(num("y", 0)), CGFloat(num("s", 60)))
            responder(true, nil)
        case "pegar":   // texto de um endereço, sem bloqueio de outro site (Inject direto)
            guard let url = URL(string: txt("url")) else { return responder(nil, "endereço inválido") }
            var pedido = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: max(2, num("tempo", 6)))
            pedido.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: pedido) { dados, resp, erro in
                guard let d = dados, let s = String(data: d, encoding: .utf8) else { return responder(nil, erro?.localizedDescription ?? "sem resposta") }
                responder(["status": (resp as? HTTPURLResponse)?.statusCode ?? 0, "texto": s], nil)
            }.resume()
        case "pele":
            let n = txt("nome")
            fila.async {
                guard let im = UIImage(contentsOfFile: self.arq(n).path), let cg = self.normalizar(im, maior: 1600).cgImage else { return responder(NSNull(), nil) }
                responder(self.corDaPele(cg) ?? NSNull(), nil)
            }
        case "grade":
            let nome = txt("nome"), c = Int(num("cols", 40)), l = Int(num("rows", 80)), enq = txt("enq"), real = txt("real")
            fila.async { responder(self.grade(nome, cols: c, rows: l, enq: enq, real: real), nil) }
        case "compor":
            let ids = (m["ids"] as? [String]) ?? []
            let alvo = ((m["alvo"] as? [NSNumber]) ?? []).map { $0.intValue }
            let c = Int(num("cols", 40)), l = Int(num("rows", 80)), px = Int(num("px", 30))
            let modo = txt("modo"), saida = txt("saida"), alfa = CGFloat(num("alfa", 0.3))
            fila.async {
                let ok = self.compor(ids, cols: c, rows: l, px: px, modo: modo, alvo: alvo, alfa: alfa, saida: saida)
                responder(ok, nil)
            }
        case "escolher":
            escolher(nome: txt("nome"), rosto: (m["rosto"] as? Bool) ?? false, responder)
        case "escolherVarias":
            escolherVarias(pasta: txt("pasta"), max: max(1, Int(num("max", 63))), responder)
        case "apagar":
            try? FileManager.default.removeItem(at: arq(txt("nome")))
            responder(true, nil)
        case "existe":
            responder(FileManager.default.fileExists(atPath: arq(txt("nome")).path), nil)
        case "listar":
            let itens = (try? FileManager.default.contentsOfDirectory(atPath: arq(txt("pasta")).path)) ?? []
            responder(itens, nil)
        case "vibrar":
            let f = txt("forca")
            let estilo: UIImpactFeedbackGenerator.FeedbackStyle = f == "forte" ? .heavy : (f == "media" ? .medium : .light)
            let g = UIImpactFeedbackGenerator(style: estilo)
            g.prepare()
            g.impactOccurred()
            responder(true, nil)
        case "cameraLigar":
            cameraLigar(num("segundos", 8), traseira: (m["traseira"] as? Bool) ?? false, responder)
        case "cameraDesligar":
            cameraDesligar(avisar: false)
            responder(true, nil)
        case "vozLigar":
            vozLigar(num("segundos", 7), responder)
        case "volumeAtivar":   // abriu o Fotos / chegou no rosto: confere a escuta do volume e deixa o volume no meio
            if motor == nil { volume.reativar(depois: 0) }
            responder(true, nil)
        case "vozDesligar":
            pararVoz(avisar: false)
            responder(true, nil)
        case "exportar":   // cópia da lista de famosos, Fototeca e bebês
            exportarCopia(dados: txt("dados"), pastas: (m["pastas"] as? [String]) ?? [], nome: txt("nome"), responder)
        case "importar":
            importarCopia(responder)
        case "notasTeclado":   // Notas falso: barrinha grudada no teclado e teclado abrindo sozinho
            PonteExtra.barraNotasLigada = (m["barra"] as? Bool) ?? false
            PonteExtra.tecladoSozinho = (m["sozinho"] as? Bool) ?? false
            responder(true, nil)
        case "lerImagens":   // Post-It: lê a escrita (desenhada pela página em várias inclinações) com o mesmo leitor da câmera
            let imgs = (m["imgs"] as? [String]) ?? []
            let palavras = (m["palavras"] as? [String]) ?? []
            fila.async { responder(self.lerImagens(imgs, palavras), nil) }
        default:
            if !galeria.recado(cmd, m, responder) { responder(nil, "recado desconhecido: \(cmd)") }
        }
    }

    // MARK: abrir e fechar apps como no iPhone (cresce do ícone / encolhe até o ícone)
    private var capaTela: UIView?
    private func janela() -> UIWindow? { web?.window }
    private func telaCobrir() {
        capaTela?.removeFromSuperview(); capaTela = nil
        guard let w = web, let jan = janela(), let foto = w.snapshotView(afterScreenUpdates: false) else { return }
        foto.frame = w.convert(w.bounds, to: jan)
        jan.addSubview(foto)
        capaTela = foto
    }
    private func telaAbrir(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ r: @escaping Resposta) {
        guard let w = web, let jan = janela() else { capaTela?.removeFromSuperview(); capaTela = nil; return r(true, nil) }
        // o app novo já está desenhado por baixo da capa: tira uma foto dele e faz ela crescer do ícone
        guard let novo = w.snapshotView(afterScreenUpdates: true) else { capaTela?.removeFromSuperview(); capaTela = nil; return r(true, nil) }
        let B = w.convert(w.bounds, to: jan)
        novo.frame = B
        novo.layer.masksToBounds = true
        jan.addSubview(novo)
        let k = max(0.05, s / B.width)
        novo.transform = CGAffineTransform(translationX: x - B.midX, y: y - B.midY).scaledBy(x: k, y: k)
        novo.layer.cornerRadius = 0.2237 * s / k
        novo.alpha = 0.4
        r(true, nil)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.curveEaseOut]) {
            novo.transform = .identity
            novo.alpha = 1
        }
        let raio = CABasicAnimation(keyPath: "cornerRadius")
        raio.fromValue = 0.2237 * s / k; raio.toValue = 0; raio.duration = 0.42
        raio.timingFunction = CAMediaTimingFunction(name: .easeOut)
        novo.layer.cornerRadius = 0
        novo.layer.add(raio, forKey: "raio")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            novo.removeFromSuperview()
            self?.capaTela?.removeFromSuperview(); self?.capaTela = nil
        }
    }
    private var velhoTela: UIView?
    private func telaFechar(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ r: @escaping Resposta) {
        velhoTela?.removeFromSuperview(); velhoTela = nil
        // a página (Notas) é desenhada fora do app: a foto precisa ser tirada "depois de atualizar", senão sai vazia
        guard let w = web, let jan = janela(), let velho = w.snapshotView(afterScreenUpdates: true) else { return r(true, nil) }
        velho.frame = w.convert(w.bounds, to: jan)
        velho.layer.masksToBounds = true
        velho.layer.cornerCurve = .continuous
        jan.addSubview(velho)
        velhoTela = velho
        r(true, nil)
        // segurança: se o "vai" não chegar, tira a foto congelada
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak velho] in
            if let v = velho, v === self?.velhoTela, v.layer.animationKeys() == nil { v.removeFromSuperview(); self?.velhoTela = nil }
        }
    }
    /// Fechamento como no iOS 26 (medido quadro a quadro num iPhone):
    /// o app encolhe rápido até o ícone; ali vira o próprio ícone, maior e esticado, que "chacoalha" até o tamanho normal;
    /// a tela de início começa desfocada e um pouco menor, e cresce até o normal.
    private func telaFecharVai(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
        guard let w = web, let jan = janela(), let velho = velhoTela else { return }
        velhoTela = nil
        let B = w.convert(w.bounds, to: jan)
        // tela de início (já trocada por baixo), desfocada
        let fundo = w.snapshotView(afterScreenUpdates: true)
        let desfoque = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        // o ícone de verdade, recortado da tela de início
        let rIcone = CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
        let icone = w.resizableSnapshotView(from: w.convert(rIcone, from: jan), afterScreenUpdates: false, withCapInsets: .zero)
        if let f = fundo {
            f.frame = B
            jan.insertSubview(f, belowSubview: velho)
            desfoque.frame = B
            jan.insertSubview(desfoque, belowSubview: velho)
            f.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)   // a tela de início começa um pouco menor e cresce (medido no iPhone)
        }
        if let ic = icone {
            ic.frame = rIcone
            ic.layer.cornerRadius = 0.2237 * s; ic.layer.cornerCurve = .continuous; ic.layer.masksToBounds = true
            ic.alpha = 0
            ic.transform = CGAffineTransform(translationX: 0, y: s * 0.18).scaledBy(x: 1.3, y: 1.55)
            jan.insertSubview(ic, belowSubview: velho)
        }
        // 1) o app encolhe (rápido no começo, firme no fim), arredondando os cantos
        let k = max(0.05, s / B.width) * 1.25, raioFim = 0.2237 * s * 1.25 / k
        let fim = CGAffineTransform(translationX: x - B.midX, y: y - B.midY + s * 0.18).scaledBy(x: k, y: k * 1.2)
        let dur = 0.32
        UIView.animate(withDuration: dur, delay: 0, options: [.curveEaseIn]) { velho.transform = fim }
        UIView.animate(withDuration: 0.12, delay: dur - 0.1, options: [.curveLinear]) { velho.alpha = 0 }
        let raio = CABasicAnimation(keyPath: "cornerRadius")
        raio.fromValue = 44; raio.toValue = raioFim; raio.duration = dur
        raio.timingFunction = CAMediaTimingFunction(name: .easeIn)
        velho.layer.cornerRadius = raioFim
        velho.layer.add(raio, forKey: "raio")
        // 2) vira o ícone, grande e esticado, que chacoalha até o tamanho normal
        if let ic = icone {
            UIView.animate(withDuration: 0.1, delay: dur - 0.1, options: [.curveLinear]) { ic.alpha = 1 }
            UIView.animate(withDuration: 0.5, delay: dur - 0.04, usingSpringWithDamping: 0.52, initialSpringVelocity: 0.6, options: []) { ic.transform = .identity }
        }
        // 3) a tela de início perde o desfoque e volta ao tamanho normal
        UIView.animate(withDuration: 0.4, delay: dur - 0.08, options: [.curveEaseOut]) {
            fundo?.transform = .identity   // cresce até o tamanho normal
            desfoque.alpha = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.55) {
            velho.removeFromSuperview(); icone?.removeFromSuperview(); desfoque.removeFromSuperview(); fundo?.removeFromSuperview()
        }
    }

    // MARK: permissão e lista de fotos
    private func nomeStatus(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "total"
        case .limited: return "limitado"
        case .denied, .restricted: return "negado"
        default: return "pendente"
        }
    }

    private func permissao(_ r: @escaping Resposta) {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if st == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in r(self.nomeStatus(s), nil) }
        } else {
            r(nomeStatus(st), nil)
        }
    }

    private func soImagens() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0", PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)   // sem prints de tela
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return o
    }

    private func albuns() -> [[String: Any]] {
        var saida: [[String: Any]] = []
        let colecoes = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        colecoes.enumerateObjects { c, _, _ in
            let n = PHAsset.fetchAssets(in: c, options: self.soImagens()).count
            if n > 0 { saida.append(["id": c.localIdentifier, "nome": c.localizedTitle ?? "Álbum", "n": n]) }
        }
        return saida
    }

    private func fotos(_ album: String?) -> [String] {
        let res: PHFetchResult<PHAsset>
        if let a = album, let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [a], options: nil).firstObject {
            res = PHAsset.fetchAssets(in: c, options: soImagens())
        } else {
            res = PHAsset.fetchAssets(with: soImagens())
        }
        var ids: [String] = []
        ids.reserveCapacity(res.count)
        res.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        return ids
    }

    private func info(_ id: String) -> [String: Any] {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return [:] }
        var d: [String: Any] = ["w": a.pixelWidth, "h": a.pixelHeight, "fav": a.isFavorite]
        if let c = a.creationDate { d["data"] = c.timeIntervalSince1970 * 1000 }
        return d
    }

    // MARK: cores médias, miniaturas e filtro (só pessoas e paisagens)
    private func lerCores() {
        if coresLidas { return }
        coresLidas = true
        if let d = try? Data(contentsOf: arqCores),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: [Int]] {
            cores = j
        }
    }

    private let palavrasFora = ["document", "text", "receipt", "screenshot", "paper", "handwriting", "menu", "whiteboard",
                                "blackboard", "computer", "monitor", "screen", "diagram", "chart", "map", "book", "magazine",
                                "newspaper", "poster", "sign", "label", "envelope", "letter", "printed", "calculator",
                                "keyboard", "barcode", "qr", "ticket", "note", "illustration", "drawing", "cartoon", "logo",
                                "graphic", "office_supplies", "tool", "wire", "cable"]

    /// 1 = foto boa para o mosaico (pessoas, paisagens...), 0 = print, documento, texto, objeto
    private func fotoBoa(_ a: PHAsset, _ cg: CGImage) -> Int {
        if a.mediaSubtypes.contains(.photoScreenshot) { return 0 }
        let classes = VNClassifyImageRequest()
        let textos = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([classes, textos])
        var area: CGFloat = 0
        for o in textos.results ?? [] { area += o.boundingBox.width * o.boundingBox.height }
        if area > 0.05 { return 0 }
        for o in classes.results ?? [] where o.confidence > 0.3 {
            let id = o.identifier.lowercased()
            if palavrasFora.contains(where: { id.contains($0) }) { return 0 }
        }
        return 1
    }

    private func analisar(_ ids: [String]) -> [Any] {
        travaCores.lock()
        lerCores()
        var faltam = ids.filter { (cores[$0]?.count ?? 0) < 4 || !FileManager.default.fileExists(atPath: nomeMini($0).path) }
        // já analisadas no formato antigo (só a cor média): os 4 pedaços saem da miniatura guardada, sem ir na Fototeca
        let soQuad = ids.filter { c in (cores[c]?.count ?? 0) >= 4 && (cores[c]?.count ?? 0) < 16 && FileManager.default.fileExists(atPath: nomeMini(c).path) }
        travaCores.unlock()
        if !soQuad.isEmpty {
            var novas: [String: [Int]] = [:]
            for id in soQuad {
                autoreleasepool {
                    if let im = UIImage(contentsOfFile: nomeMini(id).path) { novas[id] = quadrantes(im) } else { faltam.append(id) }
                }
            }
            travaCores.lock()
            for (k, q) in novas { if var c = cores[k], c.count >= 4 { c = Array(c.prefix(4)) + q; cores[k] = c } }
            if let d = try? JSONSerialization.data(withJSONObject: cores) { _ = gravar(d, arqCores) }
            travaCores.unlock()
        }

        if !faltam.isEmpty {
            let res = PHAsset.fetchAssets(withLocalIdentifiers: faltam, options: nil)
            let o = PHImageRequestOptions()
            o.isSynchronous = true
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = false
            var novas: [String: [Int]] = [:]
            res.enumerateObjects { a, _, _ in
                autoreleasepool {
                    var img: UIImage?
                    self.gerente.requestImage(for: a, targetSize: CGSize(width: 300, height: 300),
                                              contentMode: .aspectFit, options: o) { i, _ in img = i }
                    guard let im = img, let q = self.quadrado(im, lado: 64) else { return }
                    if let d = q.jpegData(compressionQuality: 0.8) { _ = self.gravar(d, self.nomeMini(a.localIdentifier)) }
                    var c = self.media(q)
                    c.append(im.cgImage.map { self.fotoBoa(a, $0) } ?? 1)
                    c += self.quadrantes(q)
                    novas[a.localIdentifier] = c
                }
            }
            travaCores.lock()
            for (k, v) in novas { cores[k] = v }
            if let d = try? JSONSerialization.data(withJSONObject: cores) { _ = gravar(d, arqCores) }
            travaCores.unlock()
        }

        travaCores.lock()
        defer { travaCores.unlock() }
        return ids.map { id -> Any in
            if let c = cores[id] { return c }
            return NSNull()
        }
    }

    // MARK: imagens: utilidades
    private func normalizar(_ im: UIImage, maior: CGFloat = 2000) -> UIImage {
        let s = im.size
        guard s.width > 0, s.height > 0 else { return im }
        let k = min(1, maior / max(s.width, s.height))
        let ns = CGSize(width: max(1, floor(s.width * k)), height: max(1, floor(s.height * k)))
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: ns, format: f).image { _ in im.draw(in: CGRect(origin: .zero, size: ns)) }
    }

    private func quadrado(_ im: UIImage, lado: CGFloat) -> UIImage? {
        let s = im.size
        guard s.width > 0, s.height > 0 else { return nil }
        let k = max(lado / s.width, lado / s.height)
        let w = s.width * k, h = s.height * k
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: lado, height: lado), format: f).image { _ in
            im.draw(in: CGRect(x: (lado - w) / 2, y: (lado - h) / 2, width: w, height: h))
        }
    }

    /// Lê os pixels (RGBA) da imagem reduzida para w x h, preenchendo (corta as sobras) e tirando a média de blocos 4x4.
    private func pixels(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        let W = w * 4, H = h * 4
        var grande = [UInt8](repeating: 0, count: W * H * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        grande.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let k = max(CGFloat(W) / iw, CGFloat(H) / ih)
            let dw = iw * k, dh = ih * k
            ctx.draw(cg, in: CGRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh))
        }
        var saida = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var r = 0, g = 0, b = 0
                for dy in 0..<4 {
                    let base = ((y * 4 + dy) * W + x * 4) * 4
                    for dx in 0..<4 {
                        let p = base + dx * 4
                        r += Int(grande[p]); g += Int(grande[p + 1]); b += Int(grande[p + 2])
                    }
                }
                let o = (y * w + x) * 4
                saida[o] = UInt8(r / 16); saida[o + 1] = UInt8(g / 16); saida[o + 2] = UInt8(b / 16); saida[o + 3] = 255
            }
        }
        return saida
    }

    /// cor de cada quarto da foto (em cima à esq., em cima à dir., embaixo à esq., embaixo à dir.): 12 números
    private func quadrantes(_ im: UIImage) -> [Int] {
        guard let cg = im.cgImage else { return [Int](repeating: 128, count: 12) }
        let p = pixels(cg, 2, 2)
        var out: [Int] = []
        for i in 0..<4 { out += [Int(p[i * 4]), Int(p[i * 4 + 1]), Int(p[i * 4 + 2])] }
        return out
    }
    private func media(_ im: UIImage) -> [Int] {
        guard let cg = im.cgImage else { return [128, 128, 128] }
        let p = pixels(cg, 4, 4)
        var r = 0, g = 0, b = 0
        for i in 0..<16 { r += Int(p[i * 4]); g += Int(p[i * 4 + 1]); b += Int(p[i * 4 + 2]) }
        return [r / 16, g / 16, b / 16]
    }

    /// cor média da pele (bochechas e nariz, sem olhos e cabelo): [r, g, b]
    private func corDaPele(_ cg: CGImage) -> [Int]? {
        guard let b = acharRosto(cg) else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let x = (b.minX + b.width * 0.25) * W, w = b.width * 0.5 * W
        let yTopo = (1 - (b.minY + b.height * 0.55)) * H, h = b.height * 0.3 * H
        guard w > 4, h > 4, let c = cg.cropping(to: CGRect(x: x, y: yTopo, width: w, height: h).integral) else { return nil }
        let p = pixels(c, 4, 4)
        var s = [0, 0, 0]
        for i in 0..<16 { s[0] += Int(p[i * 4]); s[1] += Int(p[i * 4 + 1]); s[2] += Int(p[i * 4 + 2]) }
        return s.map { $0 / 16 }
    }

    private func acharRosto(_ cg: CGImage) -> CGRect? {
        let pedido = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([pedido])
        let rostos = pedido.results ?? []
        return rostos.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?.boundingBox
    }

    /// Corta a foto no formato pedido (prop = largura / altura).
    /// fator > 0: em volta do rosto, com altura = fator x altura do rosto. fator = 0: a foto inteira (centrada no rosto).
    private func cortarRosto(_ original: UIImage, prop: CGFloat, fator: CGFloat) -> (UIImage, Bool) {
        let im = normalizar(original, maior: 2000)
        guard let cg = im.cgImage else { return (im, false) }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let p = max(0.2, min(1.5, prop))
        let rosto = acharRosto(cg)

        var cw: CGFloat, ch: CGFloat, cx: CGFloat, cy: CGFloat
        if let b = rosto, fator > 0 {
            let fh = b.height * H
            ch = fh * fator
            cw = ch * p
            cx = b.midX * W
            cy = (1 - b.midY) * H + ch * (fator < 2 ? 0.03 : 0.08)
        } else {
            ch = H
            cw = H * p
            if cw > W { cw = W; ch = W / p }
            cx = rosto.map { $0.midX * W } ?? W / 2
            cy = rosto.map { (1 - $0.midY) * H } ?? H / 2
        }
        if cw > W { cw = W; ch = cw / p }
        if ch > H { ch = H; cw = ch * p }
        var x = cx - cw / 2, y = cy - ch / 2
        x = min(max(0, x), W - cw)
        y = min(max(0, y), H - ch)
        let r = CGRect(x: x, y: y, width: cw, height: ch).integral
        guard let c = cg.cropping(to: r) else { return (im, rosto != nil) }
        return (normalizar(UIImage(cgImage: c), maior: 1400), rosto != nil)
    }

    // MARK: baixar a foto de um famoso (Wikipédia) e guardar
    private func baixarRosto(_ endereco: String, nome: String, _ r: @escaping Resposta) {
        guard let url = URL(string: endereco), !nome.isEmpty else { return r(nil, "endereço inválido") }
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        pedido.setValue("MosaicoApp/1.1 (iPhone; uso pessoal)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: pedido) { dados, _, erro in
            guard let d = dados, let im = UIImage(data: d) else { return r(nil, erro?.localizedDescription ?? "não baixou") }
            self.fila.async {
                let pronta = self.normalizar(im, maior: 1600)
                let achou = pronta.cgImage.flatMap { self.acharRosto($0) } != nil
                guard let jpg = pronta.jpegData(compressionQuality: 0.9), self.gravar(jpg, self.arq(nome)) else {
                    return r(nil, "não gravou")
                }
                var d: [String: Any] = ["rosto": achou]
                if achou, let cg = pronta.cgImage, let p = self.corDaPele(cg) { d["pele"] = p }
                r(d, nil)
            }
        }.resume()
    }

    /// Cores da imagem guardada, já cortada no enquadramento e reduzida para cols x rows (lista r,g,b,r,g,b...).
    /// Se "real" vier preenchido, guarda o corte também (para a foto real no final).
    private func grade(_ nome: String, cols: Int, rows: Int, enq: String, real: String) -> [Int] {
        guard cols > 0, rows > 0, cols * rows < 60000,
              let im = UIImage(contentsOfFile: arq(nome).path) else { return [] }
        let fator: CGFloat = enq == "inteira" ? 0 : (enq == "cabelo" ? 2.3 : 1.6)
        let (corte, _) = cortarRosto(im, prop: CGFloat(cols) / CGFloat(rows), fator: fator)
        if !real.isEmpty, let j = corte.jpegData(compressionQuality: 0.88) { _ = gravar(j, arq(real)) }
        guard let cg = corte.cgImage else { return [] }
        let p = pixels(cg, cols, rows)
        var saida: [Int] = []
        saida.reserveCapacity(cols * rows * 3)
        for i in 0..<(cols * rows) { saida.append(Int(p[i * 4])); saida.append(Int(p[i * 4 + 1])); saida.append(Int(p[i * 4 + 2])) }
        return saida
    }

    // MARK: montar o mosaico pronto numa imagem só
    private func compor(_ ids: [String], cols: Int, rows: Int, px: Int, modo: String,
                        alvo: [Int], alfa: CGFloat, saida: String) -> Bool {
        guard cols > 0, rows > 0, px > 0, cols * px <= 4200, rows * px <= 9000 else { return false }
        let tam = CGSize(width: cols * px, height: rows * px)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        var cache: [String: UIImage] = [:]
        let img = UIGraphicsImageRenderer(size: tam, format: f).image { contexto in
            let ctx = contexto.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: tam))
            ctx.interpolationQuality = .medium
            for i in 0..<min(ids.count, cols * rows) {
                let id = ids[i]
                let r = CGRect(x: (i % cols) * px, y: (i / cols) * px, width: px, height: px)
                if id.isEmpty { continue }
                var im = cache[id]
                if im == nil {
                    if id.hasPrefix("arq:") {
                        if let a = UIImage(contentsOfFile: self.arq(String(id.dropFirst(4))).path) { im = self.quadrado(a, lado: 64) }
                    } else {
                        im = UIImage(contentsOfFile: self.nomeMini(id).path)
                    }
                    if let i2 = im { cache[id] = i2 }
                }
                im?.draw(in: r)
                if alfa > 0, i * 3 + 2 < alvo.count {
                    ctx.setFillColor(red: CGFloat(alvo[i * 3]) / 255, green: CGFloat(alvo[i * 3 + 1]) / 255,
                                     blue: CGFloat(alvo[i * 3 + 2]) / 255, alpha: alfa)
                    ctx.fill(r)
                }
            }
        }
        var final = img
        if modo == "pb" || modo == "sepia", let ci = CIImage(image: img) {
            var saidaCI = ci.applyingFilter("CIPhotoEffectMono")
            if modo == "sepia" { saidaCI = saidaCI.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85]) }
            let contexto = CIContext()
            if let cg = contexto.createCGImage(saidaCI, from: ci.extent) { final = UIImage(cgImage: cg) }
        }
        guard let jpg = final.jpegData(compressionQuality: 0.85) else { return false }
        return gravar(jpg, arq(saida))
    }

    // MARK: escolher uma foto da Fototeca (bebês, foto da piada, trocar foto de famoso, tela de início)
    private func escolher(nome: String, rosto: Bool, _ r: @escaping Resposta) {
        DispatchQueue.main.async {
            guard let t = self.tela, !nome.isEmpty else { return r(false, nil) }
            self.escolhaResposta?(false, nil)
            self.escolhaResposta = r
            self.escolhaNome = nome
            self.escolhaRosto = rosto
            var conf = PHPickerConfiguration()
            conf.filter = .images
            conf.selectionLimit = 1
            let p = PHPickerViewController(configuration: conf)
            p.delegate = self
            t.present(p, animated: true)
        }
    }

    /// várias fotos de uma vez (fotos do começo da Fototeca), na ordem em que foram tocadas
    private func escolherVarias(pasta: String, max: Int, _ r: @escaping Resposta) {
        DispatchQueue.main.async {
            guard let t = self.tela, !pasta.isEmpty else { return r(nil, "sem tela") }
            self.escolhaResposta?(false, nil)
            self.escolhaResposta = r
            self.escolhaVarias = max
            self.escolhaPasta = pasta
            var conf = PHPickerConfiguration(photoLibrary: .shared())
            conf.filter = .images
            conf.selectionLimit = max
            if #available(iOS 15.0, *) { conf.selection = .ordered }
            let p = PHPickerViewController(configuration: conf)
            p.delegate = self
            t.present(p, animated: true)
        }
    }
    private func salvarVarias(_ res: [PHPickerResult], _ pasta: String, _ r: @escaping Resposta) {
        if res.isEmpty { return r([[String: Any]](), nil) }
        let grupo = DispatchGroup(), trava = NSLock()
        var saida = [[String: Any]?](repeating: nil, count: res.count)
        let base = Int(Date().timeIntervalSince1970 * 1000)
        for (k, x) in res.enumerated() {
            guard x.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            grupo.enter()
            _ = x.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                self.fila.async {
                    defer { grupo.leave() }
                    guard let im = obj as? UIImage else { return }
                    let pronta = self.normalizar(im, maior: 1600)
                    let id = "a\(base)_\(k)"
                    guard let jpg = pronta.jpegData(compressionQuality: 0.88), self.gravar(jpg, self.arq("\(pasta)/\(id).jpg")) else { return }
                    var d: [String: Any] = ["id": id, "w": pronta.size.width * pronta.scale, "h": pronta.size.height * pronta.scale]
                    if let aid = x.assetIdentifier, let a = PHAsset.fetchAssets(withLocalIdentifiers: [aid], options: nil).firstObject, let c = a.creationDate {
                        d["data"] = c.timeIntervalSince1970 * 1000
                    }
                    trava.lock(); saida[k] = d; trava.unlock()
                }
            }
        }
        grupo.notify(queue: .main) { r(saida.compactMap { $0 }, nil) }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let r = escolhaResposta else { return }
        escolhaResposta = nil
        if escolhaVarias > 0 { escolhaVarias = 0; return salvarVarias(results, escolhaPasta, r) }
        guard let prov = results.first?.itemProvider, prov.canLoadObject(ofClass: UIImage.self) else { return r(false, nil) }
        let nome = escolhaNome, rosto = escolhaRosto
        _ = prov.loadObject(ofClass: UIImage.self) { obj, _ in
            guard let im = obj as? UIImage else { return r(false, nil) }
            self.fila.async {
                let pronta = self.normalizar(im, maior: rosto ? 1600 : 2400)
                let achou = rosto && pronta.cgImage.flatMap { self.acharRosto($0) } != nil
                guard let jpg = pronta.jpegData(compressionQuality: 0.9), self.gravar(jpg, self.arq(nome)) else { return r(false, nil) }
                r(["ok": true, "rosto": achou], nil)
            }
        }
    }

    // MARK: câmera da frente lendo texto (Notas do espectador, cartão escrito à mão)
    private var camTraseira = false
    private func cameraLigar(_ segundos: Double, traseira: Bool, _ r: @escaping Resposta) {
        let ligar = {
            self.filaCam.async {
                if let s = self.sessao, self.camTraseira != traseira { s.stopRunning(); self.sessao = nil }   // trocou de câmera: monta de novo
                self.camTraseira = traseira
                if self.sessao == nil {
                    let s = AVCaptureSession()
                    s.sessionPreset = .hd1280x720
                    guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: traseira ? .back : .front),
                          let entrada = try? AVCaptureDeviceInput(device: dev), s.canAddInput(entrada) else {
                        return r(false, "sem câmera")
                    }
                    s.addInput(entrada)
                    let saida = AVCaptureVideoDataOutput()
                    saida.alwaysDiscardsLateVideoFrames = true
                    saida.setSampleBufferDelegate(self, queue: self.filaCam)
                    guard s.canAddOutput(saida) else { return r(false, "sem câmera") }
                    s.addOutput(saida)
                    if let c = saida.connection(with: .video) {
                        if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
                        if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
                    }
                    self.sessao = s
                }
                if !(self.sessao?.isRunning ?? false) { self.sessao?.startRunning() }
                r(true, nil)
                DispatchQueue.main.async {
                    self.camFim?.cancel()
                    let w = DispatchWorkItem { self.cameraDesligar(avisar: true) }
                    self.camFim = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: w)
                }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: ligar()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in if ok { ligar() } else { r(false, "câmera negada") } }
        default: r(false, "câmera negada")
        }
    }

    private func cameraDesligar(avisar: Bool) {
        DispatchQueue.main.async { self.camFim?.cancel(); self.camFim = nil }
        filaCam.async {
            if self.sessao?.isRunning ?? false { self.sessao?.stopRunning() }
            if avisar { self.evento(["tipo": "cameraFim"]) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        camGiro = (camGiro + 1) % 3
        let giros: [CGImagePropertyOrientation] = [.up, .right, .left]   // celular em pé ou deitado
        let pedido = VNRecognizeTextRequest()
        pedido.recognitionLevel = .accurate
        pedido.usesLanguageCorrection = false
        pedido.minimumTextHeight = 0.025
        if let idiomas = try? pedido.supportedRecognitionLanguages() {
            let quero = ["pt-BR", "en-US"].filter { idiomas.contains($0) }
            if !quero.isEmpty { pedido.recognitionLanguages = quero }
        }
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: giros[camGiro], options: [:]).perform([pedido])
        let linhas: [[String: Any]] = (pedido.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return ["t": t, "h": Double(o.boundingBox.height)]
        }
        if !linhas.isEmpty { evento(["tipo": "texto", "linhas": linhas]) }
    }

    // MARK: Post-It (escrita desenhada pela página → texto)
    /// para cada imagem e cada leitura (sem e com correção): as linhas, de cima para baixo, cada uma com até 3 palpites
    private func lerImagens(_ imgs: [String], _ palavras: [String]) -> [[[[String]]]] {
        var saida = [[[[String]]]](repeating: [], count: imgs.count)
        let trava = NSLock()
        DispatchQueue.concurrentPerform(iterations: imgs.count) { n in   // as imagens ao mesmo tempo (mais rápido)
            let s = imgs[n]
            let b64 = s.components(separatedBy: ",").last ?? s
            guard let d = Data(base64Encoded: b64), let im = UIImage(data: d), let cg = im.cgImage else { return }
            var leituras: [[[String]]] = []
            for corrigir in [false, true] {   // sem correção (letra por letra) e com correção puxando para os nomes da lista
                let pedido = VNRecognizeTextRequest()
                pedido.recognitionLevel = .accurate
                pedido.usesLanguageCorrection = corrigir
                if corrigir && !palavras.isEmpty { pedido.customWords = Array(palavras.prefix(4000)) }
                if let idiomas = try? pedido.supportedRecognitionLanguages() {
                    let quero = ["pt-BR", "en-US"].filter { idiomas.contains($0) }
                    if !quero.isEmpty { pedido.recognitionLanguages = quero }
                }
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([pedido])
                // de cima para baixo; na mesma altura, da esquerda para a direita
                let obs = (pedido.results ?? []).sorted { a, b in
                    let ba = a.boundingBox, bb = b.boundingBox
                    if abs(ba.midY - bb.midY) < 0.5 * min(ba.height, bb.height) { return ba.minX < bb.minX }
                    return ba.midY > bb.midY
                }
                let linhas: [[String]] = obs.map { o in o.topCandidates(3).map { $0.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }.filter { !$0.isEmpty }
                leituras.append(linhas)
            }
            trava.lock(); saida[n] = leituras; trava.unlock()
        }
        return saida
    }

    // MARK: microfone (o mágico fala o nome)
    private func vozLigar(_ segundos: Double, _ r: @escaping Resposta) {
        SFSpeechRecognizer.requestAuthorization { st in
            guard st == .authorized else { return r(false, "reconhecimento de fala negado") }
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                guard ok else { return r(false, "microfone negado") }
                DispatchQueue.main.async { self.comecarVoz(segundos, r) }
            }
        }
    }

    private func comecarVoz(_ segundos: Double, _ r: Resposta) {
        pararVoz(avisar: false)
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")), rec.isAvailable else {
            return r(false, "reconhecimento indisponível")
        }
        let sessaoAudio = AVAudioSession.sharedInstance()
        do {
            try sessaoAudio.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try sessaoAudio.setActive(true)
        } catch { return r(false, "áudio ocupado") }
        let pedido = SFSpeechAudioBufferRecognitionRequest()
        pedido.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { pedido.requiresOnDeviceRecognition = true }
        let m = AVAudioEngine()
        let entrada = m.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { buf, _ in pedido.append(buf) }
        m.prepare()
        do { try m.start() } catch {
            entrada.removeTap(onBus: 0)
            return r(false, "microfone não ligou")
        }
        motor = m
        pedidoVoz = pedido
        tarefaVoz = rec.recognitionTask(with: pedido) { res, erro in
            if let res = res {
                self.evento(["tipo": "voz", "texto": res.bestTranscription.formattedString, "final": res.isFinal])
            }
            if erro != nil || (res?.isFinal ?? false) { DispatchQueue.main.async { self.pararVoz(avisar: true) } }
        }
        r(true, nil)
        let w = DispatchWorkItem { self.pararVoz(avisar: true) }
        vozFim = w
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: w)
    }

    private func pararVoz(avisar: Bool) {
        vozFim?.cancel()
        vozFim = nil
        guard let m = motor else { return }
        m.stop()
        m.inputNode.removeTap(onBus: 0)
        pedidoVoz?.endAudio()
        tarefaVoz?.finish()
        motor = nil
        pedidoVoz = nil
        tarefaVoz = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // volta o som ao modo normal com calma (o iPhone recusa se for na mesma hora) para o botão de volume voltar a ser percebido
        volume.reativar(depois: 0.45)
        if avisar { evento(["tipo": "vozFim"]) }
    }

    // MARK: endereço mzfoto:// (imagens para a página)
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String { itens.first { $0.name == n }?.value ?? "" }
        let tarefa = urlSchemeTask
        switch url.host ?? "" {
        case "mini":
            let id = v("id")
            filaImg.async {
                if let d = try? Data(contentsOf: self.nomeMini(id)) { return self.entregar(tarefa, d) }
                self.fotoDaFototeca(id, lado: 96, preencher: true) { self.entregar(tarefa, $0) }
            }
        case "foto":
            let lado = CGFloat(Double(v("s")) ?? 400)
            fotoDaFototeca(v("id"), lado: lado, preencher: v("m") != "fit") { self.entregar(tarefa, $0) }
        case "arq":
            let u = arq(v("n"))
            filaImg.async { self.entregar(tarefa, try? Data(contentsOf: u)) }
        default:
            entregar(tarefa, nil)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        parados.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func fotoDaFototeca(_ id: String, lado: CGFloat, preencher: Bool, _ fim: @escaping (Data?) -> Void) {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return fim(nil) }
        // primeiro a melhor versão que já está no aparelho (na hora); só vai ao iCloud se ela for pequena demais
        let local = PHImageRequestOptions()
        local.deliveryMode = .highQualityFormat
        local.resizeMode = .fast
        local.isNetworkAccessAllowed = false
        local.isSynchronous = false
        let modo: PHImageContentMode = preencher ? .aspectFill : .aspectFit
        gerente.requestImage(for: a, targetSize: CGSize(width: lado, height: lado), contentMode: modo, options: local) { im, _ in
            if let im = im, max(im.size.width * im.scale, im.size.height * im.scale) >= lado * 0.45 {
                self.filaImg.async { fim(im.jpegData(compressionQuality: 0.85)) }
                return
            }
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            o.isSynchronous = false
            self.gerente.requestImage(for: a, targetSize: CGSize(width: lado, height: lado), contentMode: modo, options: o) { im2, _ in
                self.filaImg.async { fim((im2 ?? im)?.jpegData(compressionQuality: 0.85)) }
            }
        }
    }

    private func entregar(_ tarefa: WKURLSchemeTask, _ dados: Data?) {
        DispatchQueue.main.async {
            if self.parados.remove(ObjectIdentifier(tarefa)) != nil { return }
            guard let d = dados, let url = tarefa.request.url,
                  let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "image/jpeg",
                                                            "Content-Length": "\(d.count)",
                                                            "Access-Control-Allow-Origin": "*"]) else {
                tarefa.didFailWithError(NSError(domain: "mosaico", code: 404))
                return
            }
            tarefa.didReceive(resp)
            tarefa.didReceive(d)
            tarefa.didFinish()
        }
    }
}


/// Botão de volume para cima (sem o aviso de volume do iPhone aparecer): avisa a página a cada toque,
/// e repete enquanto o botão fica apertado.
final class VolumeEspiao: NSObject {
    private let vv = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    private var obs: NSKeyValueObservation?
    private var ajustando = false
    var aviso: () -> Void = {}
    func instalar(em v: UIView) {
        vv.alpha = 0.01
        vv.isUserInteractionEnabled = false
        v.addSubview(vv)
        ativar()
        obs = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { [weak self] _, ch in
            guard let n = ch.newValue, let o = ch.oldValue else { return }
            DispatchQueue.main.async {
                guard let self = self, !self.ajustando else { return }
                if n > o || n >= 0.999 { self.aviso() }
                self.centralizar()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(ativar), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    @objc func ativar() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord && s.category != .record { try? s.setCategory(.ambient, options: [.mixWithOthers]) }
        try? s.setActive(true)
        centralizar()
    }
    /// depois do microfone (ou ao abrir o Fotos): som no modo normal, escuta ativa e volume no meio — tenta de novo se o iPhone recusar
    func reativar(depois: Double, tentativa: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + depois) { [weak self] in
            guard let self = self else { return }
            let s = AVAudioSession.sharedInstance()
            var ok = true
            if s.category != .ambient { do { try s.setCategory(.ambient, mode: .default, options: [.mixWithOthers]) } catch { ok = false } }
            do { try s.setActive(true) } catch { ok = false }
            if !ok && tentativa < 5 { self.reativar(depois: 0.3, tentativa: tentativa + 1); return }
            self.centralizar(forcar: true)
        }
    }
    /// deixa o volume no meio para o botão continuar avisando (no máximo ele para de mudar)
    private func centralizar(forcar: Bool = false, tentativa: Int = 0) {
        let v = AVAudioSession.sharedInstance().outputVolume
        guard v > (forcar ? 0.8 : 0.85) || v < (forcar ? 0.15 : 0.1) else { return }
        // pelo controle invisível (assim a barra de volume do iPhone não aparece); se ainda não está pronto, tenta de novo
        guard vv.window != nil, let sl = vv.subviews.compactMap({ $0 as? UISlider }).first else {
            if tentativa < 6 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.centralizar(forcar: forcar, tentativa: tentativa + 1) } }
            return
        }
        ajustando = true
        sl.value = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.ajustando = false }
    }
}

// MARK: cópia da lista (exportar / importar)
final class EscolhaArquivo: NSObject, UIDocumentPickerDelegate {
    var fim: (URL?) -> Void = { _ in }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { fim(urls.first); fim = { _ in } }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { fim(nil); fim = { _ in } }
}

extension PonteExtra {
    /// junta os dados da página e todos os arquivos das pastas pedidas num arquivo só e abre o "Compartilhar" do iPhone
    func exportarCopia(dados: String, pastas: [String], nome: String, _ r: @escaping Resposta) {
        fila.async {
            var arquivos: [String: String] = [:]
            let fm = FileManager.default
            for p in pastas {
                let pasta = self.arqPublico(p)
                for n in (try? fm.contentsOfDirectory(atPath: pasta.path)) ?? [] where !n.hasPrefix(".") {
                    if let d = try? Data(contentsOf: pasta.appendingPathComponent(n)) { arquivos[p + "/" + n] = d.base64EncodedString() }
                }
            }
            let tudo: [String: Any] = ["tipo": "mosaico-lista", "v": 1, "dados": dados, "arquivos": arquivos]
            let destino = fm.temporaryDirectory.appendingPathComponent(nome.isEmpty ? "lista.json" : nome)
            guard let j = try? JSONSerialization.data(withJSONObject: tudo), (try? j.write(to: destino, options: .atomic)) != nil else { return r(nil, "não consegui criar o arquivo") }
            DispatchQueue.main.async {
                guard let t = self.telaPublica else { return r(nil, "sem tela") }
                let av = UIActivityViewController(activityItems: [destino], applicationActivities: nil)
                av.popoverPresentationController?.sourceView = t.view
                av.popoverPresentationController?.sourceRect = CGRect(x: t.view.bounds.midX, y: t.view.bounds.midY, width: 1, height: 1)
                av.completionWithItemsHandler = { _, ok, _, _ in r(["ok": ok, "fotos": arquivos.count], nil) }
                t.present(av, animated: true)
            }
        }
    }
    /// abre o app Arquivos; grava as fotos de volta e devolve os dados para a página
    func importarCopia(_ r: @escaping Resposta) {
        DispatchQueue.main.async {
            guard let t = self.telaPublica else { return r(nil, "sem tela") }
            let p = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data, .item], asCopy: true)
            let d = EscolhaArquivo()
            self.escolhaArquivo = d
            d.fim = { url in
                self.escolhaArquivo = nil
                guard let url = url else { return r(NSNull(), nil) }
                self.fila.async {
                    guard let dados = try? Data(contentsOf: url),
                          let o = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
                          o["tipo"] as? String == "mosaico-lista", let txt = o["dados"] as? String else { return r(nil, "arquivo não é uma lista do Mosaico") }
                    var n = 0
                    for (cam, b64) in (o["arquivos"] as? [String: String]) ?? [:] {
                        guard let d = Data(base64Encoded: b64) else { continue }
                        let u = self.arqPublico(cam)
                        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? d.write(to: u, options: .atomic)) != nil { n += 1 }
                    }
                    r(["dados": txt, "fotos": n], nil)
                }
            }
            p.delegate = d
            t.present(p, animated: true)
        }
    }
}

/// Barrinha do Notas grudada no teclado: ícones copiados do Notas de verdade, nas mesmas posições
final class BarraNotasView: UIView {
    private let pilula = UIView()
    private var icones: [(UIImageView, CGFloat, CGFloat)] = []
    private static let dados: [(String, CGFloat, CGFloat)] = [
        ("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", 0.0869, 0.4966),
        ("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", 0.2913, 0.4966),
        ("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", 0.4849, 0.4966),
        ("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", 0.6794, 0.5034),
        ("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", 0.8683, 0.4966)
    ]
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth]
        pilula.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1) : UIColor(red: 0.992, green: 0.992, blue: 0.992, alpha: 1) }
        pilula.layer.cornerRadius = 24
        pilula.layer.cornerCurve = .continuous
        pilula.layer.borderWidth = 0.5
        pilula.layer.shadowColor = UIColor.black.cgColor
        pilula.layer.shadowOpacity = 0.06
        pilula.layer.shadowRadius = 4
        pilula.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(pilula)
        for (b64, fx, fy) in BarraNotasView.dados {
            guard let d = Data(base64Encoded: b64), let im = UIImage(data: d, scale: 3) else { continue }
            let iv = UIImageView(image: im.withRenderingMode(.alwaysTemplate))
            iv.tintColor = .label
            pilula.addSubview(iv)
            icones.append((iv, fx, fy))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        pilula.frame = CGRect(x: 7, y: 4, width: bounds.width - 14, height: 48)
        pilula.layer.borderColor = (traitCollection.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0.886, alpha: 1)).cgColor
        for (iv, fx, fy) in icones {
            iv.sizeToFit()
            iv.center = CGPoint(x: pilula.bounds.width * fx, y: pilula.bounds.height * fy)
        }
    }
}

// MARK: escolher a melhor foto do famoso (de frente, rosto grande, luz boa)
extension PonteExtra {
    /// baixa as fotos candidatas, dá nota a cada uma e guarda a melhor em "nome"
    func escolherFoto(_ enderecos: [String], nome: String, _ r: @escaping Resposta) {
        let lista = Array(enderecos.prefix(10))
        guard !lista.isEmpty, !nome.isEmpty else { return r(nil, "sem fotos") }
        let grupo = DispatchGroup(), trava = NSLock()
        var notas: [(Double, Int, UIImage)] = []
        for (i, e) in lista.enumerated() {
            guard let url = URL(string: e) else { continue }
            grupo.enter()
            var pedido = URLRequest(url: url, timeoutInterval: 12)
            pedido.setValue("MosaicoApp/1.1 (iPhone; uso pessoal)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: pedido) { dados, _, _ in
                defer { grupo.leave() }
                guard let d = dados, let im = UIImage(data: d) else { return }
                let pronta = self.normalizar(im, maior: 1600)
                let n = self.notaRosto(pronta)
                trava.lock(); notas.append((n, i, pronta)); trava.unlock()
            }.resume()
        }
        grupo.notify(queue: fila) {
            let todas = notas.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            guard let melhor = todas.first else { return r(nil, "não baixou") }
            guard let jpg = melhor.2.jpegData(compressionQuality: 0.9), self.gravar(jpg, self.arq(nome)) else { return r(nil, "não gravou") }
            var d: [String: Any] = ["rosto": melhor.0 > 0, "nota": melhor.0, "url": lista[melhor.1],
                                    "notas": todas.map { ["url": lista[$0.1], "nota": $0.0] as [String: Any] }]
            if melhor.0 > 0, let cg = melhor.2.cgImage, let p = self.corDaPele(cg) { d["pele"] = p }
            r(d, nil)
        }
    }
    /// 0 = sem rosto; perto de 1 = rosto de frente, grande, com luz boa
    func notaRosto(_ im: UIImage) -> Double {
        guard let cg = im.cgImage else { return 0 }
        let pedido = VNDetectFaceRectanglesRequest()
        pedido.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([pedido])
        let rostos = (pedido.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        guard let f = rostos.first else { return 0 }
        let b = f.boundingBox, W = Double(cg.width), H = Double(cg.height)
        let area = Double(b.width * b.height)
        let tamanho = min(1, area / 0.10)
        func ang(_ x: NSNumber?) -> Double { abs(x?.doubleValue ?? 0) }
        let frente = max(0, 1 - ang(f.yaw) / 0.8) * max(0, 1 - ang(f.roll) / 0.7) * max(0, 1 - ang(f.pitch) / 0.7)
        let resol = Double(b.width) * W >= 200 ? 1.0 : 0.3
        var outros = 1.0
        if rostos.count > 1 { let a2 = Double(rostos[1].boundingBox.width * rostos[1].boundingBox.height); if a2 > area * 0.35 { outros = 0.55 } }
        var luz = 0.7
        let caixa = CGRect(x: Double(b.minX) * W, y: (1 - Double(b.maxY)) * H, width: Double(b.width) * W, height: Double(b.height) * H).integral
        if caixa.width > 4, caixa.height > 4, let c = cg.cropping(to: caixa) {
            let p = pixels(c, 4, 4); var s = 0.0
            for i in 0..<16 { s += 0.299 * Double(p[i * 4]) + 0.587 * Double(p[i * 4 + 1]) + 0.114 * Double(p[i * 4 + 2]) }
            let m = s / 16; luz = m < 60 ? 0.4 : (m > 215 ? 0.6 : 1)
        }
        let emPe = H >= W * 1.1 ? 1.0 : 0.9
        let menor = min(W, H), tamFoto = menor >= 800 ? 1.0 : (menor >= 500 ? 0.9 : 0.75)
        return (0.4 * frente + 0.35 * tamanho + 0.15 * luz + 0.1) * resol * outros * emPe * tamFoto
    }
}
