import UIKit
import WebKit
import Photos
import PhotosUI
import Vision
import CoreImage

/// Parte do iPhone só do app Mosaico.
/// Recados da página (window.webkit.messageHandlers.mz.postMessage({cmd: ...}) devolve uma resposta):
///   permissao, albuns, fotos, analisar, info, baixarRosto, grade, compor, escolher, apagar, listar, existe, vibrar
/// Imagens para a página pelo endereço mzfoto://
///   mzfoto://mini?id=...          miniatura quadrada (64 px) guardada no celular
///   mzfoto://foto?id=...&s=400&m=fill|fit   foto da Fototeca no tamanho pedido
///   mzfoto://arq?n=pasta/nome.jpg arquivo guardado pelo app (rostos, bebês, mosaico pronto)
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply, WKURLSchemeHandler, PHPickerViewControllerDelegate {
    typealias Resposta = (Any?, String?) -> Void

    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    private let fila = DispatchQueue(label: "mosaico.trabalho", qos: .userInitiated)
    private let filaImg = DispatchQueue(label: "mosaico.imagens", qos: .userInitiated, attributes: .concurrent)
    private let gerente = PHImageManager.default()
    private var parados = Set<ObjectIdentifier>()

    private var cores: [String: [Int]] = [:]
    private var coresLidas = false
    private let travaCores = NSLock()

    private var escolhaResposta: Resposta?
    private var escolhaNome = ""
    private var escolhaRosto = false
    private var escolhaProp: CGFloat = 0.46

    // MARK: ligar ao app
    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "mz")
        config.setURLSchemeHandler(self, forURLScheme: "mzfoto")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
    }

    // MARK: pastas
    private lazy var docs: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var pastaMinis: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("minis")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var arqCores: URL { pastaMinis.appendingPathComponent("cores.json") }

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
            baixarRosto(txt("url"), nome: txt("nome"), prop: CGFloat(num("prop", 0.46)), responder)
        case "grade":
            let nome = txt("nome"), c = Int(num("cols", 40)), l = Int(num("rows", 80))
            fila.async { responder(self.grade(nome, cols: c, rows: l), nil) }
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
            escolher(nome: txt("nome"), rosto: (m["rosto"] as? Bool) ?? false, prop: CGFloat(num("prop", 0.46)), responder)
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
        default:
            responder(nil, "recado desconhecido: \(cmd)")
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
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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

    // MARK: cores médias e miniaturas (para montar o mosaico)
    private func lerCores() {
        if coresLidas { return }
        coresLidas = true
        if let d = try? Data(contentsOf: arqCores),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: [Int]] {
            cores = j
        }
    }

    private func analisar(_ ids: [String]) -> [Any] {
        travaCores.lock()
        lerCores()
        let faltam = ids.filter { cores[$0] == nil || !FileManager.default.fileExists(atPath: nomeMini($0).path) }
        travaCores.unlock()

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
                    self.gerente.requestImage(for: a, targetSize: CGSize(width: 128, height: 128),
                                              contentMode: .aspectFill, options: o) { i, _ in img = i }
                    guard let im = img, let q = self.quadrado(im, lado: 64) else { return }
                    if let d = q.jpegData(compressionQuality: 0.8) { _ = self.gravar(d, self.nomeMini(a.localIdentifier)) }
                    novas[a.localIdentifier] = self.media(q)
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

    private func media(_ im: UIImage) -> [Int] {
        guard let cg = im.cgImage else { return [128, 128, 128] }
        let p = pixels(cg, 4, 4)
        var r = 0, g = 0, b = 0
        for i in 0..<16 { r += Int(p[i * 4]); g += Int(p[i * 4 + 1]); b += Int(p[i * 4 + 2]) }
        return [r / 16, g / 16, b / 16]
    }

    /// Corta a foto em volta do maior rosto, no formato da tela (prop = largura / altura).
    private func cortarRosto(_ original: UIImage, prop: CGFloat) -> (UIImage, Bool) {
        let im = normalizar(original, maior: 2000)
        guard let cg = im.cgImage else { return (im, false) }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let pedido = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([pedido])
        let rostos = pedido.results ?? []
        let p = max(0.2, min(1.5, prop))

        var cw: CGFloat, ch: CGFloat, cx: CGFloat, cy: CGFloat
        var achou = false
        if let f = rostos.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let b = f.boundingBox
            let fh = b.height * H
            ch = fh * 2.7
            cw = ch * p
            cx = b.midX * W
            cy = (1 - b.midY) * H + ch * 0.08   // rosto um pouco acima do meio
            achou = true
        } else {
            ch = H; cw = H * p
            if cw > W { cw = W; ch = W / p }
            cx = W / 2; cy = H / 2
        }
        if cw > W { cw = W; ch = cw / p }
        if ch > H { ch = H; cw = ch * p }
        var x = cx - cw / 2, y = cy - ch / 2
        x = min(max(0, x), W - cw)
        y = min(max(0, y), H - ch)
        let r = CGRect(x: x, y: y, width: cw, height: ch).integral
        guard let c = cg.cropping(to: r) else { return (im, achou) }
        return (normalizar(UIImage(cgImage: c), maior: 1000), achou)
    }

    // MARK: baixar a foto de um famoso (Wikipédia) e guardar só o rosto
    private func baixarRosto(_ endereco: String, nome: String, prop: CGFloat, _ r: @escaping Resposta) {
        guard let url = URL(string: endereco), !nome.isEmpty else { return r(nil, "endereço inválido") }
        var pedido = URLRequest(url: url, timeoutInterval: 20)
        pedido.setValue("MosaicoApp/1.0 (iPhone; uso pessoal)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: pedido) { dados, _, erro in
            guard let d = dados, let im = UIImage(data: d) else { return r(nil, erro?.localizedDescription ?? "não baixou") }
            self.fila.async {
                let (cortada, achou) = self.cortarRosto(im, prop: prop)
                guard let jpg = cortada.jpegData(compressionQuality: 0.9), self.gravar(jpg, self.arq(nome)) else {
                    return r(nil, "não gravou")
                }
                r(["rosto": achou], nil)
            }
        }.resume()
    }

    /// Cores da imagem guardada, reduzida para cols x rows (lista r,g,b,r,g,b...).
    private func grade(_ nome: String, cols: Int, rows: Int) -> [Int] {
        guard cols > 0, rows > 0, cols * rows < 40000,
              let im = UIImage(contentsOfFile: arq(nome).path), let cg = normalizar(im, maior: 1200).cgImage else { return [] }
        let p = pixels(cg, cols, rows)
        var saida: [Int] = []
        saida.reserveCapacity(cols * rows * 3)
        for i in 0..<(cols * rows) { saida.append(Int(p[i * 4])); saida.append(Int(p[i * 4 + 1])); saida.append(Int(p[i * 4 + 2])) }
        return saida
    }

    // MARK: montar o mosaico pronto numa imagem só
    private func compor(_ ids: [String], cols: Int, rows: Int, px: Int, modo: String,
                        alvo: [Int], alfa: CGFloat, saida: String) -> Bool {
        guard cols > 0, rows > 0, px > 0, cols * px <= 4000, rows * px <= 8000 else { return false }
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

    // MARK: escolher uma foto da Fototeca (bebês, trocar foto de famoso, tela de início)
    private func escolher(nome: String, rosto: Bool, prop: CGFloat, _ r: @escaping Resposta) {
        DispatchQueue.main.async {
            guard let t = self.tela, !nome.isEmpty else { return r(false, nil) }
            self.escolhaResposta?(false, nil)
            self.escolhaResposta = r
            self.escolhaNome = nome
            self.escolhaRosto = rosto
            self.escolhaProp = prop
            var conf = PHPickerConfiguration()
            conf.filter = .images
            conf.selectionLimit = 1
            let p = PHPickerViewController(configuration: conf)
            p.delegate = self
            t.present(p, animated: true)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let r = escolhaResposta else { return }
        escolhaResposta = nil
        guard let prov = results.first?.itemProvider, prov.canLoadObject(ofClass: UIImage.self) else { return r(false, nil) }
        let nome = escolhaNome, rosto = escolhaRosto, prop = escolhaProp
        _ = prov.loadObject(ofClass: UIImage.self) { obj, _ in
            guard let im = obj as? UIImage else { return r(false, nil) }
            self.fila.async {
                var pronta = im
                var achou = false
                if rosto {
                    let corte = self.cortarRosto(im, prop: prop)
                    pronta = corte.0
                    achou = corte.1
                } else {
                    pronta = self.normalizar(im, maior: 2400)
                }
                guard let jpg = pronta.jpegData(compressionQuality: 0.9), self.gravar(jpg, self.arq(nome)) else { return r(false, nil) }
                r(["ok": true, "rosto": achou], nil)
            }
        }
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
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        o.isSynchronous = false
        gerente.requestImage(for: a, targetSize: CGSize(width: lado, height: lado),
                             contentMode: preencher ? .aspectFill : .aspectFit, options: o) { im, _ in
            self.filaImg.async { fim(im?.jpegData(compressionQuality: 0.85)) }
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
