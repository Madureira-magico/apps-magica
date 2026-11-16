import UIKit
import WebKit
import Photos
import PhotosUI
import Vision
import CoreImage
import AVFoundation
import Speech
import MediaPlayer

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
    private let fila = DispatchQueue(label: "mosaico.trabalho", qos: .userInitiated)
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
            let bloco: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            class_addMethod(n, NSSelectorFromString("inputAccessoryView"), imp_implementationWithBlock(bloco), "@@:")
            objc_registerClassPair(n)
            nova = n
        }
        if let n = nova { object_setClass(alvo, n) }
    }

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
            cameraLigar(num("segundos", 8), responder)
        case "cameraDesligar":
            cameraDesligar(avisar: false)
            responder(true, nil)
        case "vozLigar":
            vozLigar(num("segundos", 7), responder)
        case "volumeAtivar":   // abriu o Fotos / chegou no rosto: confere a escuta do volume e deixa o volume no meio
            if motor == nil { volume.reativar(depois: 0) }
            r(true, nil)
        case "vozDesligar":
            pararVoz(avisar: false)
            responder(true, nil)
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
    private func cameraLigar(_ segundos: Double, _ r: @escaping Resposta) {
        let ligar = {
            self.filaCam.async {
                if self.sessao == nil {
                    let s = AVCaptureSession()
                    s.sessionPreset = .hd1280x720
                    guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
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
