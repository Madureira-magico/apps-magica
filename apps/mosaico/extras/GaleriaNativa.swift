import UIKit
import WebKit
import Photos

/// Fototeca feita com as peças do próprio iPhone (fica ATRÁS da página, que fica transparente na Fototeca).
/// A página continua mandando: lista de fotos, mosaico pronto, ajustes. A física (rolar, frear, quicar)
/// é a do UIScrollView; a pinça presa embaixo dos dedos e a dissolução entre níveis são feitas aqui.
final class GaleriaNativa: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: peças
    let vista = UIView()
    private let capa = CapaToques()                      // por cima da página: recebe os gestos direto
    private let rolador = UIScrollView()
    private let camadas = [CALayer(), CALayer()]          // dois níveis da grade (para dissolver)
    private let magBox = UIView()                         // rosto ampliado
    private let magImg = UIImageView()
    private let magTiles = TilesMosaico()
    private let corCamada = CALayer()                     // sépia / preto e branco
    private var pinca: UIPinchGestureRecognizer!
    private var toque: UITapGestureRecognizer!
    private var link: CADisplayLink?
    private weak var web: WKWebView?

    var urlMini: (String) -> URL = { _ in URL(fileURLWithPath: "/") }
    var urlArq: (String) -> URL = { _ in URL(fileURLWithPath: "/") }
    var evento: ([String: Any]) -> Void = { _ in }

    // MARK: dados vindos da página
    struct Mos {
        var ids: [String]; var tinta: [UInt8]; var cols: Int; var primeira: Int; var linhas: Int; var ultima: Int; var ini: Int
        var img: String; var v: String
    }
    private var seq: [String] = []
    private var mos: Mos?
    private var reforco: CGFloat = 0.4
    private var corModo = "cor"
    private var escuro = true
    private var n0: CGFloat = 3
    private var st: CGFloat = 47, sb: CGFloat = 34
    private var zonas: [CGRect] = []
    private var selecao = false
    private var selecionados = Set<Int>()

    // MARK: estado do zoom
    private var ligada = false
    private var ativa = true
    private var zoom: CGFloat = 3
    private var doFim: CGFloat = 0
    private var anc: (i: Int, fx: CGFloat, fy: CGFloat, mx: CGFloat, my: CGFloat)?
    private var ox: CGFloat = 0, oy: CGFloat = 0
    private var z0Pinca: CGFloat = 3
    private var ajustando = false
    private var precisa = true
    private var anim: (de: CGFloat, para: CGFloat, t0: CFTimeInterval, fim: () -> Void)?

    private let ZM0: CGFloat = 13, ZM1: CGFloat = 16.5
    private var W: CGFloat { vista.bounds.width }
    private var H: CGFloat { vista.bounds.height }
    private var cima: CGFloat { st + 96 }

    // MARK: imagens
    private final class Caixa { let img: CGImage; init(_ i: CGImage) { img = i } }
    private let cache: NSCache<NSString, Caixa> = { let c = NSCache<NSString, Caixa>(); c.countLimit = 5000; return c }()
    private var pendentes = Set<String>()
    private let travaPend = NSLock()
    private let filaImg: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 6; q.qualityOfService = .userInitiated; return q }()
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
        for c in camadas { vista.layer.addSublayer(c) }
        magBox.isUserInteractionEnabled = false
        magImg.contentMode = .scaleToFill
        magBox.addSubview(magTiles)
        magBox.addSubview(magImg)
        vista.addSubview(magBox)
        corCamada.compositingFilter = "colorBlendMode"
        corCamada.opacity = 0
        vista.layer.addSublayer(corCamada)
        rolador.frame = vista.bounds
        rolador.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rolador.alpha = 0.011
        rolador.delegate = self
        rolador.showsVerticalScrollIndicator = false
        rolador.showsHorizontalScrollIndicator = false
        rolador.alwaysBounceVertical = true
        rolador.contentInsetAdjustmentBehavior = .never
        rolador.scrollsToTop = false
        rolador.isScrollEnabled = false
        vista.addSubview(rolador)
        webView.insertSubview(vista, at: 0)
        // camada invisível por cima da página: pega os gestos direto (sem a página atrasar);
        // nos botões da página (título, barra de baixo, cantos...) ela deixa o toque passar
        capa.frame = webView.bounds
        capa.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        capa.backgroundColor = .clear
        capa.isHidden = true
        capa.deixar = { [weak self] p in
            guard let s = self, s.ligada, s.ativa else { return false }
            return !s.zonas.contains { $0.contains(p) }
        }
        webView.addSubview(capa)
        capa.addGestureRecognizer(rolador.panGestureRecognizer)
        pinca = UIPinchGestureRecognizer(target: self, action: #selector(pincou(_:)))
        pinca.delegate = self
        pinca.isEnabled = false
        capa.addGestureRecognizer(pinca)
        toque = UITapGestureRecognizer(target: self, action: #selector(tocou(_:)))
        toque.delegate = self
        toque.isEnabled = false
        toque.cancelsTouchesInView = false
        capa.addGestureRecognizer(toque)
        let l = CADisplayLink(target: self, selector: #selector(quadro))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
    }

    // MARK: recados da página (devolve true se era para a galeria)
    func recado(_ cmd: String, _ m: [String: Any], _ r: @escaping (Any?, String?) -> Void) -> Bool {
        func num(_ k: String, _ p: CGFloat) -> CGFloat { CGFloat((m[k] as? NSNumber)?.doubleValue ?? Double(p)) }
        switch cmd {
        case "galeria":
            let on = (m["on"] as? Bool) ?? false
            ativa = (m["ativa"] as? Bool) ?? true
            ligar(on)
            r(true, nil)
        case "galeriaDados":
            receberDados(m)
            r(true, nil)
        case "galeriaRect":
            let i = Int(num("i", -1))
            if let q = retangulo(i) { r([q.minX, q.minY, q.width, q.height], nil) } else { r(NSNull(), nil) }
        case "galeriaVer":
            garantirVisivel(Int(num("i", -1)))
            r(true, nil)
        case "galeriaNivel":
            irAoNivel(num("n", 3))
            r(true, nil)
        case "galeriaEstado":
            r(["zoom": zoom, "mag": emMag, "k": kAtual], nil)
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
        }
        vista.isHidden = !on
        capa.isHidden = !on
        if let w = web { w.bringSubviewToFront(capa) }
        pinca.isEnabled = on && ativa
        toque.isEnabled = on && ativa
        rolador.isScrollEnabled = on && ativa
        link?.isPaused = !on
        if on { vista.frame = web?.bounds ?? vista.frame; montarRolador(); precisa = true }
    }

    private func receberDados(_ m: [String: Any]) {
        let zerar = (m["zerar"] as? Bool) ?? false
        if let s = m["seq"] as? [String] { seq = s }
        if let d = m["mos"] as? [String: Any], let ids = d["ids"] as? [String] {
            let tinta = ((d["tinta"] as? [NSNumber]) ?? []).map { UInt8(clamping: $0.intValue) }
            let novo = Mos(ids: ids, tinta: tinta, cols: (d["cols"] as? NSNumber)?.intValue ?? 60,
                           primeira: (d["primeira"] as? NSNumber)?.intValue ?? 0, linhas: (d["linhas"] as? NSNumber)?.intValue ?? 0,
                           ultima: (d["ultima"] as? NSNumber)?.intValue ?? 0, ini: (d["ini"] as? NSNumber)?.intValue ?? 0,
                           img: (d["img"] as? String) ?? "", v: "\(d["v"] ?? "")")
            let mudou = mos == nil || mos!.v != novo.v || mos!.cols != novo.cols
            mos = novo
            if mudou { carregarMosaico() }
        } else if m["mos"] != nil {
            mos = nil
            magImg.image = nil
            magTiles.dados = nil
        }
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
            if let a = c["ativa"] as? Bool { ativa = a; pinca.isEnabled = ligada && a; toque.isEnabled = ligada && a; rolador.isScrollEnabled = ligada && a }
        }
        vista.backgroundColor = escuro ? .black : .white
        magTiles.backgroundColor = vista.backgroundColor
        magTiles.reforco = reforco
        if zerar { anc = nil; anim = nil; zoom = n0; doFim = 0; ox = 0; oy = 0 }
        if !niveis.contains(where: { abs($0 - zoom) < 0.001 }) && !(temMag && zoom > ZM0) { zoom = nivelPerto(zoom) }
        if !temMag && zoom > niveis.last! { zoom = niveis.last! }
        montarRolador()
        precisa = true
    }

    private func carregarMosaico() {
        guard let m = mos else { return }
        let url = urlArq(m.img)
        magImg.image = UIImage(contentsOfFile: url.path)
        magTiles.dados = TilesMosaico.Dados(ids: m.ids, tinta: m.tinta, cols: m.cols, linhas: m.linhas, t0: W / CGFloat(m.cols))
        magTiles.carregar = { [weak self] id in self?.imagemSincrona(id) }
        magTiles.reforco = reforco
        magTiles.setNeedsDisplay()
    }

    // MARK: geometria (igual à da página)
    private var niveis: [CGFloat] { temMag ? [3, 5, 13] : [3, 5, 13, 30] }
    private var temMag: Bool { mos != nil && magImg.image != nil }
    private func suave(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { let u = min(1, max(0, (x - a) / (b - a))); return u * u * (3 - 2 * u) }
    private var mistura: CGFloat { temMag ? suave(ZM0, ZM1, zoom) : 0 }
    private var emMag: Bool { mistura >= 1 }
    private var kAtual: CGFloat { mos.map { CGFloat($0.cols) / zoom } ?? 1 }
    private func padNivel(_ n: CGFloat) -> CGFloat { n <= 5 ? sb + 70 : 0 }
    private func nivelPerto(_ z: CGFloat) -> CGFloat {
        var m = niveis[0]
        for v in niveis where abs(log(v / z)) < abs(log(m / z)) { m = v }
        return m
    }
    private var nivelBase: CGFloat {
        let L = niveis
        if zoom <= L[0] { return L[0] }
        if zoom >= L[L.count - 1] { return L[L.count - 1] }
        return nivelPerto(zoom)
    }
    private func altura(_ n: CGFloat, _ t: CGFloat) -> CGFloat { cima + ceil(CGFloat(seq.count) / n) * t + padNivel(n) }

    private struct Lay { var n: Int; var t: CGFloat; var x0: CGFloat; var topo: CGFloat; var alt: CGFloat }
    private func layout(_ nf: CGFloat) -> Lay {
        let n = Int(nf), t = W / zoom, alt = altura(nf, t)
        var x0: CGFloat = 0, topo: CGFloat
        if let a = anc, a.i >= 0 {
            let r = CGFloat(a.i / n), c = CGFloat(a.i % n)
            x0 = a.mx - (c + a.fx) * t
            if nf * t >= W { x0 = min(0, max(W - nf * t, x0)) } else { x0 = max(0, min(W - nf * t, x0)) }
            topo = cima + (r + a.fy) * t - a.my
            topo = max(0, min(max(0, alt - H), topo))
        } else {
            topo = rolador.contentOffset.y   // parado: a posição é a do rolador (com o quique)
        }
        return Lay(n: n, t: t, x0: x0, topo: topo, alt: alt)
    }
    private func pontoNaGrade(_ L: Lay, _ x: CGFloat, _ y: CGFloat) -> (i: Int, fx: CGFloat, fy: CGFloat) {
        let cc = (x - L.x0) / L.t, rr = (y + L.topo - cima) / L.t
        let r = Int(floor(rr)), c = Int(floor(cc))
        return (r < 0 || c < 0 || c >= L.n ? -1 : r * L.n + c, cc - CGFloat(c), rr - CGFloat(r))
    }
    private func geo() -> (C: Int, t0: CGFloat, topo0: CGFloat) {
        let m = mos!, t0 = W / CGFloat(m.cols)
        return (m.cols, t0, max(0, cima + CGFloat(m.ultima + 1) * t0 - H))
    }
    private func pontoMag(_ x: CGFloat, _ y: CGFloat) -> (i: Int, fx: CGFloat, fy: CGFloat) {
        let g = geo(), k = kAtual
        let cc = ((x - ox) / k) / g.t0, rr = (((y - oy) / k) - cima + g.topo0) / g.t0
        let r = Int(floor(rr)), c = Int(floor(cc))
        return (c < 0 || c >= g.C || r < 0 ? -1 : r * g.C + c, cc - CGFloat(c), rr - CGFloat(r))
    }
    private func prenderMag() {
        let k = kAtual
        if k >= 1 { ox = min(0, max(W - W * k, ox)); oy = min(0, max(H - H * k, oy)) }
        else { ox = (W - W * k) / 2; oy = (H - H * k) / 2 }
    }
    private func magNaFoto(_ i: Int, _ fx: CGFloat, _ fy: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        guard let m = mos else { return }
        let g = geo(), k = kAtual, r = i / g.C, c = i % g.C
        if i < 0 || r < m.primeira || r > m.ultima { ox = (W - W * k) / 2; oy = H - H * k; prenderMag(); return }
        ox = x - (CGFloat(c) + fx) * g.t0 * k
        oy = y - (cima + (CGFloat(r) + fy) * g.t0 - g.topo0) * k
        prenderMag()
    }
    private func pontoAgora(_ x: CGFloat, _ y: CGFloat) -> (i: Int, fx: CGFloat, fy: CGFloat) {
        mistura >= 0.5 ? pontoMag(x, y) : pontoNaGrade(layout(nivelBase), x, y)
    }
    private func retangulo(_ i: Int) -> CGRect? {
        guard i >= 0 else { return nil }
        var q: CGRect
        if mistura >= 0.5, let m = mos {
            let g = geo(), k = kAtual, r = i / g.C, c = i % g.C
            if r < m.primeira || r > m.ultima { return nil }
            let s = g.t0 * k
            q = CGRect(x: CGFloat(c) * s + ox, y: (cima + CGFloat(r) * g.t0 - g.topo0) * k + oy, width: s, height: s)
        } else {
            let L = layout(nivelBase), r = i / L.n, c = i % L.n
            q = CGRect(x: L.x0 + CGFloat(c) * L.t, y: cima + CGFloat(r) * L.t - L.topo, width: L.t, height: L.t)
        }
        return q.intersects(vista.bounds) ? q : nil
    }
    private func garantirVisivel(_ i: Int) {
        guard i >= 0, anc == nil, mistura < 0.5 else { return }
        let n = nivelBase, L = layout(n), y = cima + CGFloat(i / L.n) * L.t - L.topo
        if y >= cima - 20 && y + L.t <= H - padNivel(n) { return }
        let topo = cima + CGFloat(i / L.n) * L.t - H / 2 + L.t / 2
        doFim = max(0, min(max(0, L.alt - H), L.alt - H - topo))
        montarRolador()
        precisa = true
    }
    private func irAoNivel(_ n: CGFloat) { anim = nil; anc = nil; zoom = n; doFim = 0; montarRolador(); precisa = true }

    /// Prepara o rolador para o estado parado atual (grade num nível, ou rosto ampliado).
    private func montarRolador() {
        guard W > 0 else { return }
        ajustando = true
        if temMag && zoom > ZM0 {
            let k = kAtual
            rolador.alwaysBounceHorizontal = k > 1.01
            rolador.contentSize = CGSize(width: W * max(1, k), height: H * max(1, k))
            rolador.contentOffset = CGPoint(x: -ox, y: -oy)
        } else {
            let n = nivelBase, t = W / zoom, alt = altura(n, t)
            rolador.alwaysBounceHorizontal = false
            rolador.contentSize = CGSize(width: W, height: max(H, alt))
            rolador.contentOffset = CGPoint(x: 0, y: max(0, alt - H - doFim))
        }
        ajustando = false
    }

    // MARK: física do rolador
    func scrollViewDidScroll(_ s: UIScrollView) {
        if ajustando || !ligada { return }
        if temMag && zoom > ZM0 {
            ox = -s.contentOffset.x; oy = -s.contentOffset.y
        } else {
            let alt = altura(nivelBase, W / zoom)
            doFim = max(0, alt - H - s.contentOffset.y)
        }
        precisa = true
    }

    // MARK: gestos
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive t: UITouch) -> Bool {
        guard ligada && ativa else { return false }
        if g === toque { let p = t.location(in: vista); return !zonas.contains { $0.contains(p) } }
        return true
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

    @objc private func pincou(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: vista)
        switch g.state {
        case .began:
            terminarAnim()
            rolador.isScrollEnabled = false
            let q = pontoAgora(p.x, p.y)
            anc = (q.i, q.fx, q.fy, p.x, p.y)
            z0Pinca = zoom
        case .changed:
            anc?.mx = p.x; anc?.my = p.y
            aplicarZoom(z0Pinca / max(0.05, g.scale))
            precisa = true
        case .ended, .cancelled, .failed:
            soltou()
            rolador.isScrollEnabled = ligada && ativa
        default: break
        }
    }
    @objc private func tocou(_ g: UITapGestureRecognizer) {
        let p = g.location(in: vista)
        let i = pontoAgora(p.x, p.y).i
        evento(["tipo": "gTap", "i": i, "x": p.x, "y": p.y, "noMosaico": emMag && kAtual < 1.05])
    }

    private func aplicarZoom(_ z: CGFloat) {
        let L = niveis
        zoom = min(temMag ? CGFloat(mos!.cols) * 1.35 : L[L.count - 1] * 1.15, max(L[0] * 0.8, z))
        if temMag && zoom > ZM0 {
            if let a = anc { magNaFoto(a.i, a.fx, a.fy, a.mx, a.my) } else { prenderMag() }
        }
    }
    private func soltou() {
        if temMag && zoom > ZM0 {
            if zoom < ZM1 { animar(log(zoom / ZM0) < log(ZM1 / zoom) ? ZM0 : ZM1) }
            else if kAtual < 1.25 { animar(CGFloat(mos!.cols)) }
            else { pararNoLugar() }
            return
        }
        animar(nivelPerto(zoom))
    }
    private func pararNoLugar() {
        if mistura < 1 {
            let n = nivelBase, L = layout(n)
            doFim = max(0, L.alt - H - L.topo)
        }
        anc = nil
        montarRolador()
        precisa = true
    }
    private func animar(_ alvo: CGFloat) {
        anim = (zoom, alvo, CACurrentMediaTime(), { [weak self] in
            guard let s = self else { return }
            s.aplicarZoom(alvo)
            s.zoom = alvo
            if s.temMag && alvo > s.ZM0 { s.prenderMag() }
            s.pararNoLugar()
        })
    }
    private func terminarAnim() {
        if let a = anim { anim = nil; a.fim() }
    }

    // MARK: desenho
    @objc private func quadro() {
        if let a = anim {
            let k = min(1, (CACurrentMediaTime() - a.t0) / 0.30), e = 1 - pow(1 - k, 3)
            aplicarZoom(a.de + (a.para - a.de) * CGFloat(e))
            precisa = true
            if k >= 1 { anim = nil; a.fim() }
        }
        if precisa { precisa = false; desenhar() }
    }

    private func desenhar() {
        guard ligada, W > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = mistura
        var usados = [0: false, 1: false]
        if b < 1 {
            let L = niveis, z = min(zoom, ZM0)
            if z <= L[0] || z >= L[L.count - 1] {
                desenharNivel(z <= L[0] ? L[0] : L[L.count - 1], camadas[0], 1 - b); usados[0] = true
            } else {
                var a = L[0], c = L[1]
                for k in 0..<(L.count - 1) where z >= L[k] && z <= L[k + 1] { a = L[k]; c = L[k + 1] }
                let u = log(z / a) / log(c / a), ab = suave(0.2, 0.8, u)
                desenharNivel(a, camadas[0], 1 - b); usados[0] = true
                if ab > 0.001 { desenharNivel(c, camadas[1], ab * (1 - b)); usados[1] = true }
            }
        }
        for (k, u) in usados where !u { limpar(camadas[k]) }
        // rosto ampliado
        if b > 0, let m = mos {
            let g = geo(), k = kAtual
            magBox.isHidden = false
            magBox.alpha = b
            magBox.bounds = CGRect(x: 0, y: 0, width: W, height: CGFloat(m.linhas) * g.t0)
            magImg.frame = magBox.bounds
            magTiles.frame = magBox.bounds
            let yTopo = (cima + CGFloat(m.primeira) * g.t0 - g.topo0) * k + oy
            magBox.transform = CGAffineTransform(scaleX: k, y: k)
            magBox.center = CGPoint(x: ox + W * k / 2, y: yTopo + magBox.bounds.height * k / 2)
            magImg.alpha = min(1, max(0, (2.0 - k) / 0.6))
            magTiles.isHidden = k < 1.35
        } else {
            magBox.isHidden = true
        }
        // sépia / preto e branco entrando aos poucos
        let ramp = mos == nil ? 0 : min(1, max(0, (zoom - 5) / (ZM0 - 5)))
        if corModo != "cor" && ramp > 0 {
            corCamada.frame = vista.bounds
            corCamada.backgroundColor = corModo == "sepia" ? UIColor(red: 0.44, green: 0.30, blue: 0.16, alpha: 1).cgColor : UIColor.gray.cgColor
            corCamada.opacity = Float(ramp * (corModo == "sepia" ? 0.9 : 1))
        } else { corCamada.opacity = 0 }
        CATransaction.commit()
    }

    private func espaco(_ z: CGFloat) -> CGFloat { z <= 3.2 ? 2 : z <= 5.5 ? 1.5 : z <= 15 ? 1 : 0.6 }

    private final class Ficha: CALayer {
        var item = ""
        let tinta = CALayer()
        let marca = CALayer()
        override init() {
            super.init()
            masksToBounds = true
            contentsGravity = .resizeAspectFill
            addSublayer(tinta)
            addSublayer(marca)
            marca.isHidden = true
        }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError() }
    }
    private var fichas: [ObjectIdentifier: [Int: Ficha]] = [:]
    private var sobras: [Ficha] = []
    private lazy var imgMarca: CGImage? = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        return r.image { c in
            let g = c.cgContext
            g.setFillColor(UIColor.systemBlue.cgColor); g.fillEllipse(in: CGRect(x: 2, y: 2, width: 44, height: 44))
            g.setStrokeColor(UIColor.white.cgColor); g.setLineWidth(4); g.strokeEllipse(in: CGRect(x: 2, y: 2, width: 44, height: 44))
            g.setLineCap(.round); g.setLineJoin(.round)
            g.move(to: CGPoint(x: 14, y: 25)); g.addLine(to: CGPoint(x: 21, y: 32)); g.addLine(to: CGPoint(x: 34, y: 17)); g.strokePath()
        }.cgImage
    }()

    private func limpar(_ c: CALayer) {
        let id = ObjectIdentifier(c)
        for (_, f) in fichas[id] ?? [:] { f.removeFromSuperlayer(); sobras.append(f) }
        fichas[id] = [:]
    }

    private func desenharNivel(_ nf: CGFloat, _ c: CALayer, _ alfa: CGFloat) {
        let L = layout(nf), t = L.t, g = espaco(zoom), lado = t - g, n = L.n
        let id = ObjectIdentifier(c)
        var atuais = fichas[id] ?? [:]
        var vistos = Set<Int>()
        c.opacity = Float(alfa)
        let r0 = max(0, Int(floor((L.topo - cima) / t))), r1 = min(Int(ceil(CGFloat(seq.count) / nf)) - 1, Int(floor((H + L.topo - cima) / t)))
        let px = t * UIScreen.main.scale
        let ramp = mos == nil || mos!.ids.isEmpty ? 0 : min(1, max(0, (zoom - 5) / (ZM0 - 5)))
        let a = reforco * pow(ramp, 1.2)
        if r0 <= r1 {
            for r in r0...r1 {
                let y = cima + CGFloat(r) * t - L.topo
                for col in 0..<n {
                    let i = r * n + col
                    if i >= seq.count { break }
                    let x = L.x0 + CGFloat(col) * t, it = seq[i]
                    if it.isEmpty || x > W || x + t < 0 { continue }
                    vistos.insert(i)
                    let f: Ficha
                    if let e = atuais[i] { f = e } else { f = sobras.popLast() ?? Ficha(); c.addSublayer(f); atuais[i] = f; f.item = ""; f.contents = nil }
                    f.frame = CGRect(x: x, y: y, width: lado, height: lado)
                    if let im = imagem(it, px) {
                        if f.item != it || f.contents == nil || (f.contents as! CGImage).width < im.width { f.contents = im; f.item = it }
                    } else if f.item != it {
                        f.contents = nil; f.item = it
                        f.backgroundColor = UIColor(white: 0.5, alpha: 0.18).cgColor
                    }
                    if f.contents != nil { f.backgroundColor = nil }
                    // retoque com a cor do pedaço do rosto
                    if a > 0.01, let m = mos, i - m.ini >= 0, (i - m.ini) * 3 + 2 < m.tinta.count {
                        let k = (i - m.ini) * 3
                        f.tinta.isHidden = false
                        f.tinta.frame = f.bounds
                        f.tinta.backgroundColor = UIColor(red: CGFloat(m.tinta[k]) / 255, green: CGFloat(m.tinta[k + 1]) / 255, blue: CGFloat(m.tinta[k + 2]) / 255, alpha: 1).cgColor
                        f.tinta.opacity = Float(a)
                    } else { f.tinta.isHidden = true }
                    if selecao && selecionados.contains(i) {
                        let s = min(24, lado / 4)
                        f.marca.isHidden = false
                        f.marca.contents = imgMarca
                        f.marca.frame = CGRect(x: lado - s - 4, y: lado - s - 4, width: s, height: s)
                        f.marca.backgroundColor = nil
                    } else { f.marca.isHidden = true }
                }
            }
        }
        for (i, f) in atuais where !vistos.contains(i) { f.removeFromSuperlayer(); sobras.append(f); atuais[i] = nil }
        fichas[id] = atuais
        if sobras.count > 600 { sobras.removeLast(sobras.count - 600) }
    }

    // MARK: fotos (miniatura do disco, ou a foto no tamanho certo)
    private func chave(_ id: String, _ s: Int) -> NSString { "\(id)|\(s)" as NSString }
    private func imagem(_ id: String, _ px: CGFloat) -> CGImage? {
        let mini = cache.object(forKey: chave(id, 64))?.img
        if mini == nil { pedir(id, 64) }
        if px <= 110 || id.hasPrefix("arq:") { return mini }
        let s = px <= 260 ? 256 : min(1400, Int(ceil(px / 128)) * 128)
        if let g = cache.object(forKey: chave(id, s))?.img { return g }
        pedir(id, s)
        // enquanto a maior não chega, usa a maior que já tem
        for o in [1400, 1280, 1152, 1024, 896, 768, 640, 512, 384, 256] where o < s {
            if let g = cache.object(forKey: chave(id, o))?.img { return g }
        }
        return mini
    }
    private func pedir(_ id: String, _ s: Int) {
        let k = "\(id)|\(s)"
        travaPend.lock()
        if pendentes.contains(k) { travaPend.unlock(); return }
        pendentes.insert(k)
        travaPend.unlock()
        filaImg.addOperation { [weak self] in
            guard let self = self else { return }
            let img = self.carregar(id, s)
            self.travaPend.lock(); self.pendentes.remove(k); self.travaPend.unlock()
            if let i = img {
                self.cache.setObject(Caixa(i), forKey: k as NSString)
                DispatchQueue.main.async { self.precisa = true }
            }
        }
    }
    /// usada também pelo rosto ampliado (em outra linha de execução)
    func imagemSincrona(_ id: String) -> CGImage? {
        if let m = cache.object(forKey: chave(id, 64))?.img { return m }
        if let i = carregar(id, 64) { cache.setObject(Caixa(i), forKey: chave(id, 64)); return i }
        return nil
    }
    private func carregar(_ id: String, _ s: Int) -> CGImage? {
        if id.hasPrefix("arq:") {
            guard let im = UIImage(contentsOfFile: urlArq(String(id.dropFirst(4))).path) else { return nil }
            return quadrado(im, 256)
        }
        if s == 64, let im = UIImage(contentsOfFile: urlMini(id).path), let cg = im.cgImage { return cg }
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = s > 64
        var saida: UIImage?
        let lado = CGFloat(max(s, 96))
        gerente.requestImage(for: a, targetSize: CGSize(width: lado, height: lado), contentMode: .aspectFill, options: o) { im, _ in saida = im }
        guard let im = saida else { return nil }
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

/// Rosto ampliado: desenha só os pedaços que aparecem, no tamanho certo (como um mapa).
final class TilesMosaico: UIView {
    struct Dados { var ids: [String]; var tinta: [UInt8]; var cols: Int; var linhas: Int; var t0: CGFloat }
    var dados: Dados? { didSet { setNeedsDisplay() } }
    var reforco: CGFloat = 0.4
    var carregar: ((String) -> CGImage?)?
    override class var layerClass: AnyClass { CATiledLayerRapido.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        if let t = layer as? CATiledLayer {
            t.tileSize = CGSize(width: 256, height: 256)
            t.levelsOfDetail = 4
            t.levelsOfDetailBias = 4
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let d = dados, d.t0 > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor((backgroundColor ?? .black).cgColor)
        ctx.fill(rect)
        let g = d.t0 * 0.07, lado = d.t0 - g, ref = reforco
        let c0 = max(0, Int(floor(rect.minX / d.t0))), c1 = min(d.cols - 1, Int(floor(rect.maxX / d.t0)))
        let r0 = max(0, Int(floor(rect.minY / d.t0))), r1 = min(d.linhas - 1, Int(floor(rect.maxY / d.t0)))
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                let cel = r * d.cols + c
                guard cel < d.ids.count else { continue }
                let id = d.ids[cel]
                if id.isEmpty { continue }
                let q = CGRect(x: CGFloat(c) * d.t0, y: CGFloat(r) * d.t0, width: lado, height: lado)
                if let im = carregar?(id) {
                    ctx.saveGState()
                    ctx.translateBy(x: q.minX, y: q.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(im, in: CGRect(x: 0, y: 0, width: lado, height: lado))
                    ctx.restoreGState()
                }
                if ref > 0.01, cel * 3 + 2 < d.tinta.count {
                    ctx.setFillColor(red: CGFloat(d.tinta[cel * 3]) / 255, green: CGFloat(d.tinta[cel * 3 + 1]) / 255, blue: CGFloat(d.tinta[cel * 3 + 2]) / 255, alpha: ref)
                    ctx.fill(q)
                }
            }
        }
    }
}
final class CATiledLayerRapido: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0.08 }
}
