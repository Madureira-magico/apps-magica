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
    private var tiles = TilesMosaico()      // camada 1: a grade (trocada inteira a cada mosaico novo: nada de camadas velhas guardadas)
    private let tilesB = TilesMosaico()     // camada 2: o mosaico do rosto (aparece dissolvendo ao afastar)
    private var bAtual: CGFloat = 0
    private let tinta = UIImageView()
    private let fundo = UIImageView()
    private let linhasCam = CAShapeLayer()
    private let baseMos = UIImageView()       // o mosaico pronto (miniatura) por baixo: onde a grade ainda não se desenhou, aparece ele (nunca preto)
    private let pinca = UIPinchGestureRecognizer()
    private var pinchando = false, pS0: CGFloat = 1, pAnc = CGPoint.zero
    private var pBase: CGFloat = 1, pToques = 2, pLivre = CGPoint.zero   // base da escala, dedos na tela, lugar sem a ajuda
    private var descer = true                                             // a ajuda na volta também desce até as 18 fotos
    private var animador: CADisplayLink?
    private var anim: (t0: CFTimeInterval, dur: Double, s0: CGFloat, s1: CGFloat, o0: CGPoint, o1: CGPoint)?
    private var fundoChave = ""
    private let tintaFaixa = UIImageView()   // pinta forte as fotos do começo quando o rosto aparece
    private let cobre = UIView()             // esconde as fotos de cima da cabeça quando o rosto aparece
    private let cobreBaixo = UIView()        // e as de baixo do rosto (a primeira tela)
    private var naFace = false
    private var xTravado: CGFloat?
    private let magImg = UIImageView()
    private let realImg = UIImageView()     // a foto real, grudada no mosaico (mesmo lugar e tamanho do rosto montado)
    private var realRow: CGFloat = 0, realRows: CGFloat = 0
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
    private var momento: CGFloat = 5       // 0 = troca mais cedo, 10 = mais tarde
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
        zoomer.bouncesZoom = false   // o rosto para exatamente na largura da tela (sem encolher além e voltar)
        zoomer.alwaysBounceVertical = true
        zoomer.alwaysBounceHorizontal = false
        zoomer.bounces = true
        zoomer.decelerationRate = .normal
        zoomer.addSubview(plano)
        fundo.contentMode = .scaleToFill
        fundo.isUserInteractionEnabled = false
        baseMos.contentMode = .scaleToFill
        baseMos.isUserInteractionEnabled = false
        plano.addSubview(baseMos)
        plano.addSubview(fundo)   // fotos de baixo já prontas (em miniatura) enquanto a grade de verdade se desenha por cima
        plano.addSubview(tiles)
        tilesB.isHidden = true
        plano.addSubview(tilesB)
        tinta.layer.magnificationFilter = .nearest
        tinta.isUserInteractionEnabled = false
        plano.addSubview(tinta)
        magImg.contentMode = .scaleToFill
        plano.addSubview(magImg)
        tintaFaixa.layer.magnificationFilter = .nearest
        tintaFaixa.isUserInteractionEnabled = false
        plano.addSubview(tintaFaixa)
        cobre.isUserInteractionEnabled = false
        plano.addSubview(cobre)
        cobreBaixo.isUserInteractionEnabled = false
        cobreBaixo.isHidden = true
        plano.addSubview(cobreBaixo)
        realImg.contentMode = .scaleToFill
        realImg.alpha = 0
        realImg.isUserInteractionEnabled = false
        plano.addSubview(realImg)
        vista.addSubview(zoomer)
        linhasCam.fillRule = .evenOdd
        linhasCam.actions = ["path": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
        vista.layer.addSublayer(linhasCam)   // a linha entre as fotos, por cima, desenhada na tela (muda suave, sem piscar)
        corCamada.compositingFilter = "colorBlendMode"
        corCamada.opacity = 0
        vista.layer.addSublayer(corCamada)
        tiles.carregar = { [weak self] id, px, q in self?.imagem(id, px, q, nil) }
        tilesB.carregar = { [weak self] id, px, q in self?.imagem(id, px, q, true) }
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
        zoomer.panGestureRecognizer.maximumNumberOfTouches = 1   // dois dedos = pinça (a pinça acompanha os dedos sozinha)
        capa.addGestureRecognizer(zoomer.panGestureRecognizer)
        zoomer.pinchGestureRecognizer?.isEnabled = false   // a pinça é nossa (sem brigar com o iPhone: nada treme)
        pinca.addTarget(self, action: #selector(pincou(_:)))
        pinca.delegate = self
        capa.addGestureRecognizer(pinca)
        toque = UITapGestureRecognizer(target: self, action: #selector(tocou(_:)))
        toque.delegate = self
        capa.addGestureRecognizer(toque)
        let seg = UILongPressGestureRecognizer(target: self, action: #selector(segurou(_:)))
        seg.minimumPressDuration = 2.0
        seg.allowableMovement = 12
        seg.delegate = self
        capa.addGestureRecognizer(seg)
    }
    @objc private func segurou(_ g: UILongPressGestureRecognizer) {
        if g.state == .began {
            evento(["tipo": "gHold", "on": true, "i": indice(g.location(in: plano))])
        } else if g.state == .ended || g.state == .cancelled || g.state == .failed {
            evento(["tipo": "gHold", "on": false])
        }
    }
    /// troca a miniatura de uma foto por outra enquanto segura (i = -1 desfaz)
    private var troca: (i: Int, orig: String)?
    private func trocar(_ i: Int, _ id: String) {
        guard var d = tiles.dados else { return }
        if let t = troca, t.i < d.seq.count { d.seq[t.i] = t.orig; tiles.dados = d; tiles.setNeedsDisplay(quadro(t.i)); troca = nil }
        guard i >= 0, i < d.seq.count, !id.isEmpty else { return }
        troca = (i, d.seq[i])
        for t in [64, 256, 512] { cache.removeObject(forKey: "\(id)|\(t)" as NSString) }   // a foto do famoso muda a cada nome
        d.seq[i] = id
        tiles.dados = d
        tiles.setNeedsDisplay(quadro(i))
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
        case "galeriaTroca":
            trocar(Int(num("i", -1)), (m["id"] as? String) ?? "")
            r(true, nil)
        case "galeriaInicio":   // volta às 18 fotos (3 colunas, lá embaixo) e mostra elas já desenhadas, inteiras
            posicaoInicial()
            mostrarCapaInicio()
            r(true, nil)
        case "galeriaCapa":    // voltando de uma foto aberta: a tela pronta por cima enquanto a grade termina de se desenhar
            if visiveis <= 8 { mostrarCapaInicio() }
            r(true, nil)
        case "galeriaReal":
            realImg.alpha = max(0, min(1, num("a", 0)))
            r(true, nil)
        case "galeriaEstado":
            r(["zoom": visiveis, "mag": temMos && visiveis > 13.5, "k": zoomer.zoomScale,
               "C": C, "seq": seq.count, "linhas": linhas, "mos": temMos, "ligada": ligada, "oculta": vista.isHidden,
               "y": Int(zoomer.contentOffset.y), "alt": Int(zoomer.contentSize.height), "planoH": Int(plano.bounds.height)], nil)
        default:
            return false
        }
        return true
    }

    /// "capa" com a primeira tela já pronta: as fotos aparecem inteiras na hora, enquanto a grade termina de se desenhar por baixo
    private let capaInicio = UIImageView()
    private func mostrarCapaInicio() {
        guard let d = tiles.dados, d.t0 > 0, vista.bounds.width > 0 else { return }
        let z = zoomer.zoomScale, off = zoomer.contentOffset, B = vista.bounds
        let px = z * UIScreen.main.scale
        let (gp, rp) = TilesMosaico.vao(d.t0 * px)
        let g: CGFloat = gp / px, lado = d.t0 - g, raio = rp / px * z
        let visivel = CGRect(x: off.x / z, y: off.y / z, width: B.width / z, height: B.height / z)
        let c0 = max(0, Int(floor(visivel.minX / d.t0))), c1 = min(d.cols - 1, Int(floor(visivel.maxX / d.t0)))
        let r0 = max(0, Int(floor(visivel.minY / d.t0))), r1 = min(d.linhas - 1, Int(floor(visivel.maxY / d.t0)))
        guard c0 <= c1, r0 <= r1 else { return }
        let (corFundo, _) = tiles.cores
        let fmt = UIGraphicsImageRendererFormat.preferred()
        let t0c = CACurrentMediaTime()
        let img = UIGraphicsImageRenderer(size: B.size, format: fmt).image { cx in
            let ctx = cx.cgContext
            ctx.setFillColor(corFundo); ctx.fill(CGRect(origin: .zero, size: B.size))
            for r in r0...r1 {
                for c in c0...c1 {
                    let i = r * d.cols + c
                    guard i < d.seq.count else { continue }
                    let m = i - d.ini
                    let id = (m >= 0 && m < d.mos.count && !d.mos[m].isEmpty) ? d.mos[m] : d.seq[i]
                    guard !id.isEmpty else { continue }
                    let q = CGRect(x: CGFloat(c) * d.t0 * z - off.x, y: CGFloat(r) * d.t0 * z - off.y, width: lado * z, height: lado * z)
                    let k512 = cache.object(forKey: "\(id)|512" as NSString)?.img, k256 = cache.object(forKey: "\(id)|256" as NSString)?.img
                    var im = k512 ?? k256
                    if im == nil, CACurrentMediaTime() - t0c < 0.45, let novo = carregar(id, 256) { cache.setObject(Caixa(novo), forKey: "\(id)|256" as NSString, cost: novo.width * novo.height * 4); im = novo }
                    if im == nil { im = cache.object(forKey: "\(id)|64" as NSString)?.img ?? carregar(id, 64) }   // sem tempo: a miniatura (a grade completa por baixo)
                    guard let cg = im else { continue }
                    // recorte quadrado do meio (como a grade)
                    let w = CGFloat(cg.width), h = CGFloat(cg.height), l = min(w, h)
                    if let quad = cg.cropping(to: CGRect(x: (w - l) / 2, y: (h - l) / 2, width: l, height: l)) {
                        ctx.saveGState()
                        if raio > 0 { ctx.addPath(UIBezierPath(roundedRect: q, cornerRadius: raio).cgPath); ctx.clip() }
                        UIImage(cgImage: quad).draw(in: q)
                        ctx.restoreGState()
                    }
                }
            }
        }
        capaInicio.image = img
        capaInicio.frame = visivel   // dentro da grade: anda junto com o dedo (nada some no primeiro deslize)
        capaInicio.alpha = 1
        capaInicio.isUserInteractionEnabled = false
        if capaInicio.superview !== plano { capaInicio.removeFromSuperview(); plano.insertSubview(capaInicio, aboveSubview: tilesB) }
        capaVez += 1; let v = capaVez
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.capaVez == v { self?.tirarCapaInicio() } }
    }
    private var capaVez = 0
    private func tirarCapaInicio() {   // sai sem fade: está no mesmo lugar da grade de verdade
        guard capaInicio.superview != nil else { return }
        capaVez += 1
        capaInicio.removeFromSuperview()
    }
    private func ligar(_ on: Bool) {
        if !on { capaInicio.removeFromSuperview(); capaVez += 1 }
        if on && !ligada && mudouFechada { mudouFechada = false; tiles.setNeedsDisplay() }   // mudou com a galeria fechada: redesenha ao abrir
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
        atualizarLinhas()
    }
    private func atualizarGestos() {
        let pode = ligada && ativa
        toque.isEnabled = pode
        zoomer.isScrollEnabled = pode && !travado
        zoomer.pinchGestureRecognizer?.isEnabled = false
        pinca.isEnabled = pode
    }

    private func receberDados(_ m: [String: Any]) {
        var zerar = (m["zerar"] as? Bool) ?? false
        // onde a pessoa está, ANTES de qualquer mudança (em colunas e fileiras, para continuar no mesmo lugar)
        let csA = zoomer.contentSize, oA = zoomer.contentOffset, cA = max(1, C), cSA = cS
        let celA = csA.width / CGFloat(cA)                       // tamanho de uma coluna na tela
        let colsA = W / max(0.0001, celA)                         // colunas na tela
        let colA = celA > 0 ? (oA.x + W / 2) / celA - CGFloat(cSA) : 0      // meio da tela, contado a partir da faixa
        let filA = celA > 0 ? (csA.height - (oA.y + H / 2)) / celA : 0       // meio da tela, em fileiras a partir de baixo
        if let s = m["seq"] as? [String] { seq = s }
        if let d = m["mos"] as? [String: Any], let ids = d["ids"] as? [String] {
            mosIds = ids
            mosTinta = ((d["tinta"] as? [NSNumber]) ?? []).map { UInt8(clamping: $0.intValue) }
            mosCols = (d["cols"] as? NSNumber)?.intValue ?? 60
            primeira = (d["primeira"] as? NSNumber)?.intValue ?? 0
            linhasMos = (d["linhas"] as? NSNumber)?.intValue ?? 0
            ini = (d["ini"] as? NSNumber)?.intValue ?? 0
            faixaL = (d["faixaL"] as? NSNumber)?.intValue ?? 0
            colS = (d["cS"] as? NSNumber)?.intValue ?? 0
            realRow = CGFloat((d["realRow"] as? NSNumber)?.doubleValue ?? 0)
            realRows = CGFloat((d["realRows"] as? NSNumber)?.doubleValue ?? 0)
            let real = (d["real"] as? String) ?? ""
            let img = (d["img"] as? String) ?? "", v = "\(d["v"] ?? "")"
            if v != mosV || img != mosImg || magImg.image == nil {
                mosImg = img; mosV = v
                magImg.image = UIImage(contentsOfFile: urlArq(img).path)
                realImg.image = real.isEmpty ? nil : UIImage(contentsOfFile: urlArq(real).path)
                realImg.alpha = 0
                tinta.image = imagemTinta(false)
                tintaFaixa.image = imagemTinta(true)
            }
        } else if m["mos"] != nil {
            mosIds = []; mosTinta = []; mosCols = 0; mosV = ""
            magImg.image = nil; tinta.image = nil; tintaFaixa.image = nil
            realImg.image = nil; realImg.alpha = 0
        }
        let selAntes = selecao ? selecionados : []
        if let c = m["cfg"] as? [String: Any] {
            reforco = CGFloat((c["reforco"] as? NSNumber)?.doubleValue ?? 0.4)
            momento = CGFloat((c["momento"] as? NSNumber)?.doubleValue ?? 5)
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
            ajuda = CGFloat((c["ajuda"] as? NSNumber)?.doubleValue ?? 3)
            descer = (c["descer"] as? Bool) ?? true
        }
        vista.backgroundColor = escuro ? .black : .white
        tiles.backgroundColor = .clear
        tiles.cores = (escuro ? UIColor.black.cgColor : UIColor.white.cgColor, escuro ? UIColor(white: 0.12, alpha: 1).cgColor : UIColor(white: 0.9, alpha: 1).cgColor)
        tilesB.backgroundColor = vista.backgroundColor
        tilesB.cores = tiles.cores
        tiles.marcas = selecao ? selecionados : []

        // monta a imagem gigante
        C = temMos ? mosCols : max(1, Int(n0))
        linhas = Int(ceil(Double(seq.count) / Double(max(1, C))))
        let chave = "\(C)|\(seq.count)|\(mosV)|\(W)|\(escuro)|\(seq.hashValue)|\(cS)"
        var refez = false
        if chave != geoChave {
            let manter = !geoChave.isEmpty && csA.width > 0 && celA > 0 && !zerar   // também com uma foto aberta por cima
            geoChave = chave
            montarPlano()
            refez = true
            if manter {
                // mesmas colunas na tela, mesmo ponto da faixa no meio, mesmas fileiras a partir de baixo
                let sc = min(zoomer.maximumZoomScale, max(zoomer.minimumZoomScale, CGFloat(C) / max(0.0001, colsA)))
                zoomer.setZoomScale(sc, animated: false)
                centralizar()
                let cs = zoomer.contentSize, cel = cs.width / CGFloat(max(1, C))
                xTravado = nil
                ajustando = true
                zoomer.contentOffset = limitar(CGPoint(x: (colA + CGFloat(cS)) * cel - W / 2, y: cs.height - filA * cel - H / 2))
                ajustando = false
                if !travado { zoomer.isScrollEnabled = ligada && ativa }
            } else { zerar = true }
        } else {
            // só a seleção mudou: redesenha só essas fotos
            let mudou = selAntes.symmetricDifference(selecao ? selecionados : [])
            for i in mudou { tiles.setNeedsDisplay(quadro(i)) }
        }
        if zerar { posicaoInicial() }
        atualizarGestos()
        atualizar()
        // grade refeita com a Fototeca aberta: a tela pronta (mesmas fotos, mesmo lugar) fica por cima enquanto a grade nova se desenha
        if refez, ligada, !vista.isHidden, visiveis <= 8 { mostrarCapaInicio() }
    }

    private var mudouFechada = false
    private func montarPlano() {
        if !ligada { mudouFechada = true }
        tirarCapaInicio()   // a capa é da grade antiga
        let t = t0
        // a galeria JÁ É o mosaico: as fotos do rosto entram direto na camada de fotos (nada por cima, nada troca)
        var seq1 = seq
        if temMos { for (k, id) in mosIds.enumerated() where ini + k < seq1.count && !id.isEmpty { seq1[ini + k] = id } }
        if tiles.dados != nil, let pai = tiles.superview {
            // o iPhone às vezes guarda pedaços do desenho antigo em outros tamanhos de zoom (aparecem num salto):
            // uma grade nova, sem nada guardado
            let novo = TilesMosaico()
            novo.carregar = tiles.carregar
            novo.cores = tiles.cores
            novo.marcas = tiles.marcas
            novo.backgroundColor = .clear
            novo.pxPerto = tiles.pxPerto
            pai.insertSubview(novo, aboveSubview: tiles)
            tiles.removeFromSuperview()
            tiles = novo
        }
        tiles.dados = TilesMosaico.Dados(seq: seq1, mos: [], ini: 0, cols: C, linhas: linhas, t0: t)
        if temMos { aquecer(seq1) }
        var idsB = [String](repeating: "", count: C * linhas)
        if temMos { for (k, id) in mosIds.enumerated() where ini + k < idsB.count { idsB[ini + k] = id } }
        tilesB.dados = TilesMosaico.Dados(seq: idsB, mos: [], ini: 0, cols: C, linhas: linhas, t0: t)
        zoomer.zoomScale = 1
        plano.frame = CGRect(x: 0, y: 0, width: W, height: CGFloat(linhas) * t)
        tiles.frame = plano.bounds
        tilesB.frame = plano.bounds
        tiles.setNeedsDisplay()
        tilesB.setNeedsDisplay()
        let faixa = CGRect(x: 0, y: CGFloat(primeira) * t, width: W, height: CGFloat(linhasMos) * t)
        tinta.frame = faixa
        magImg.frame = faixa
        baseMos.frame = faixa
        baseMos.image = temMos ? magImg.image : nil
        baseMos.isHidden = !temMos
        tintaFaixa.frame = faixa
        cobre.frame = CGRect(x: -W, y: -H * 4, width: W * 3, height: H * 4 + CGFloat(primeira) * t)
        cobre.backgroundColor = vista.backgroundColor
        cobre.isHidden = !temMos
        let fimRosto = CGFloat(primeira + linhasMos) * t
        cobreBaixo.frame = CGRect(x: -W, y: fimRosto, width: W * 3, height: max(0, CGFloat(linhas) * t - fimRosto) + H * 4)
        cobreBaixo.backgroundColor = vista.backgroundColor
        cobreBaixo.isHidden = true   // as fotos de baixo do rosto ficam sempre (a "gravata" do original)
        tinta.isHidden = !temMos
        tintaFaixa.isHidden = !temMos
        magImg.isHidden = !temMos
        realImg.frame = CGRect(x: 0, y: realRow * t, width: W, height: realRows * t)
        realImg.isHidden = !temMos || realImg.image == nil
        zoomer.contentSize = plano.frame.size
        zoomer.contentInset = UIEdgeInsets(top: cima, left: 0, bottom: sb + 70, right: 0)
        zoomer.minimumZoomScale = 1
        zoomer.maximumZoomScale = max(1.2, CGFloat(C) / max(1, min(CGFloat(C), n0)))
        tiles.pxPerto = zoomer.maximumZoomScale * UIScreen.main.scale
        tiles.setNeedsDisplay()
        montarFundo(seq1, t)
    }
    /// as últimas fileiras inteiras (as 2 telas e as fotos dos lados) em miniatura, embaixo da grade: nada aparece preto no começo da pinça
    private func montarFundo(_ ids: [String], _ t: CGFloat) {
        let cols = C, nl = linhas
        guard temMos, cols > 3, nl > 0 else { fundo.image = nil; fundoChave = ""; return }
        let r0 = max(0, nl - 24), chave = "\(mosV)|\(cols)|\(nl)|\(ids.count)|\(t)"
        fundo.frame = CGRect(x: 0, y: CGFloat(r0) * t, width: CGFloat(cols) * t, height: CGFloat(nl - r0) * t)
        fundo.backgroundColor = vista.backgroundColor
        if chave == fundoChave { return }
        fundoChave = chave; fundo.image = nil
        let cel: CGFloat = 40, corF = tiles.cores.0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
            let img = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(cols) * cel, height: CGFloat(nl - r0) * cel), format: fmt).image { cx in
                let ctx = cx.cgContext
                ctx.setFillColor(corF); ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(cols) * cel, height: CGFloat(nl - r0) * cel))
                for r in r0..<nl { for c in 0..<cols {
                    guard self.fundoChave == chave else { return }
                    let i = r * cols + c
                    guard i < ids.count, !ids[i].isEmpty else { continue }
                    let k = "\(ids[i])|64" as NSString
                    var im = self.cache.object(forKey: k)?.img
                    if im == nil { im = self.carregar(ids[i], 64); if let m = im { self.cache.setObject(Caixa(m), forKey: k, cost: m.width * m.height * 4) } }
                    guard let cg = im else { continue }
                    let w = CGFloat(cg.width), h = CGFloat(cg.height), l = min(w, h)
                    guard let q = cg.cropping(to: CGRect(x: (w - l) / 2, y: (h - l) / 2, width: l, height: l)) else { continue }
                    UIImage(cgImage: q).draw(in: CGRect(x: CGFloat(c) * cel, y: CGFloat(r - r0) * cel, width: cel, height: cel))
                } }
            }
            DispatchQueue.main.async { if self.fundoChave == chave { self.fundo.image = img } }
        }
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
        xTravado = nil
        zoomer.contentOffset = CGPoint(x: x, y: y)
    }

    /// imagem pequenina com 1 ponto de cor por foto (a cor do rosto), esticada sem borrar
    private var colS = 0
    private var cS: Int { temMos ? colS : 0 }   // a Fototeca de perto fica no MEIO da grade grande (embaixo do rosto)
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
    /// ao aproximar (voltando do rosto), vai levando aos poucos até as fotos do começo
    private var escalaAnt: CGFloat = 0
    private var ajuda: CGFloat = 3   // 0 = sem ajuda, 3 = como era, 10 = bem forte
    private func xFaixa(_ sc: CGFloat) -> CGFloat {   // offset de lado com a faixa das fotos de verdade no meio da tela
        let x = (CGFloat(cS) + n0 / 2) * t0 * sc - W / 2
        let ins = zoomer.contentInset, maxX = plano.bounds.width * sc - W + ins.right
        return min(max(x, -ins.left), max(-ins.left, maxX))
    }
    private func guiarVolta(_ s: UIScrollView) {
        let sc = s.zoomScale
        defer { escalaAnt = sc }
        guard ajuda > 0, temMos, sc >= 1, escalaAnt > 0, sc > escalaAnt * 1.0005 else { return }
        // só de lado: a cada pinça abrindo, vai centralizando na faixa; para cima e para baixo fica livre
        let u = min(1, max(0, log(sc) / log(max(1.0001, s.maximumZoomScale))))
        let k: CGFloat = min(1, 0.06 + 0.5 * u * u)
        let o = s.contentOffset, alvo = xFaixa(sc)
        ajustando = true
        s.contentOffset = CGPoint(x: o.x + (alvo - o.x) * k, y: o.y)
        ajustando = false
    }
    func scrollViewDidZoom(_ s: UIScrollView) {
        if pinchando || animador != nil { centralizar(); atualizar(); return }   // a nossa pinça/animação já cuida do lugar
        if !trilho { guiarVolta(s) }
        centralizar()
        if trilho, let t = dadosTrilho, s.zoomScale >= 1 {
            // caminho fixo entre as fotos do começo e o rosto inteiro: desliza junto com a pinça, sem pulo
            let u = min(1, max(0, log(s.zoomScale) / log(max(1.0001, t.smax))))
            let sx = t.sf.x + (t.ss.x - t.sf.x) * u, sy = t.sf.y + (t.ss.y - t.sf.y) * u
            ajustando = true
            s.contentOffset = CGPoint(x: t.p.x * s.zoomScale - sx, y: t.p.y * s.zoomScale - sy)
            ajustando = false
        }
        if s.isZooming || s.isZoomBouncing { prenderBordas(s) }
        atualizar()
        if travado && s.zoomScale > s.minimumZoomScale * 1.01 { travado = false; zoomer.isScrollEnabled = ligada && ativa }
    }
    /// rosto inteiro na tela: fica parado (só a pinça para aproximar funciona)
    private var travado = false
    private var trilho = false
    private let usarTrilho = false
    private var ajustando = false
    private var dadosTrilho: (p: CGPoint, sf: CGPoint, ss: CGPoint, smax: CGFloat)?
    private func offsetInicio(_ smax: CGFloat) -> CGPoint {
        let ins = zoomer.contentInset
        return CGPoint(x: CGFloat(cS) * t0 * smax, y: max(-ins.top, plano.bounds.height * smax - H + ins.bottom))
    }
    private func offsetRosto() -> CGPoint {   // rosto inteiro na tela (ele fica acima da primeira tela)
        let fim = temMos ? CGFloat(primeira + linhasMos) * t0 : plano.bounds.height
        return CGPoint(x: -zoomer.contentInset.left, y: fim - H)
    }
    func scrollViewWillBeginZooming(_ s: UIScrollView, with v: UIView?) {
        tirarCapaInicio()
        evento(["tipo": "gZoom"])
        trilho = false
        xTravado = nil
        // pinça livre, presa nos dedos (como no Mozaic: puxa, pinça, puxa, pinça)
        if !usarTrilho { return }
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
        if ajuda > 0, temMos, e >= s.maximumZoomScale * 0.98 {   // chegou às fotos grandes: encaixa a faixa certinho no meio
            xTravado = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { s.contentOffset.x = self.xFaixa(s.zoomScale) }
            return
        }
        guard temMos, e <= s.minimumZoomScale * 1.01 else { return }
        travado = true
        zoomer.isScrollEnabled = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { s.contentOffset = self.offsetRosto() }
    }
    /// arrastar só para cima e para baixo (como no app Fotos); de lado só a pinça mexe
    func scrollViewWillBeginDragging(_ s: UIScrollView) { pararAnimacao(); if !s.isZooming { xTravado = s.contentOffset.x } }   // o dedo manda: para qualquer encaixe animado
    /// linha entre as fotos (como no Fotos do iPhone): 5 pixels com as fotos grandes, afinando aos poucos até sumir no mosaico
    private func atualizarLinhas() {
        guard ligada, let d = tiles.dados, d.t0 > 0 else { linhasCam.isHidden = true; return }
        let z = zoomer.zoomScale, esc = UIScreen.main.scale, cel = d.t0 * z, celPx = cel * esc
        let u = min(1, max(0, (celPx - 70) / (220 - 70)))
        let g = 5 * u * u * (3 - 2 * u) / esc          // espessura em pontos
        guard g > 0.15 else { linhasCam.isHidden = true; return }
        let raio = min(cel / 4, g * 1.5)
        let o = zoomer.contentOffset, B = vista.bounds
        let c0 = max(0, Int(floor(o.x / cel))), c1 = min(d.cols - 1, Int(floor((o.x + B.width) / cel)))
        let r0 = max(0, Int(floor(o.y / cel))), r1 = min(d.linhas - 1, Int(floor((o.y + B.height) / cel)))
        guard c0 <= c1, r0 <= r1, (c1 - c0 + 1) * (r1 - r0 + 1) < 4000 else { linhasCam.isHidden = true; return }
        let p = CGMutablePath()
        for r in r0...r1 { for c in c0...c1 {
            let q = CGRect(x: CGFloat(c) * cel - o.x, y: CGFloat(r) * cel - o.y, width: cel, height: cel)
            p.addRect(q)
            p.addRoundedRect(in: q.insetBy(dx: g / 2, dy: g / 2), cornerWidth: raio, cornerHeight: raio)
        } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        linhasCam.frame = B
        linhasCam.fillColor = tiles.cores.0
        linhasCam.path = p
        linhasCam.isHidden = false
        CATransaction.commit()
    }
    func scrollViewDidScroll(_ s: UIScrollView) {
        atualizarLinhas()
        if let x = xTravado, !s.isZooming, !ajustando, s.contentOffset.x != x {
            ajustando = true; s.contentOffset.x = x; ajustando = false
        }
    }
    /// posição permitida: sem vazio dos lados nem abaixo das últimas fotos (como no Fotos do iPhone)
    /// quanto do caminho entre o rosto inteiro (0) e as fotos grandes (1)
    private func fracao(_ sc: CGFloat) -> CGFloat {
        let mn = max(0.0001, zoomer.minimumZoomScale), mx = zoomer.maximumZoomScale
        guard temMos, mx > mn * 1.0001 else { return 1 }   // sem artista: sempre a grade normal (última fileira acima da barra)
        return min(1, max(0, log(sc / mn) / log(mx / mn)))
    }
    /// força da cortina que esconde as fotos acima da cabeça (a mesma conta de atualizar)
    private func forcaCobre(_ sc: CGFloat) -> CGFloat {
        guard temMos else { return 0 }
        let cc = CGFloat(C), v = cc / max(0.0001, sc)
        let ini = (0.15 + 0.05 * max(0, min(10, momento))) * cc
        let cobreIni = min(0.9 * cc, max(0.55 * cc, ini + 0.2 * cc))
        return suave(cobreIni, 0.97 * cc, v)
    }
    /// limites de cima e de baixo para um zoom: embaixo, o espaço acima da barra só existe com as fotos grandes
    /// (no rosto a imagem vai até o fim da tela); em cima, perto do rosto, nunca aparece a cortina acima da cabeça
    private func limitesY(_ sc: CGFloat) -> (CGFloat, CGFloat) {
        let ins = zoomer.contentInset, h = plano.bounds.height * sc
        let maxY = h - H + ins.bottom * fracao(sc)
        var minY = -ins.top
        if temMos {
            let topoRosto = CGFloat(primeira) * t0 * sc, a = forcaCobre(sc)
            minY = minY + (topoRosto - minY) * a
        }
        return (min(minY, maxY), maxY)
    }
    private func limitar(_ p: CGPoint, _ escala: CGFloat? = nil) -> CGPoint {
        let sc = escala ?? zoomer.zoomScale
        let ins = zoomer.contentInset, cw = plano.bounds.width * sc
        var n = p
        let (minY, maxY) = limitesY(sc)
        n.y = min(max(n.y, minY), maxY)
        let minX = -ins.left, maxX = cw - W + ins.right
        n.x = maxX >= minX ? min(max(n.x, minX), maxX) : minX
        return n
    }
    @objc private func pincou(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: vista)
        switch g.state {
        case .began:
            pararAnimacao()
            tirarCapaInicio()
            evento(["tipo": "gZoom"])
            trilho = false; xTravado = nil; travado = false
            pinchando = true
            zoomer.setContentOffset(zoomer.contentOffset, animated: false)   // para qualquer embalo
            zoomer.isScrollEnabled = false
            pS0 = zoomer.zoomScale; pBase = pS0; pToques = g.numberOfTouches
            let o = zoomer.contentOffset
            pLivre = o
            pAnc = CGPoint(x: (o.x + p.x) / pS0, y: (o.y + p.y) / pS0)
        case .changed:
            let mn = zoomer.minimumZoomScale, mx = zoomer.maximumZoomScale
            if g.numberOfTouches != pToques {
                // um dedo saiu (ou entrou): continua do lugar em que está, sem pular para o dedo que ficou
                let k0 = zoomer.zoomScale
                pBase = k0 / max(0.0001, g.scale)
                pAnc = CGPoint(x: (pLivre.x + p.x) / k0, y: (pLivre.y + p.y) / k0)
                pToques = g.numberOfTouches
            }
            let sc = min(max(pBase * g.scale, mn), mx)
            zoomer.zoomScale = sc
            centralizar()
            var off = CGPoint(x: pAnc.x * sc - p.x, y: pAnc.y * sc - p.y)
            pLivre = off
            if ajuda > 0, temMos, sc > pS0, mx > 1.0001 {
                // volta: a cada abertura, leva aos poucos até a faixa (de lado) e, se ligado, até as 18 fotos (para baixo)
                let u0 = fracao(pS0), u = fracao(sc)
                let w = min(1, max(0, (u - u0) / max(0.0001, 1 - u0))), k = w * w * (3 - 2 * w)
                off.x += (xFaixa(sc) - off.x) * k
                if descer { off.y += (limitesY(sc).1 - off.y) * k }
            }
            ajustando = true
            zoomer.contentOffset = limitar(off, sc)
            ajustando = false
            atualizar()
        case .ended, .cancelled, .failed:
            pinchando = false
            fimPinca()
        default: break
        }
    }
    private func fimPinca() {
        let e = zoomer.zoomScale, mn = zoomer.minimumZoomScale, mx = zoomer.maximumZoomScale
        if temMos && e <= mn * 1.01 {   // rosto inteiro: fica parado no lugar dele
            travado = true
            zoomer.isScrollEnabled = false
            animarPara(mn, offsetRosto(), 0.25)
            return
        }
        zoomer.isScrollEnabled = ligada && ativa
        if !temMos {   // sem artista a grade não tem zoom: volta para as 3 colunas certinhas
            let o = zoomer.contentOffset, alvo = min(mx, max(mn, CGFloat(C) / max(1, min(CGFloat(C), n0))))
            if abs(e - alvo) > 0.001 {
                let cs = CGSize(width: plano.bounds.width * alvo, height: plano.bounds.height * alvo), ins = zoomer.contentInset
                let y = min(max((o.y + H / 2) / e * alvo - H / 2, -ins.top), max(-ins.top, cs.height - H + ins.bottom))
                animarPara(alvo, CGPoint(x: 0, y: y), 0.2)
            }
            return
        }
        if ajuda > 0, temMos, e >= mx * 0.75 {   // quase nas fotos grandes: encaixa as 3 colunas da faixa certinho
            let o = zoomer.contentOffset
            let alvoY = descer ? limitesY(mx).1 : (o.y + H / 2) / e * mx - H / 2
            animarPara(mx, limitar(CGPoint(x: xFaixa(mx), y: alvoY), mx), 0.22)
        }
    }
    /// anima zoom e lugar quadro a quadro (assim a linha entre as fotos acompanha exatamente)
    private func animarPara(_ s1: CGFloat, _ o1: CGPoint, _ dur: Double) {
        pararAnimacao()
        anim = (CACurrentMediaTime(), dur, zoomer.zoomScale, s1, zoomer.contentOffset, o1)
        let l = CADisplayLink(target: self, selector: #selector(passoAnim))
        l.add(to: .main, forMode: .common)
        animador = l
    }
    private func pararAnimacao() { animador?.invalidate(); animador = nil; anim = nil }
    @objc private func passoAnim() {
        guard let a = anim else { pararAnimacao(); return }
        let t = min(1, (CACurrentMediaTime() - a.t0) / a.dur), k = CGFloat(1 - pow(1 - t, 3))
        let sc = a.s0 + (a.s1 - a.s0) * k
        zoomer.zoomScale = sc
        centralizar()
        ajustando = true
        zoomer.contentOffset = CGPoint(x: a.o0.x + (a.o1.x - a.o0.x) * k, y: a.o0.y + (a.o1.y - a.o0.y) * k)
        ajustando = false
        atualizar()
        if t >= 1 { pararAnimacao(); xTravado = nil }
    }
    /// na pinça, como no Fotos do iPhone: nunca aparece vazio dos lados nem abaixo das últimas fotos
    private func prenderBordas(_ s: UIScrollView) {
        let ins = s.contentInset, cs = s.contentSize, o = s.contentOffset
        var n = o
        let maxY = cs.height - H + ins.bottom
        if maxY > -ins.top, n.y > maxY { n.y = maxY }
        let minX = -ins.left, maxX = cs.width - W + ins.right
        if maxX >= minX { n.x = min(max(n.x, minX), maxX) }
        if n != o { ajustando = true; s.contentOffset = n; ajustando = false }
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
        let cc = CGFloat(C)
        // igual ao original: acima da primeira tela a galeria JÁ É o mosaico (as fotos estão no lugar da cor delas).
        // Nada troca: diminuindo o zoom, as próprias fotos formam o rosto; a cor só reforça aos poucos.
        let ini = (0.15 + 0.05 * max(0, min(10, momento))) * cc            // "Momento da cor"
        let b: CGFloat = temMos ? 1 : 0
        let ramp: CGFloat = temMos ? suave(ini, 0.95 * cc, v) : 0
        let segura = ramp
        let cobreIni = min(0.9 * cc, max(0.55 * cc, ini + 0.2 * cc))
        bAtual = b
        tilesB.isHidden = true   // a camada do mosaico é opaca: as fotos do rosto já estão na camada de fotos
        tiles.isHidden = false
        let mag: CGFloat = temMos ? min(1, max(0, (2.0 - k) / 0.6)) * segura : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        magImg.alpha = mag
        tinta.alpha = reforco * pow(ramp, 1.2) * (1 - mag)
        tintaFaixa.alpha = 0
        cobre.alpha = temMos ? suave(cobreIni, 0.97 * cc, v) : 0
        cobreBaixo.alpha = 0
        let face = temMos && v >= CGFloat(C) * 0.97
        if face != naFace { naFace = face; evento(["tipo": "gFace", "on": face]) }
        if corModo != "cor" && ramp > 0 {
            corCamada.frame = vista.bounds
            corCamada.backgroundColor = corModo == "sepia" ? UIColor(red: 0.44, green: 0.30, blue: 0.16, alpha: 1).cgColor : UIColor.gray.cgColor
            corCamada.opacity = Float(ramp * (corModo == "sepia" ? 0.9 : 1))
        } else { corCamada.opacity = 0 }
        CATransaction.commit()
        atualizarLinhas()
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
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        g is UILongPressGestureRecognizer || o is UILongPressGestureRecognizer || g === pinca || o === pinca
    }
    @objc private func tocou(_ g: UITapGestureRecognizer) {
        let p = g.location(in: vista)
        let i = indice(g.location(in: plano))
        // é foto do rosto (mosaico) ou da primeira tela? decide pelo lugar tocado
        let k = i - ini, doRosto = temMos && k >= 0 && k < mosIds.count && !mosIds[k].isEmpty
        evento(["tipo": "gTap", "i": i, "x": p.x, "y": p.y, "noMosaico": temMos && visiveis > CGFloat(C) * 0.8, "b": doRosto])
    }

    // MARK: fotos (chamado pelos pedaços, fora da linha principal)
    private var pendentes = Set<String>(), falhas = Set<String>()
    private let travaPend = NSLock()
    private let filaImg: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 4; q.qualityOfService = .userInitiated; return q }()
    /// devolve na hora a melhor foto que já tem (a miniatura do disco é instantânea) e busca a nítida por trás
    func imagem(_ id: String, _ px: CGFloat, _ q: CGRect, _ b: Bool?) -> CGImage? {
        let s = px <= 90 ? 64 : (px <= 300 ? 256 : 512)
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
                DispatchQueue.main.async { if b == true { self.tilesB.setNeedsDisplay(q) } else { self.tiles.setNeedsDisplay(q) } }
            }
        }
        if s == 512, let g = cache.object(forKey: "\(id)|256" as NSString)?.img { return g }
        if let g = cache.object(forKey: "\(id)|64" as NSString)?.img { return g }
        guard let mini = carregar(id, 64) else { return nil }
        cache.setObject(Caixa(mini), forKey: "\(id)|64" as NSString, cost: mini.width * mini.height * 4)
        return mini
    }
    /// carrega por trás as miniaturas de todas as fotos do mosaico: na pinça elas já estão prontas (sem blocos brancos)
    private var aquecida = ""
    private func aquecer(_ ids: [String]) {
        let chave = "\(mosV)|\(ids.count)"
        guard chave != aquecida else { return }
        aquecida = chave
        let unicos = Array(Set(ids.filter { !$0.isEmpty }))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for id in unicos {
                guard let self = self, self.aquecida == chave else { return }
                let k = "\(id)|64" as NSString
                if self.cache.object(forKey: k) != nil { continue }
                autoreleasepool {
                    if let im = self.carregar(id, 64) { self.cache.setObject(Caixa(im), forKey: k, cost: im.width * im.height * 4) }
                }
            }
        }
    }
    private func carregar(_ id: String, _ s: Int) -> CGImage? {
        if id.hasPrefix("arq:") {
            guard let im = UIImage(contentsOfFile: urlArq(String(id.dropFirst(4))).path) else { return nil }
            return quadrado(im, CGFloat(s))
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
    var pxPerto: CGFloat = 0   // pixels de tela por ponto com as fotos grandes (3 colunas)
    override class var layerClass: AnyClass { CATiledLayerRapido.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false   // onde a grade ainda não se desenhou aparece o fundo pronto (miniaturas), não preto
        if let t = layer as? CATiledLayer {
            t.tileSize = CGSize(width: 512, height: 512)
            t.levelsOfDetail = 7
            t.levelsOfDetailBias = 6
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// espaço entre as fotos e arredondado dos cantos, em pixels da tela, pelo tamanho da foto (medido no Fotos do iPhone: 5 pixels)
    static func vao(_ ladoPx: CGFloat) -> (CGFloat, CGFloat) {
        return (0, 0)   // as fotos ficam coladas; a linha é desenhada por cima, na tela (atualizarLinhas)
    }
    override func draw(_ rect: CGRect) {
        guard let d = dados, d.t0 > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        let (corFundo, corVazia) = cores, marcas = self.marcas
        ctx.setFillColor(corFundo)
        ctx.fill(rect)
        let escala = max(1, abs(ctx.ctm.a))
        // como no Fotos do iPhone: fotos grandes com linha de 5 pixels e cantinhos arredondados; pequenas (mosaico), coladas
        // (medido pela tela, não pela camada: a camada das fotos grandes tem mais detalhe que a tela)
        let tela = pxPerto > 0 ? min(escala, pxPerto) : escala
        let (gp, rp) = TilesMosaico.vao(d.t0 * tela)
        let g: CGFloat = gp / tela, lado = d.t0 - g, raio = rp / tela
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
                    if raio > 0 { ctx.addPath(UIBezierPath(roundedRect: q, cornerRadius: raio).cgPath); ctx.clip() }
                    ctx.translateBy(x: q.minX, y: q.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .medium
                    ctx.draw(im, in: CGRect(x: 0, y: 0, width: lado, height: lado))
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(corVazia)
                    if raio > 0 { ctx.addPath(UIBezierPath(roundedRect: q, cornerRadius: raio).cgPath); ctx.fillPath() } else { ctx.fill(q) }
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
