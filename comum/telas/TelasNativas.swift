import UIKit
import WebKit

/// PEÇA PRONTA (comum/telas): a parte do iPhone das telas falsas, igual ao Mosaico e ao Timeline.
/// Não funciona sozinha: o PonteExtra.swift do app cria uma e repassa os recados (ver comum/telas/GUIA.md).
///   telaCobrir                -> congela o que está na tela (a tela de início) por cima de tudo
///   telaAbrir {x, y, s}       -> o app cresce do ícone (centro x,y e lado s, em pontos) até a tela cheia
///   telaFechar {x, y, s}      -> congela o app na tela (a página troca para a tela de início por baixo)
///   telaFecharVai {x, y, s}   -> o app encolhe até o ícone, como no iOS 26 (ícone chacoalha, fundo desfoca e cresce)
///   icones                    -> devolve a lanterna e a câmera do próprio iPhone (desenhos oficiais), em PNG
///   wifi                      -> o desenho do Wi-Fi da barra de cima, em PNG
///   bateria                   -> {nivel 0–1, carregando, economia} de verdade (para a barra de cima falsa)
final class TelasNativas {
    weak var web: WKWebView?
    private var capaTela: UIView?
    private var velhoTela: UIView?

    /// Trata os recados das telas. Devolve false se o recado não é dela.
    func tratar(_ cmd: String, _ d: [String: Any], _ responder: @escaping (Any?) -> Void) -> Bool {
        func num(_ k: String, _ p: Double) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? p) }
        switch cmd {
        case "telaCobrir": telaCobrir(); responder(true)
        case "telaAbrir": telaAbrir(num("x", 0), num("y", 0), num("s", 60), responder)
        case "telaFechar": telaFechar(num("x", 0), num("y", 0), num("s", 60), responder)
        case "telaFecharVai": telaFecharVai(num("x", 0), num("y", 0), num("s", 60)); responder(true)
        case "icones": responder(icones())
        case "wifi": responder(png("wifi", 60, .semibold))
        case "bateria": responder(bateria())
        default: return false
        }
        return true
    }

    private func janela() -> UIWindow? { web?.window }

    private func telaCobrir() {
        capaTela?.removeFromSuperview(); capaTela = nil
        guard let w = web, let jan = janela(), let foto = w.snapshotView(afterScreenUpdates: false) else { return }
        foto.frame = w.convert(w.bounds, to: jan)
        jan.addSubview(foto)
        capaTela = foto
    }

    private func telaAbrir(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ r: @escaping (Any?) -> Void) {
        guard let w = web, let jan = janela() else { capaTela?.removeFromSuperview(); capaTela = nil; return r(true) }
        // o app novo já está desenhado por baixo da capa: tira uma foto dele e faz ela crescer do ícone
        guard let novo = w.snapshotView(afterScreenUpdates: true) else { capaTela?.removeFromSuperview(); capaTela = nil; return r(true) }
        let B = w.convert(w.bounds, to: jan)
        novo.frame = B
        novo.layer.masksToBounds = true
        jan.addSubview(novo)
        let k = max(0.05, s / B.width)
        novo.transform = CGAffineTransform(translationX: x - B.midX, y: y - B.midY).scaledBy(x: k, y: k)
        novo.layer.cornerRadius = 0.2237 * s / k
        novo.alpha = 0.4
        r(true)
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

    private func telaFechar(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ r: @escaping (Any?) -> Void) {
        velhoTela?.removeFromSuperview(); velhoTela = nil
        guard let w = web, let jan = janela(), let velho = w.snapshotView(afterScreenUpdates: true) else { return r(true) }
        velho.frame = w.convert(w.bounds, to: jan)
        velho.layer.masksToBounds = true
        velho.layer.cornerCurve = .continuous
        jan.addSubview(velho)
        velhoTela = velho
        r(true)
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
        let fundo = w.snapshotView(afterScreenUpdates: true)
        let desfoque = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        let rIcone = CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
        let icone = w.resizableSnapshotView(from: w.convert(rIcone, from: jan), afterScreenUpdates: false, withCapInsets: .zero)
        if let f = fundo {
            f.frame = B
            jan.insertSubview(f, belowSubview: velho)
            desfoque.frame = B
            jan.insertSubview(desfoque, belowSubview: velho)
            f.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
        if let ic = icone {
            ic.frame = rIcone
            ic.layer.cornerRadius = 0.2237 * s; ic.layer.cornerCurve = .continuous; ic.layer.masksToBounds = true
            ic.alpha = 0
            ic.transform = CGAffineTransform(translationX: 0, y: s * 0.18).scaledBy(x: 1.3, y: 1.55)
            jan.insertSubview(ic, belowSubview: velho)
        }
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
        if let ic = icone {
            UIView.animate(withDuration: 0.1, delay: dur - 0.1, options: [.curveLinear]) { ic.alpha = 1 }
            UIView.animate(withDuration: 0.5, delay: dur - 0.04, usingSpringWithDamping: 0.52, initialSpringVelocity: 0.6, options: []) { ic.transform = .identity }
        }
        UIView.animate(withDuration: 0.4, delay: dur - 0.08, options: [.curveEaseOut]) {
            fundo?.transform = .identity
            desfoque.alpha = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.55) {
            velho.removeFromSuperview(); icone?.removeFromSuperview(); desfoque.removeFromSuperview(); fundo?.removeFromSuperview()
        }
    }

    /// Desenho oficial do iPhone (SF Symbol) em PNG branco.
    private func png(_ nome: String, _ tamanho: CGFloat = 90, _ peso: UIImage.SymbolWeight = .regular) -> String {
        let conf = UIImage.SymbolConfiguration(pointSize: tamanho, weight: peso)
        guard let img = UIImage(systemName: nome, withConfiguration: conf)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return "" }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        let r = UIGraphicsImageRenderer(size: img.size, format: f)
        let dados = r.pngData { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
        return "data:image/png;base64," + dados.base64EncodedString()
    }

    /// Lanterna e câmera do próprio iPhone (os mesmos desenhos da tela bloqueada de verdade).
    private func icones() -> [String: String] {
        return ["lan": png("flashlight.off.fill"), "cam": png("camera.fill")]
    }

    /// Bateria de verdade, para a barra de cima falsa.
    private func bateria() -> [String: Any] {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        return ["nivel": Double(d.batteryLevel), "carregando": d.batteryState == .charging || d.batteryState == .full,
                "economia": ProcessInfo.processInfo.isLowPowerModeEnabled]
    }
}
