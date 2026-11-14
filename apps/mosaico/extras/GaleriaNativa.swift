import UIKit
import WebKit
import Photos

/// Fototeca feita com as peças do próprio iPhone (fica ATRÁS da página, que fica transparente na Fototeca).
/// - Grade (3, 5, 13 colunas): UICollectionView. A pinça usa a transição interativa do próprio iPhone
///   (cada foto anda da posição na grade antiga até a posição na nova, acompanhando os dedos).
/// - Depois de 13 colunas: o rosto ampliado (pedaços desenhados no tamanho certo), até o mosaico inteiro.
final class GaleriaNativa: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: peças
    let vista = UIView()
    private let capa = CapaToques()
    private var grade: UICollectionView!
    private let rolador = UIScrollView()        // física do arrastar no rosto ampliado
    private let magBox = UIView()
    private let magImg = UIImageView()
    private let magTiles = TilesMosaico()
    private let corCamada = CALayer()
    private var pincaG: UIPinchGestureRecognizer!
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

    // MARK: estado
    private var ligada = false
    private var ativa = true
    private var nivel: CGFloat = 3              // colunas da grade parada
    private var zoom: CGFloat = 3               // colunas "contínuas" (grade em transição ou rosto ampliado)
    private var doFim: CGFloat = 0
    private var ox: CGFloat = 0, oy: CGFloat = 0
    private var ajustando = false
    private var precisa = true
    private var anim: (de: CGFloat, para: CGFloat, t0: CFTimeInterval, fim: () -> Void)?

    // pinça
    private var anc: (i: Int, fx: CGFloat, fy: CGFloat, mx: CGFloat, my: CGFloat)?
    private var baseNivel: CGFloat = 3, baseEscala: CGFloat = 1
    private var trans: TransicaoGrade?
    private var transAlvo: CGFloat = 0
    private var transTerminando = false

    private let ZM0: CGFloat = 13, ZM1: CGFloat = 16.5
    private var W: CGFloat { vista.bounds.width }
    private var H: CGFloat { vista.bounds.height }
    private var cima: CGFloat { st + 96 }

    // MARK: imagens
    private final class Caixa { let img: CGImage; init(_ i: CGImage) { img = i } }
    private let cache: NSCache<NSString, Caixa> = { let c = NSCache<NSString, Caixa>(); c.countLimit = 6000; return c }()
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

        grade = UICollectionView(frame: vista.bounds, collectionViewLayout: LayoutGrade())
        grade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grade.backgroundColor = .clear
        grade.dataSource = self
        grade.delegate = self
        grade.register(CelulaFoto.self, forCellWithReuseIdentifier: "f")
        grade.contentInsetAdjustmentBehavior = .never
        grade.showsVerticalScrollIndicator = false
        grade.alwaysBounceVertical = true
        grade.scrollsToTop = false
        grade.isScrollEnabled = false
        vista.addSubview(grade)

        magBox.isUserInteractionEnabled = false
        magImg.contentMode = .scaleToFill
        magBox.addSubview(magTiles)
        magBox.addSubview(magImg)
        magBox.isHidden = true
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
        rolador.contentInsetAdjustmentBehavior = .never
        rolador.scrollsToTop = false
        rolador.isScrollEnabled = false
        vista.addSubview(rolador)
        webView.insertSubview(vista, at: 0)

        // camada invisível por cima da página: pega os gestos direto; nos botões da página deixa passar
        capa.frame = webView.bounds
        capa.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        capa.backgroundColor = .clear
        capa.isHidden = true
        capa.deixar = { [weak self] p in
            guard let s = self, s.ligada, s.ativa else { return false }
            return !s.zonas.contains { $0.contains(p) }
        }
        webView.addSubview(capa)
        capa.addGestureRecognizer(grade.panGestureRecognizer)
        capa.addGestureRecognizer(rolador.panGestureRecognizer)
        pincaG = UIPinchGestureRecognizer(target: self, action: #selector(pincou(_:)))
        pincaG.delegate = self
        capa.addGestureRecognizer(pincaG)
        toque = UITapGestureRecognizer(target: self, action: #selector(tocou(_:)))
        toque.delegate = self
        capa.addGestureRecognizer(toque)

        let l = CADisplayLink(target: self, selector: #selector(quadro))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
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
            r(["zoom": zoom, "mag": emMag, "k": kAtual], nil)
        default:
            return false
        }
        return true
    }

    private func atualizarGestos() {
        let pode = ligada && ativa
        pincaG.isEnabled = pode
        toque.isEnabled = pode
        grade.isScrollEnabled = pode && !modoMag && trans == nil
        rolador.isScrollEnabled = pode && emMag
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
        link?.isPaused = !on
        atualizarGestos()
        if on { precisa = true }
    }

    private func receberDados(_ m: [String: Any]) {
        let zerar = (m["zerar"] as? Bool) ?? false
        var seqMudou = false
        if let s = m["seq"] as? [String], s != seq { seq = s; seqMudou = true }
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
            if let a = c["ativa"] as? Bool { ativa = a }
        }
        vista.backgroundColor = escuro ? .black : .white
        magTiles.backgroundColor = vista.backgroundColor
        magTiles.reforco = reforco
        if trans != nil { cancelarTransicao(imediato: true) }
        if zerar { anim = nil; anc = nil; nivel = n0; zoom = n0; doFim = 0; ox = 0; oy = 0 }
        if !temMag && zoom > ZM0 { zoom = nivel }
        if ![3, 5, 13].contains(nivel) { nivel = 3 }
        aplicarLayout(nivel)
        if seqMudou || zerar { grade.reloadData() } else { atualizarCelulas() }
        grade.layoutIfNeeded()
        irParaFim()
        atualizarGestos()
        precisa = true
    }

    private func carregarMosaico() {
        guard let m = mos else { return }
        magImg.image = UIImage(contentsOfFile: urlArq(m.img).path)
        magTiles.dados = TilesMosaico.Dados(ids: m.ids, tinta: m.tinta, cols: m.cols, linhas: m.linhas, t0: W / CGFloat(m.cols))
        magTiles.carregar = { [weak self] id in self?.imagemSincrona(id) }
        magTiles.reforco = reforco
        magTiles.setNeedsDisplay()
    }

    // MARK: grade
    private func novoLayout(_ n: CGFloat) -> LayoutGrade {
        let l = LayoutGrade()
        l.cols = Int(n); l.cima = cima; l.pad = n <= 5 ? sb + 70 : 0; l.espaco = n <= 3 ? 2 : (n <= 5 ? 1.5 : 1)
        return l
    }
    private func aplicarLayout(_ n: CGFloat) {
        nivel = n
        grade.setCollectionViewLayout(novoLayout(n), animated: false)
    }
    private func irParaFim() {
        let alt = grade.collectionViewLayout.collectionViewContentSize.height
        ajustando = true
        grade.contentOffset = CGPoint(x: 0, y: max(0, alt - H - doFim))
        ajustando = false
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { seq.count }
    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "f", for: ip) as! CelulaFoto
        configurar(c, ip.item)
        return c
    }
    private func configurar(_ c: CelulaFoto, _ i: Int) {
        guard i < seq.count else { return }
        let it = seq[i]
        c.item = i
        let px = c.bounds.width * UIScreen.main.scale
        let img = it.isEmpty ? nil : imagem(it, max(px, W / nivel * UIScreen.main.scale))
        if let im = img { c.foto.image = UIImage(cgImage: im) } else if c.idFoto != it { c.foto.image = nil }
        c.idFoto = it
        c.foto.backgroundColor = img == nil ? UIColor(white: 0.5, alpha: 0.2) : nil
        c.marca.isHidden = !(selecao && selecionados.contains(i))
        pintar(c, i)
    }
    private func pintar(_ c: CelulaFoto, _ i: Int) {
        let ramp = mos == nil ? 0 : min(1, max(0, (zoom - 5) / (ZM0 - 5)))
        let a = reforco * pow(ramp, 1.2)
        if a > 0.01, let m = mos, i - m.ini >= 0, (i - m.ini) * 3 + 2 < m.tinta.count {
            let k = (i - m.ini) * 3
            c.tinta.isHidden = false
            c.tinta.backgroundColor = UIColor(red: CGFloat(m.tinta[k]) / 255, green: CGFloat(m.tinta[k + 1]) / 255, blue: CGFloat(m.tinta[k + 2]) / 255, alpha: 1)
            c.tinta.alpha = a
        } else { c.tinta.isHidden = true }
    }
    private func atualizarCelulas() {
        for c in grade.visibleCells { if let f = c as? CelulaFoto, f.item >= 0 { configurar(f, f.item) } }
    }
    func collectionView(_ cv: UICollectionView, transitionLayoutForOldLayout from: UICollectionViewLayout, newLayout to: UICollectionViewLayout) -> UICollectionViewTransitionLayout {
        TransicaoGrade(currentLayout: from, nextLayout: to)
    }

    // MARK: geometria
    private var temMag: Bool { mos != nil && magImg.image != nil }
    private var modoMag: Bool { temMag && zoom > ZM0 + 0.001 }
    private func suave(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { let u = min(1, max(0, (x - a) / (b - a))); return u * u * (3 - 2 * u) }
    private var mistura: CGFloat { modoMag ? suave(ZM0, ZM1, zoom) : 0 }
    private var emMag: Bool { mistura >= 1 }
    private var kAtual: CGFloat { mos.map { CGFloat($0.cols) / zoom } ?? 1 }

    private func pontoGrade(_ x: CGFloat, _ y: CGFloat) -> (i: Int, fx: CGFloat, fy: CGFloat) {
        let p = CGPoint(x: x, y: y + grade.contentOffset.y)
        guard let ip = grade.indexPathForItem(at: p) ?? vizinho(p), let a = grade.layoutAttributesForItem(at: ip) else { return (-1, 0.5, 0.5) }
        return (ip.item, (p.x - a.frame.minX) / max(1, a.frame.width), (p.y - a.frame.minY) / max(1, a.frame.height))
    }
    private func vizinho(_ p: CGPoint) -> IndexPath? {   // caiu no espacinho entre duas fotos
        for d in [CGPoint(x: -2, y: 0), CGPoint(x: 0, y: -2), CGPoint(x: -2, y: -2)] {
            if let ip = grade.indexPathForItem(at: CGPoint(x: p.x + d.x, y: p.y + d.y)) { return ip }
        }
        return nil
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
    /// põe a foto i da grade embaixo do ponto y
    private func gradeNaFoto(_ i: Int, _ fy: CGFloat, _ y: CGFloat) {
        guard i >= 0, i < seq.count, let a = grade.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { return }
        let alt = grade.collectionViewLayout.collectionViewContentSize.height
        let off = a.frame.minY + fy * a.frame.height - y
        ajustando = true
        grade.contentOffset = CGPoint(x: 0, y: max(0, min(max(0, alt - H), off)))
        ajustando = false
        doFim = max(0, alt - H - grade.contentOffset.y)
    }
    private func pontoAgora(_ x: CGFloat, _ y: CGFloat) -> (i: Int, fx: CGFloat, fy: CGFloat) {
        mistura >= 0.5 ? pontoMag(x, y) : pontoGrade(x, y)
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
            guard i < seq.count, let a = grade.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { return nil }
            q = a.frame.offsetBy(dx: 0, dy: -grade.contentOffset.y)
        }
        return q.intersects(vista.bounds) ? q : nil
    }
    private func garantirVisivel(_ i: Int) {
        guard i >= 0, i < seq.count, !modoMag, trans == nil, let a = grade.layoutAttributesForItem(at: IndexPath(item: i, section: 0)) else { return }
        let y = a.frame.minY - grade.contentOffset.y
        if y >= cima - 20 && y + a.frame.height <= H - (nivel <= 5 ? sb + 70 : 0) { return }
        gradeNaFoto(i, 0.5, H / 2)
    }
    private func irAoNivel(_ n: CGFloat) {
        anim = nil; anc = nil
        if trans != nil { cancelarTransicao(imediato: true) }
        zoom = n; doFim = 0
        aplicarLayout(n); grade.layoutIfNeeded(); irParaFim()
        atualizarGestos(); precisa = true
    }

    // MARK: rolar
    func scrollViewDidScroll(_ s: UIScrollView) {
        if ajustando || !ligada { return }
        if s === rolador {
            if modoMag { ox = -s.contentOffset.x; oy = -s.contentOffset.y; precisa = true }
        } else if s === grade, trans == nil {
            let alt = grade.collectionViewLayout.collectionViewContentSize.height
            doFim = max(0, alt - H - s.contentOffset.y)
        }
    }
    func scrollViewDidEndDecelerating(_ s: UIScrollView) { if s === grade { atualizarCelulas() } }
    private func montarRolador() {
        let k = kAtual
        ajustando = true
        rolador.contentSize = CGSize(width: W * max(1, k), height: H * max(1, k))
        rolador.contentOffset = CGPoint(x: -ox, y: -oy)
        ajustando = false
    }

    // MARK: gestos
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive t: UITouch) -> Bool { ligada && ativa }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { g === pincaG || o === pincaG }

    @objc private func tocou(_ g: UITapGestureRecognizer) {
        let p = g.location(in: vista)
        evento(["tipo": "gTap", "i": pontoAgora(p.x, p.y).i, "x": p.x, "y": p.y, "noMosaico": emMag && kAtual < 1.05])
    }

    @objc private func pincou(_ g: UIPinchGestureRecognizer) {
        let e = g.state == .began ? 0 : (g.state == .changed ? 1 : (g.state == .ended || g.state == .cancelled || g.state == .failed ? 2 : -1))
        if e >= 0 { pinca(e, g.location(in: vista), g.scale) }
    }
    private var pincaViva = false, escalaViva: CGFloat = 1
    /// e: 0 começou, 1 mudou, 2 soltou (também usado no teste automático)
    func pinca(_ e: Int, _ p: CGPoint, _ escala: CGFloat) {
        switch e {
        case 0:
            pincaViva = true; escalaViva = escala
            terminarAnim()
            grade.isScrollEnabled = false; rolador.isScrollEnabled = false
            let q = pontoAgora(p.x, p.y)
            anc = (q.i, q.fx, q.fy, p.x, p.y)
            baseNivel = modoMag ? zoom : nivel
            baseEscala = escala
        case 1:
            guard pincaViva else { return }
            escalaViva = escala
            anc?.mx = p.x; anc?.my = p.y
            let z = baseNivel / max(0.05, escala / baseEscala)   // colunas que a pinça pede
            pincaMudou(z, escala)
        default:
            guard pincaViva else { return }
            pincaViva = false
            soltou()
        }
    }

    private func pincaMudou(_ z: CGFloat, _ escala: CGFloat) {
        // 1) rosto ampliado
        if modoMag || (temMag && nivel == 13 && trans == nil && z > ZM0) {
            if !modoMag { baseNivel = ZM0; baseEscala = escala }
            zoom = min(CGFloat(mos!.cols) * 1.35, baseNivel / max(0.05, escala / baseEscala))
            if zoom <= ZM0 {   // voltou para a grade de 13: a mesma foto embaixo dos dedos
                zoom = ZM0
                if let a = anc { gradeNaFoto(a.i, a.fy, a.my) }
                baseNivel = 13; baseEscala = escala
            } else if let a = anc { magNaFoto(a.i, a.fx, a.fy, a.mx, a.my) }
            atualizarCelulas()
            precisa = true
            return
        }
        // 2) grade: transição interativa entre dois níveis
        let niveis: [CGFloat] = [3, 5, 13]
        if trans == nil {
            if transTerminando { return }
            let idx = niveis.firstIndex(of: nivel) ?? 0
            if z > nivel * 1.02, idx < niveis.count - 1 { comecarTransicao(para: niveis[idx + 1]) }
            else if z < nivel * 0.98, idx > 0 { comecarTransicao(para: niveis[idx - 1]) }
            else { return }
        }
        guard let t = trans, !transTerminando else { return }
        let de = nivel, para = transAlvo
        let prog = log(z / de) / log(para / de)
        if prog >= 1 {
            t.transitionProgress = 1
            terminarTransicao(true, escala: escala)
        } else if prog <= 0 {
            cancelarTransicao(imediato: false)
            baseEscala = escala
        } else {
            t.transitionProgress = prog
            t.ponto = anc.map { CGPoint(x: $0.mx, y: $0.my) } ?? .zero
            t.invalidateLayout()
            zoom = de * pow(para / de, prog)
        }
        precisa = true
    }

    private func comecarTransicao(para alvo: CGFloat) {
        transAlvo = alvo
        transTerminando = false
        let t = grade.startInteractiveTransition(to: novoLayout(alvo)) { [weak self] _, terminou in
            self?.transicaoAcabou(terminou)
        } as? TransicaoGrade
        trans = t
        t?.ancora = anc.map { IndexPath(item: max(0, min(seq.count - 1, $0.i)), section: 0) }
        t?.fx = anc?.fx ?? 0.5; t?.fy = anc?.fy ?? 0.5
        t?.ponto = anc.map { CGPoint(x: $0.mx, y: $0.my) } ?? .zero
    }
    private func terminarTransicao(_ sim: Bool, escala: CGFloat?) {
        guard trans != nil, !transTerminando else { return }
        transTerminando = true
        if let e = escala { baseEscala = e }
        if sim { grade.finishInteractiveTransition() } else { grade.cancelInteractiveTransition() }
    }
    private func cancelarTransicao(imediato: Bool) {
        guard let t = trans else { return }
        t.transitionProgress = 0
        terminarTransicao(false, escala: nil)
        if imediato { trans = nil; transTerminando = false; zoom = nivel }
    }
    private func transicaoAcabou(_ terminou: Bool) {
        let alvo = transAlvo
        trans = nil
        transTerminando = false
        if terminou { nivel = alvo }
        baseNivel = nivel
        zoom = nivel
        if let a = anc { gradeNaFoto(a.i, a.fy, a.my) }   // a foto presa continua embaixo dos dedos
        atualizarCelulas()
        if pincaViva { baseEscala = escalaViva } else { anc = nil }
        atualizarGestos()
        precisa = true
    }

    private func soltou() {
        if modoMag {
            if zoom < ZM1 { animar(log(zoom / ZM0) < log(ZM1 / zoom) ? ZM0 : ZM1) }
            else if kAtual < 1.25 { animar(CGFloat(mos!.cols)) }
            else { pararNoMag() }
            return
        }
        if let t = trans {
            if !transTerminando { terminarTransicao(t.transitionProgress > 0.5, escala: nil) }
            return
        }
        zoom = nivel
        anc = nil
        atualizarCelulas()
        atualizarGestos()
        precisa = true
    }
    private func pararNoMag() {
        anc = nil
        if modoMag { prenderMag(); montarRolador() } else { zoom = ZM0 }
        atualizarCelulas()
        atualizarGestos()
        precisa = true
    }
    private func animar(_ alvo: CGFloat) {
        anim = (zoom, alvo, CACurrentMediaTime(), { [weak self] in
            guard let s = self else { return }
            s.zoom = alvo
            if alvo > s.ZM0 { if let a = s.anc { s.magNaFoto(a.i, a.fx, a.fy, a.mx, a.my) }; s.prenderMag() }
            else if let a = s.anc { s.gradeNaFoto(a.i, a.fy, a.my) }
            s.pararNoMag()
        })
    }
    private func terminarAnim() { if let a = anim { anim = nil; a.fim() } }

    // MARK: desenho por quadro (rosto ampliado e cor)
    @objc private func quadro() {
        if let a = anim {
            let k = min(1, (CACurrentMediaTime() - a.t0) / 0.30), e = 1 - pow(1 - k, 3)
            zoom = a.de + (a.para - a.de) * CGFloat(e)
            if zoom > ZM0, let c = anc { magNaFoto(c.i, c.fx, c.fy, c.mx, c.my) }
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
        grade.alpha = 1 - b
        grade.isHidden = b >= 1
        if b > 0, let m = mos {
            let g = geo(), k = kAtual
            magBox.isHidden = false
            magBox.alpha = b
            magBox.transform = .identity
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
        let ramp = mos == nil ? 0 : min(1, max(0, (zoom - 5) / (ZM0 - 5)))
        if corModo != "cor" && ramp > 0 {
            corCamada.frame = vista.bounds
            corCamada.backgroundColor = corModo == "sepia" ? UIColor(red: 0.44, green: 0.30, blue: 0.16, alpha: 1).cgColor : UIColor.gray.cgColor
            corCamada.opacity = Float(ramp * (corModo == "sepia" ? 0.9 : 1))
        } else { corCamada.opacity = 0 }
        CATransaction.commit()
        for c in grade.visibleCells { if let f = c as? CelulaFoto, f.item >= 0 { pintar(f, f.item) } }
    }

    // MARK: fotos (miniatura do disco, ou a foto no tamanho certo)
    private func chave(_ id: String, _ s: Int) -> NSString { "\(id)|\(s)" as NSString }
    private func imagem(_ id: String, _ px: CGFloat) -> CGImage? {
        if id.hasPrefix("arq:") {
            if let g = cache.object(forKey: chave(id, 256))?.img { return g }
            pedir(id, 256); return nil
        }
        var mini = cache.object(forKey: chave(id, 64))?.img
        if mini == nil, let im = UIImage(contentsOfFile: urlMini(id).path)?.cgImage {   // miniatura do disco: na hora
            cache.setObject(Caixa(im), forKey: chave(id, 64)); mini = im
        }
        if mini == nil { pedir(id, 64) }
        if px <= 110 { return mini }
        let s = px <= 260 ? 256 : min(1400, Int(ceil(px / 128)) * 128)
        if let g = cache.object(forKey: chave(id, s))?.img { return g }
        pedir(id, s)
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
                DispatchQueue.main.async { self.atualizarCelulas() }
            }
        }
    }
    func imagemSincrona(_ id: String) -> CGImage? {
        if id.hasPrefix("arq:") {
            if let m = cache.object(forKey: chave(id, 256))?.img { return m }
            if let i = carregar(id, 256) { cache.setObject(Caixa(i), forKey: chave(id, 256)); return i }
            return nil
        }
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

// MARK: - peças da grade

/// Grade quadrada de n colunas, começando embaixo do título (igual à da página).
final class LayoutGrade: UICollectionViewLayout {
    var cols = 3
    var cima: CGFloat = 143
    var pad: CGFloat = 104
    var espaco: CGFloat = 2
    private var t: CGFloat { (collectionView?.bounds.width ?? 390) / CGFloat(max(1, cols)) }
    private var total: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }
    override var collectionViewContentSize: CGSize {
        let w = collectionView?.bounds.width ?? 390
        let linhas = ceil(CGFloat(total) / CGFloat(max(1, cols)))
        return CGSize(width: w, height: max(collectionView?.bounds.height ?? 0, cima + linhas * t + pad))
    }
    private func quadro(_ i: Int) -> CGRect {
        let r = i / cols, c = i % cols, lado = t, g = espaco
        return CGRect(x: CGFloat(c) * lado, y: cima + CGFloat(r) * lado, width: c == cols - 1 ? lado : lado - g, height: lado - g)
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let n = total
        guard n > 0, cols > 0 else { return [] }
        let r0 = max(0, Int(floor((rect.minY - cima) / t))), r1 = Int(floor((rect.maxY - cima) / t))
        guard r1 >= r0 else { return [] }
        var saida: [UICollectionViewLayoutAttributes] = []
        for r in r0...r1 {
            for c in 0..<cols {
                let i = r * cols + c
                if i >= n { break }
                let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
                a.frame = quadro(i)
                saida.append(a)
            }
        }
        return saida
    }
    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard ip.item < total else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: ip)
        a.frame = quadro(ip.item)
        return a
    }
    override func shouldInvalidateLayout(forBoundsChange b: CGRect) -> Bool { b.width != collectionView?.bounds.width }
}

/// Transição entre duas grades que mantém a foto presa embaixo dos dedos.
final class TransicaoGrade: UICollectionViewTransitionLayout {
    var ancora: IndexPath?
    var fx: CGFloat = 0.5, fy: CGFloat = 0.5
    var ponto: CGPoint = .zero
    private func desvio() -> CGPoint {
        guard let ip = ancora, let cv = collectionView, let a = super.layoutAttributesForItem(at: ip) else { return .zero }
        let quer = CGPoint(x: ponto.x + cv.contentOffset.x, y: ponto.y + cv.contentOffset.y)
        let esta = CGPoint(x: a.frame.minX + fx * a.frame.width, y: a.frame.minY + fy * a.frame.height)
        return CGPoint(x: quer.x - esta.x, y: quer.y - esta.y)
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let d = desvio()
        let atrs = super.layoutAttributesForElements(in: rect.offsetBy(dx: -d.x, dy: -d.y)) ?? []
        return atrs.map { o in
            let a = o.copy() as! UICollectionViewLayoutAttributes
            a.frame = a.frame.offsetBy(dx: d.x, dy: d.y)
            return a
        }
    }
    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let o = super.layoutAttributesForItem(at: ip) else { return nil }
        let d = desvio(), a = o.copy() as! UICollectionViewLayoutAttributes
        a.frame = a.frame.offsetBy(dx: d.x, dy: d.y)
        return a
    }
}

final class CelulaFoto: UICollectionViewCell {
    let foto = UIImageView()
    let tinta = UIView()
    let marca = UIImageView()
    var item = -1
    var idFoto = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        foto.contentMode = .scaleAspectFill
        foto.clipsToBounds = true
        foto.frame = contentView.bounds
        foto.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tinta.frame = contentView.bounds
        tinta.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tinta.isHidden = true
        tinta.isUserInteractionEnabled = false
        marca.image = UIImage(systemName: "checkmark.circle.fill")
        marca.tintColor = .systemBlue
        marca.backgroundColor = .white
        marca.clipsToBounds = true
        marca.isHidden = true
        contentView.addSubview(foto)
        contentView.addSubview(tinta)
        contentView.addSubview(marca)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(22, bounds.width / 4)
        marca.frame = CGRect(x: bounds.width - s - 4, y: bounds.height - s - 4, width: s, height: s)
        marca.layer.cornerRadius = s / 2
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
