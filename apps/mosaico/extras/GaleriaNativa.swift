import UIKit
import WebKit
import Photos

/// Fototeca = UMA imagem gigante (todas as fotos lado a lado, formando o mosaico).
/// A pinça é só o zoom de foto do próprio iPhone nessa imagem: nada muda de lugar, sem saltos.
/// De perto (3 colunas) parecem fotos normais; afastando, a cor do rosto vai aparecendo.
final class GaleriaNativa: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    let vista = UIView()
    private let capa = CapaToques()
    private let zoomer = UIScrollView()
    private let plano = UIView()
    private let tiles = TilesMosaico()
    private let tinta = UIImageView()
    private let tintaFaixa = UIImageView()   // pinta forte as fotos do começo quando o rosto aparece
    private var xTravado: CGFloat?
    private let magImg = UIImageView()
    private let corCamada = CALayer()
    private var toque: UITapGestureRecognizer!
    private weak var web: WKWebView?

    var urlMini: (String) -> URL = { _ in URL(fileURLWithPath: "/") }
    var urlArq: (String) -> URL = { _ in URL(fileURLWithPath: "/") }
    var evento: ([String: Any]) -> Void = { _ in }

    // dados da página
    private var seq: [String] = []
    private var mosIds: [String] = []
    private var mosTinta: [UInt8] = []
    private var mosCols = 0, primeira = 0, linhasMos = 0, ini = 0, faixaL = 0
    private var mosImg = "", mosV = ""
    private var temMos: Bool { mosCols > 0 && magImg.image != nil }
    private var reforco: CGFloat = 0.4
    private var corModo = "cor"
    private var escuro = true
    private var n0: CGFloat = 3
    private var st: CGFloat = 47, sb: CGFloat = 34
    private var zonas: [CGRect] = []
    private var selecao = false
    private var selecionados = Set<Int>()

    private var ligada = false, ativa = true
    private var C = 13              // colunas da imagem gigante
    private var linhas = 0
    private var geoChave = ""
    private var W: CGFloat { vista.bounds.width }
    private var H: CGFloat { vista.bounds.height }
    private var t0: CGFloat { W / CGFloat(max(1, C)) }
    private var cima: CGFloat { st + 96 }
    private var visiveis: CGFloat { CGFloat(C) / max(0.01, zoomer.zoomScale) }   // colunas na tela

    // imagens
    private final class Caixa { let img: CGImage; init(_ i: CGImage) { img = i } }
    private let cache: NSCache<NSString, Caixa> = { let c = NSCache<NSString, Caixa>(); c.totalCostLimit = 160 * 1024 * 1024; return c }()
    private let gerente = PHCachingImageManager()

    // MARK: montar
    func instalar(em webView: WKWebView) {
        web = webView
        vista.frame = webView.bounds
        vista.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vista.isUserInteractionEnabled = false
        vista.isHidden = true
        vista.backgroundColor = .black
        vista.clipsToBounds = true

        zoomer.frame = vista.bounds
        zoomer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomer.delegate = self
        zoomer.showsVerticalScrollIndicator = false
        zoomer.showsHorizontalScrollIndicator = false
        zoomer.contentInsetAdjustmentBehavior = .never
        zoomer.scrollsToTop = false
        zoomer.bouncesZoom = true
        zoomer.alwaysBounceVertical = true
        zoomer.alwaysBounceHorizontal = false
        zoomer.bounces = true
        zoomer.decelerationRate = .normal
        zoomer.addSubview(plano)
        plano.addSubview(tiles)
        tinta.layer.magnificationFilter = .nearest
        tinta.isUserInteractionEnabled = false
        plano.addSubview(tinta)
        magImg.contentMode = .scaleToFill
        plano.addSubview(magImg)
        tintaFaixa.layer.magnificationFilter = .nearest
        tintaFaixa.isUserInteractionEnabled = false
        plano.addSubview(tintaFaixa)
        vista.addSubview(zoomer)
        corCamada.compositingFilter = "colorBlendMode"
        corCamada.opacity = 0
        vista.layer.addSublayer(corCamada)
        tiles.carregar = { [weak self] id, px, q in self?.imagem(id, px, q) }
        webView.insertSubview(vista, at: 0)

        capa.frame = webView.bounds
        capa.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        capa.backgroundColor = .clear
        capa.isHidden = true
        capa.deixar = { [weak self] p in
            guard let s = self, s.ligada, s.ativa else { return false }
            return !s.zonas.contains { $0.contains(p) }
        }
        webView.addSubview(capa)
        zoomer.minimumZoomScale = 1
        zoomer.maximumZoomScale = 5
        capa.addGestureRecognizer(zoomer.panGestureRecognizer)
        if let p = zoomer.pinchGestureRecognizer { capa.addGestureRecognizer(p) }
        toque = UITapGestureRecognizer(target: self, action: #selector(tocou(_:)))
        toque.delegate = self
        capa.addGestureRecognizer(toque)
    }

    // MARK: recados da página
    func recado(_ cmd: String, _ m: [String: Any], _ r: @escaping (Any?, String?) -> Void) -> Bool {
        func num(_ k: String, _ p: CGFloat) -> CGFloat { CGFloat((m[k] as? NSNumber)?.doubleValue ?? Double(p)) }
        switch cmd {
        case "galeria":
            ativa = (m["ativa"] as? Bool) ?? true
            ligar((m["on"] as? Bool) ?? false)
            r(true, nil)
        case "galeriaDados":
            receberDados(m)
            r(true, nil)
        case "galeriaRect":
            if let q = retangulo(Int(num("i", -1))) { r([q.minX, q.minY, q.width, q.height], nil) } else { r(NSNull(), nil) }
        case "galeriaVer":
            garantirVisivel(Int(num("i", -1)))
            r(true, nil)
        case "galeriaNivel":
            irAoNivel(num("n", 3))
            r(true, nil)
        case "galeriaEstado":
            r(["zoom": visiveis, "mag": temMos && visiveis > 13.5, "k": zoomer.zoomScale], nil)
        default:
            return false
        }
        return true
    }

    private func ligar(_ on: Bool) {
        ligada = on
        if let w = web, on {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.scrollView.backgroundColor = .clear
            w.bringSubviewToFront(capa)
            vista.frame = w.bounds
        }
        vista.isHidden = !on
        capa.isHidden = !on
        atualizarGestos()
    }
    private func atualizarGestos() {
        let pode = ligada && ativa
        toque.isEnabled = pode
        zoomer.isScrollEnabled = pode && !travado
        zoomer.pinchGestureRecognizer?.isEnabled = pode
    }

    private func receberDados(_ m: [String: Any]) {
        var zerar = (m["zerar"] as? Bool) ?? false
        if let s = m["seq"] as? [String] { seq = s }
        if let d = m["mos"] as? [String: Any], let ids = d["ids"] as? [String] {
            mosIds = ids
            mosTinta = ((d["tinta"] as? [NSNumber]) ?? []).map { UInt8(clamping: $0.intValue) }
            mosCols = (d["cols"] as? NSNumber)?.intValue ?? 60
            primeira = (d["primeira"] as? NSNumber)?.intValue ?? 0
            linhasMos = (d["linhas"] as? NSNumber)?.intValue ?? 0
            ini = (d["ini"] as? NSNumber)?.intValue ?? 0
            faixaL = (d["faixaL"] as? NSNumber)?.intValue ?? 0
            let img = (d["img"] as? String) ?? "", v = "\(d["v"] ?? "")"
            if v != mosV || img != mosImg || magImg.image == nil {
                mosImg = img; mosV = v
                magImg.image = UIImage(contentsOfFile: urlArq(img).path)
                tinta.image = imagemTinta(false)
                tintaFaixa.image = imagemTinta(true)
            }
        } else if m["mos"] != nil {
            mosIds = []; mosTinta = []; mosCols = 0; mosV = ""
            magImg.image = nil; tinta.image = nil; tintaFaixa.image = nil
        }
        let selAntes = selecao ? selecionados : []
        if let c = m["cfg"] as? [String: Any] {
            reforco = CGFloat((c["reforco"] as? NSNumber)?.doubleValue ?? 0.4)
            corModo = (c["cor"] as? String) ?? "cor"
            escuro = (c["escuro"] as? Bool) ?? true
            n0 = CGFloat((c["n0"] as? NSNumber)?.doubleValue ?? 3)
            st = CGFloat((c["st"] as? NSNumber)?.doubleValue ?? 47)
            sb = CGFloat((c["sb"] as? NSNumber)?.doubleValue ?? 34)
            selecao = (c["selecao"] as? Bool) ?? false
            selecionados = Set(((c["sel"] as? [NSNumber]) ?? []).map { $0.intValue })
            zonas = ((c["zonas"] as? [[NSNumber]]) ?? []).compactMap { a in
                a.count == 4 ? CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue) : nil
            }
            if let a = c["ativa"] as? Bool { ativa = a }
        }
        vista.backgroundColor = escuro ? .black : .white
        tiles.backgroundColor = vista.backgroundColor
        tiles.cores = (escuro ? UIColor.black.cgColor : UIColor.white.cgColor, escuro ? UIColor(white: 0.12, alpha: 1).cgColor : UIColor(white: 0.9, alpha: 1).cgColor)
        tiles.marcas = selecao ? selecionados : []

        // monta a imagem gigante
        C = temMos ? mosCols : max(1, Int(n0))
        linhas = Int(ceil(Double(seq.count) / Double(max(1, C))))
        let chave = "\(C)|\(seq.count)|\(mosV)|\(W)|\(escuro)|\(seq.hashValue)"
        if chave != geoChave {
            // se estava vendo as fotos de perto (3 colunas), continua EXATAMENTE no mesmo lugar depois de trocar
            let perto = ligada && !geoChave.isEmpty && abs(visiveis - n0) < 0.1
            let doFim = zoomer.contentSize.height - zoomer.contentOffset.y
            geoChave = chave
            montarPlano()
            if perto && !zerar {
                let sc = min(zoomer.maximumZoomScale, CGFloat(C) / max(1, min(CGFloat(C), n0)))
                zoomer.setZoomScale(sc, animated: false)
                travado = false
                let ins = zoomer.contentInset, cs = zoomer.contentSize
                let y = min(max(-ins.top, cs.height - doFim), cs.height - H + ins.bottom)
                zoomer.contentOffset = CGPoint(x: CGFloat(cS) * t0 * sc, y: y)
            } else { zerar = true }
        } else {
            // só a seleção mudou: redesenha só essas fotos
            let mudou = selAntes.symmetricDifference(selecao ? selecionados : [])
            for i in mudou { tiles.setNeedsDisplay(quadro(i)) }
        }
        if zerar { posicaoInicial() }
        atualizarGestos()
        atualizar()
    }

    private func montarPlano() {
        // segura a imagem antiga na tela enquanto a nova se desenha (sem piscar branco)
        if ligada, !vista.isHidden, plano.bounds.width > 0, let foto = vista.snapshotView(afterScreenUpdates: false) {
            vista.addSubview(foto)
            UIView.animate(withDuration: 0.25, delay: 0.45, options: []) { foto.alpha = 0 } completion: { _ in foto.removeFromSuperview() }
        }
        let t = t0
        tiles.dados = TilesMosaico.Dados(seq: seq, mos: mosIds, ini: ini, cols: C, linhas: linhas, t0: t)
        zoomer.zoomScale = 1
        plano.frame = CGRect(x: 0, y: 0, width: W, height: CGFloat(linhas) * t)
        tiles.frame = plano.bounds
        let faixa = CGRect(x: 0, y: CGFloat(primeira) * t, width: W, height: CGFloat(linhasMos) * t)
        tinta.frame = faixa
        magImg.frame = faixa
        tintaFaixa.frame = faixa
        tinta.isHidden = !temMos
        tintaFaixa.isHidden = !temMos
        magImg.isHidden = !temMos
        zoomer.contentSize = plano.frame.size
        zoomer.contentInset = UIEdgeInsets(top: cima, left: 0, bottom: sb + 70, right: 0)
        zoomer.minimumZoomScale = 1
        zoomer.maximumZoomScale = max(1.2, CGFloat(C) / max(1, min(CGFloat(C), n0)))
        if let p = zoomer.pinchGestureRecognizer, p.view !== capa { capa.addGestureRecognizer(p) }   // a pinça sempre na camada de toques
        tiles.setNeedsDisplay()
    }
    private func posicaoInicial() {
        travado = false
        zoomer.setZoomScale(min(zoomer.maximumZoomScale, CGFloat(C) / max(1, min(CGFloat(C), n0))), animated: false)
        irParaFim()
    }
    private func irParaFim() {
        let cs = zoomer.contentSize, ins = zoomer.contentInset
        let y = max(-ins.top, cs.height - H + ins.bottom)
        let x = CGFloat(cS) * t0 * zoomer.zoomScale
        zoomer.contentOffset = CGPoint(x: x, y: y)
    }

    /// imagem pequenina com 1 ponto de cor por foto (a cor do rosto), esticada sem borrar
    private var cS: Int { max(0, (C - Int(n0)) / 2) }
    private func imagemTinta(_ soFaixa: Bool) -> UIImage? {
        guard mosCols > 0, linhasMos > 0, mosTinta.count >= 3 else { return nil }
        let w = mosCols, h = linhasMos
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let c0 = max(0, (w - Int(n0)) / 2), c1 = c0 + Int(n0)
        for cel in 0..<(w * h) where cel * 3 + 2 < mosTinta.count {
            let c = cel % w, r = cel / w
            if soFaixa && (c < c0 || c >= c1 || r < h - faixaL) { continue }
            px[cel * 4] = mosTinta[cel * 3]; px[cel * 4 + 1] = mosTinta[cel * 3 + 1]; px[cel * 4 + 2] = mosTinta[cel * 3 + 2]; px[cel * 4 + 3] = 255
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: zoom
    func viewForZooming(in s: UIScrollView) -> UIView? { plano }
    func scrollViewDidZoom(_ s: UIScrollView) {
        centralizar()
        if trilho, let t = dadosTrilho, s.zoomScale >= 1 {
            // caminho fixo entre as fotos do começo e o rosto inteiro: desliza junto com a pinça, sem pulo
            let u = min(1, max(0, log(s.zoomScale) / log(max(1.0001, t.smax))))
            let sx = t.sf.x + (t.ss.x - t.sf.x) * u, sy = t.sf.y + (t.ss.y - t.sf.y) * u
            ajustando = true
            s.contentOffset = CGPoint(x: t.p.x * s.zoomScale - sx, y: t.p.y * s.zoomScale - sy)
            ajustando = false
        }
        atualizar()
        if travado && s.zoomScale > s.minimumZoomScale * 1.01 { travado = false; zoomer.isScrollEnabled = ligada && ativa }
    }
    /// rosto inteiro na tela: fica parado (só a pinça para aproximar funciona)
    private var travado = false
    private var trilho = false
    private var ajustando = false
    private var dadosTrilho: (p: CGPoint, sf: CGPoint, ss: CGPoint, smax: CGFloat)?
    private func offsetInicio(_ smax: CGFloat) -> CGPoint {
        let ins = zoomer.contentInset
        return CGPoint(x: CGFloat(cS) * t0 * smax, y: max(-ins.top, plano.bounds.height * smax - H + ins.bottom))
    }
    private func offsetRosto() -> CGPoint { CGPoint(x: -zoomer.contentInset.left, y: plano.bounds.height - H) }
    func scrollViewWillBeginZooming(_ s: UIScrollView, with v: UIView?) {
        trilho = false
        xTravado = nil
        guard temMos else { return }
        let smax = s.maximumZoomScale, oi = offsetInicio(smax), o = s.contentOffset
        let noInicio = abs(s.zoomScale - smax) < smax * 0.01 && abs(o.x - oi.x) < 6 && abs(o.y - oi.y) < 6
        guard travado || noInicio else { return }
        let ins = zoomer.contentInset
        let q = CGPoint(x: W / 2, y: (ins.top + H - ins.bottom) / 2)                  // meio da tela no começo
        let p = CGPoint(x: (oi.x + q.x) / smax, y: (oi.y + q.y) / smax)               // esse ponto na imagem
        let of = offsetRosto()
        dadosTrilho = (p, CGPoint(x: p.x - of.x, y: p.y - of.y), q, smax)
        trilho = true
    }
    func scrollViewDidEndZooming(_ s: UIScrollView, with v: UIView?, atScale e: CGFloat) {
        let eraTrilho = trilho
        trilho = false
        if eraTrilho && e >= s.maximumZoomScale * 0.99 {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { s.contentOffset = self.offsetInicio(s.maximumZoomScale) }
            return
        }
        guard temMos, e <= s.minimumZoomScale * 1.01 else { return }
        travado = true
        zoomer.isScrollEnabled = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { s.contentOffset = self.offsetRosto() }
    }
    /// arrastar só para cima e para baixo (como no app Fotos); de lado só a pinça mexe
    func scrollViewWillBeginDragging(_ s: UIScrollView) { if !s.isZooming { xTravado = s.contentOffset.x } }
    func scrollViewDidScroll(_ s: UIScrollView) {
        if let x = xTravado, !s.isZooming, !ajustando, s.contentOffset.x != x {
            ajustando = true; s.contentOffset.x = x; ajustando = false
        }
    }
    private func centralizar() {   // afastou demais: o rosto fica no meio enquanto volta
        let largura = plano.frame.width
        let dx = max(0, (W - largura) / 2)
        if zoomer.contentInset.left != dx {
            zoomer.contentInset = UIEdgeInsets(top: cima, left: dx, bottom: sb + 70, right: dx)
        }
    }
    private func suave(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { let u = min(1, max(0, (x - a) / (b - a))); return u * u * (3 - 2 * u) }
    private func atualizar() {
        let v = visiveis, k = zoomer.zoomScale
        let ramp = temMos ? suave(5, 13, v) : 0
        let mag: CGFloat = temMos ? min(1, max(0, (2.0 - k) / 0.6)) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        magImg.alpha = mag
        tinta.alpha = reforco * pow(ramp, 1.2) * (1 - mag)
        tintaFaixa.alpha = 0.55 * pow(ramp, 1.2)
        if corModo != "cor" && ramp > 0 {
            corCamada.frame = vista.bounds
            corCamada.backgroundColor = corModo == "sepia" ? UIColor(red: 0.44, green: 0.30, blue: 0.16, alpha: 1).cgColor : UIColor.gray.cgColor
            corCamada.opacity = Float(ramp * (corModo == "sepia" ? 0.9 : 1))
        } else { corCamada.opacity = 0 }
        CATransaction.commit()
    }

    // MARK: posições
    private func quadro(_ i: Int) -> CGRect {
        let t = t0
        return CGRect(x: CGFloat(i % C) * t, y: CGFloat(i / C) * t, width: t, height: t)
    }
    private func indice(_ p: CGPoint) -> Int {
        let t = t0
        let c = Int(floor(p.x / t)), r = Int(floor(p.y / t))
        if c < 0 || c >= C || r < 0 { return -1 }
        let i = r * C + c
        return i < seq.count ? i : -1
    }
    private func retangulo(_ i: Int) -> CGRect? {
        guard i >= 0, i < seq.count else { return nil }
        let q = plano.convert(quadro(i).insetBy(dx: t0 * 0.035, dy: t0 * 0.035), to: vista)
        return q.intersects(vista.bounds) ? q : nil
    }
    private func garantirVisivel(_ i: Int) {
        guard i >= 0, i < seq.count else { return }
        let q = plano.convert(quadro(i), to: vista)
        if q.minY >= cima - 10 && q.maxY <= H - sb - 70 && q.minX >= -2 && q.maxX <= W + 2 { return }
        let alvo = plano.convert(quadro(i), to: zoomer)
        let ins = zoomer.contentInset, cs = zoomer.contentSize
        let x = min(max(-ins.left, alvo.midX - W / 2), cs.width - W + ins.right)
        let y = min(max(-ins.top, alvo.midY - H / 2), cs.height - H + ins.bottom)
        zoomer.setContentOffset(CGPoint(x: x, y: y), animated: false)
    }
    private func irAoNivel(_ n: CGFloat) {
        travado = false; atualizarGestos()
        zoomer.setZoomScale(CGFloat(C) / max(1, min(CGFloat(C), n)), animated: false)
        irParaFim()
        atualizar()
    }

    // MARK: gestos
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive t: UITouch) -> Bool { ligada && ativa }
    @objc private func tocou(_ g: UITapGestureRecognizer) {
        let p = g.location(in: vista)
        let i = indice(g.location(in: plano))
        evento(["tipo": "gTap", "i": i, "x": p.x, "y": p.y, "noMosaico": temMos && visiveis > CGFloat(C) * 0.8])
    }

    // MARK: fotos (chamado pelos pedaços, fora da linha principal)
    private var pendentes = Set<String>(), falhas = Set<String>()
    private let travaPend = NSLock()
    private let filaImg: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 4; q.qualityOfService = .userInitiated; return q }()
    /// devolve na hora a melhor foto que já tem (a miniatura do disco é instantânea) e busca a nítida por trás
    func imagem(_ id: String, _ px: CGFloat, _ q: CGRect) -> CGImage? {
        let s = id.hasPrefix("arq:") ? 256 : (px <= 90 ? 64 : (px <= 300 ? 256 : 512))
        let k = "\(id)|\(s)" as NSString
        if let g = cache.object(forKey: k)?.img { return g }
        if s == 64 || id.hasPrefix("arq:") {
            guard let im = carregar(id, s) else { return nil }
            cache.setObject(Caixa(im), forKey: k, cost: im.width * im.height * 4)
            return im
        }
        travaPend.lock()
        let novo = !falhas.contains(k as String) && pendentes.insert(k as String).inserted
        travaPend.unlock()
        if novo {
            filaImg.addOperation { [weak self] in
                guard let self = self else { return }
                let im = self.carregar(id, s)
                if let im = im { self.cache.setObject(Caixa(im), forKey: k, cost: im.width * im.height * 4) }
                self.travaPend.lock(); self.pendentes.remove(k as String); if im == nil { self.falhas.insert(k as String) }; self.travaPend.unlock()
                if im == nil { return }
                DispatchQueue.main.async { self.tiles.setNeedsDisplay(q) }
            }
        }
        if s == 512, let g = cache.object(forKey: "\(id)|256" as NSString)?.img { return g }
        if let g = cache.object(forKey: "\(id)|64" as NSString)?.img { return g }
        guard let mini = carregar(id, 64) else { return nil }
        cache.setObject(Caixa(mini), forKey: "\(id)|64" as NSString, cost: mini.width * mini.height * 4)
        return mini
    }
    private func carregar(_ id: String, _ s: Int) -> CGImage? {
        if id.hasPrefix("arq:") {
            guard let im = UIImage(contentsOfFile: urlArq(String(id.dropFirst(4))).path) else { return nil }
            return quadrado(im, 256)
        }
        if s == 64, let im = UIImage(contentsOfFile: urlMini(id).path), let cg = im.cgImage { return cg }
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return s == 64 ? nil : carregar(id, 64)
        }
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        var saida: UIImage?
        let lado = CGFloat(s)
        gerente.requestImage(for: a, targetSize: CGSize(width: lado, height: lado), contentMode: .aspectFill, options: o) { im, _ in saida = im }
        guard let im = saida else { return s == 64 ? nil : carregar(id, 64) }
        return quadrado(im, lado)
    }
    private func quadrado(_ im: UIImage, _ lado: CGFloat) -> CGImage? {
        let sz = im.size
        guard sz.width > 0, sz.height > 0 else { return nil }
        let k = max(lado / sz.width, lado / sz.height), w = sz.width * k, h = sz.height * k
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: lado, height: lado), format: f).image { _ in
            im.draw(in: CGRect(x: (lado - w) / 2, y: (lado - h) / 2, width: w, height: h))
        }.cgImage
    }
}

/// Camada transparente que só fica com os toques fora dos botões da página.
final class CapaToques: UIView {
    var deixar: (CGPoint) -> Bool = { _ in false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, deixar(point) else { return nil }
        return self
    }
}

/// A imagem gigante: desenha só os pedaços que aparecem, no tamanho certo (como um mapa).
final class TilesMosaico: UIView {
    struct Dados { var seq: [String]; var mos: [String]; var ini: Int; var cols: Int; var linhas: Int; var t0: CGFloat }
    private let trava = NSLock()
    private var _dados: Dados?
    var dados: Dados? {
        get { trava.lock(); defer { trava.unlock() }; return _dados }
        set { trava.lock(); _dados = newValue; trava.unlock() }
    }
    private var _cores: (CGColor, CGColor) = (UIColor.black.cgColor, UIColor(white: 0.12, alpha: 1).cgColor)
    var cores: (CGColor, CGColor) {
        get { trava.lock(); defer { trava.unlock() }; return _cores }
        set { trava.lock(); _cores = newValue; trava.unlock() }
    }
    private var _marcas = Set<Int>()
    var marcas: Set<Int> {
        get { trava.lock(); defer { trava.unlock() }; return _marcas }
        set { trava.lock(); _marcas = newValue; trava.unlock() }
    }
    var carregar: ((String, CGFloat, CGRect) -> CGImage?)?
    override class var layerClass: AnyClass { CATiledLayerRapido.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        if let t = layer as? CATiledLayer {
            t.tileSize = CGSize(width: 512, height: 512)
            t.levelsOfDetail = 7
            t.levelsOfDetailBias = 6
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let d = dados, d.t0 > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        let (corFundo, corVazia) = cores, marcas = self.marcas
        ctx.setFillColor(corFundo)
        ctx.fill(rect)
        let escala = max(1, abs(ctx.ctm.a))
        let g = d.t0 * 0.07, lado = d.t0 - g
        let c0 = max(0, Int(floor(rect.minX / d.t0))), c1 = min(d.cols - 1, Int(floor(rect.maxX / d.t0)))
        let r0 = max(0, Int(floor(rect.minY / d.t0))), r1 = min(d.linhas - 1, Int(floor(rect.maxY / d.t0)))
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                let i = r * d.cols + c
                guard i < d.seq.count else { continue }
                let m = i - d.ini
                let id = (m >= 0 && m < d.mos.count && !d.mos[m].isEmpty) ? d.mos[m] : d.seq[i]
                let q = CGRect(x: CGFloat(c) * d.t0, y: CGFloat(r) * d.t0, width: lado, height: lado)
                if id.isEmpty { continue }
                if let im = carregar?(id, lado * escala, q) {
                    ctx.saveGState()
                    ctx.translateBy(x: q.minX, y: q.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .medium
                    ctx.draw(im, in: CGRect(x: 0, y: 0, width: lado, height: lado))
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(corVazia); ctx.fill(q)
                }
                if marcas.contains(i) {
                    let s = min(22, lado / 4), b = CGRect(x: q.maxX - s - lado * 0.04, y: q.maxY - s - lado * 0.04, width: s, height: s)
                    ctx.setFillColor(UIColor.white.cgColor); ctx.fillEllipse(in: b)
                    ctx.setFillColor(UIColor.systemBlue.cgColor); ctx.fillEllipse(in: b.insetBy(dx: s * 0.08, dy: s * 0.08))
                    ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(s * 0.11); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.move(to: CGPoint(x: b.minX + s * 0.28, y: b.midY)); ctx.addLine(to: CGPoint(x: b.minX + s * 0.44, y: b.minY + s * 0.66))
                    ctx.addLine(to: CGPoint(x: b.minX + s * 0.72, y: b.minY + s * 0.34)); ctx.strokePath()
                }
            }
        }
    }
}
final class CATiledLayerRapido: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0.08 }
}
