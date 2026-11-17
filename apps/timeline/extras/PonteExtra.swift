import UIKit
import WebKit
import AVFoundation
import AudioToolbox
import CoreMotion
import MediaPlayer

/// Parte do iPhone só do app Timeline.
/// Recados da página: window.webkit.messageHandlers.tl.postMessage({cmd: ...})
///   armar {gatilho: "volume" | "chacoalhar" | "virar" | "toque"} -> fica esperando o gatilho
///   desarmar                -> para de esperar
///   som {vol: 0...1}        -> toca o som de bloqueio do iPhone
///   glitch {seg: n}         -> toca o som de glitch por n segundos
///   icones                  -> manda a lanterna e a câmera do próprio iPhone (desenhos oficiais)
/// O iPhone responde:
///   window.tlGatilho()                  -> o gatilho aconteceu
///   window.tlIcones(lanterna, camera)   -> imagens (data:image/png)
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandler {
    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    private var gatilho = ""
    private var armado = false

    // movimento
    private let mm = CMMotionManager()
    private var picos: [TimeInterval] = []
    private var viradoDesde: TimeInterval = 0
    private var ultimoPico: TimeInterval = 0

    // volume
    private var volumeView: MPVolumeView?
    private var observador: NSKeyValueObservation?
    private var volumeOriginal: Float = 0.5
    private var ajustando = false

    // som
    private var somID: SystemSoundID = 0
    private var silencio: AVAudioPlayer?
    private var somGlitch: AVAudioPlayer?
    private var somBloqueio: AVAudioPlayer?
    private var paraGlitch: DispatchWorkItem?

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "tl")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
        let url = URL(fileURLWithPath: "/System/Library/Audio/UISounds/lock.caf")
        if AudioServicesCreateSystemSoundID(url as CFURL, &somID) != noErr { somID = 0 }
        prepararSom()
        // o controle de volume fica sempre na tela (escondido): assim o aviso de volume nunca aparece
        let mv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
        mv.alpha = 0.01
        mv.isUserInteractionEnabled = false
        tela.view.addSubview(mv)
        volumeView = mv
        NotificationCenter.default.addObserver(self, selector: #selector(voltouProApp),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(voltouProApp),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// Toca "silêncio" sem parar. Enquanto o app toca som, os botões de volume mexem no volume do app
    /// (e não na campainha, que mostrava o aviso "Toque" e não avisava o app).
    private func prepararSom() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        func player(_ nome: String) -> AVAudioPlayer? {
            guard let u = Bundle.main.url(forResource: nome, withExtension: "wav", subdirectory: "www")
                    ?? Bundle.main.url(forResource: nome, withExtension: "wav") else { return nil }
            let p = try? AVAudioPlayer(contentsOf: u); p?.prepareToPlay(); return p
        }
        silencio = player("silencio")
        silencio?.numberOfLoops = -1
        silencio?.volume = 0.01
        silencio?.play()
        somGlitch = player("glitch")
        // o som de bloqueio do próprio iPhone, tocado de um jeito que deixa controlar o volume
        somBloqueio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Audio/UISounds/lock.caf"))
        somBloqueio?.prepareToPlay()
    }

    @objc private func voltouProApp() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if silencio?.isPlaying == false { silencio?.play() }
        if gatilho == "volume" && armado { garantirEspacoVolume() }
    }

    /// Toca o glitch por "segundos" e para na hora certa
    private func tocarGlitch(_ segundos: Double) {
        guard let p = somGlitch else { return }
        paraGlitch?.cancel()
        p.stop(); p.currentTime = 0; p.volume = 1
        p.numberOfLoops = -1
        p.play()
        let item = DispatchWorkItem { p.stop() }
        paraGlitch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: item)
    }

    private func tocarBloqueio(_ vol: Float) {
        if let p = somBloqueio {
            p.stop(); p.currentTime = 0
            p.volume = max(0, min(1, vol))
            p.play()
        } else {
            AudioServicesPlaySystemSound(somID != 0 ? somID : 1100)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let corpo = message.body as? [String: Any], let cmd = corpo["cmd"] as? String else { return }
        switch cmd {
        case "armar": armar((corpo["gatilho"] as? String) ?? "toque")
        case "desarmar": desarmar()
        case "som": tocarBloqueio((corpo["vol"] as? NSNumber)?.floatValue ?? 0.4)
        case "icones": mandarIcones()
        case "glitch": tocarGlitch((corpo["seg"] as? NSNumber)?.doubleValue ?? 3)
        default: break
        }
    }

    private func avisar() {
        guard armado else { return }
        desarmar()
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.tlGatilho&&tlGatilho()", completionHandler: nil) }
    }

    private func armar(_ g: String) {
        desarmar()
        gatilho = g
        armado = true
        switch g {
        case "chacoalhar", "virar": ligarMovimento()
        case "volume": ligarVolume()
        default: break
        }
    }

    private func desarmar() {
        armado = false
        if mm.isDeviceMotionActive { mm.stopDeviceMotionUpdates() }
        if gatilho == "volume" { desligarVolume() }
        gatilho = ""
    }

    // MARK: chacoalhar / virar para baixo
    private func ligarMovimento() {
        guard mm.isDeviceMotionAvailable else { return }
        picos = []; viradoDesde = 0; ultimoPico = 0
        mm.deviceMotionUpdateInterval = 1.0 / 60
        mm.startDeviceMotionUpdates(to: .main) { [weak self] d, _ in
            guard let self = self, let d = d, self.armado else { return }
            let t = d.timestamp
            if self.gatilho == "chacoalhar" {
                let a = d.userAcceleration
                let forca = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                if forca > 1.25 && t - self.ultimoPico > 0.12 {      // cada "sacudida" conta uma vez
                    self.ultimoPico = t
                    self.picos.append(t)
                    self.picos = self.picos.filter { t - $0 < 0.9 }
                    if self.picos.count >= 2 { self.avisar() }
                }
            } else {
                // tela virada para a mesa: gravidade "saindo" pela tela
                if d.gravity.z > 0.8 {
                    if self.viradoDesde == 0 { self.viradoDesde = t }
                    if t - self.viradoDesde > 0.25 { self.avisar() }
                } else { self.viradoDesde = 0 }
            }
        }
    }

    // MARK: botão de volume +
    private func ligarVolume() {
        voltouProApp()
        garantirEspacoVolume()
        if observador == nil {
            observador = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { [weak self] _, m in
                guard let n = m.newValue, let o = m.oldValue else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.armado, self.gatilho == "volume", !self.ajustando else { return }
                    if n > o + 0.001 {
                        self.avisar()
                        self.mudarVolume(self.volumeOriginal)   // devolve o volume como estava
                    }
                }
            }
        }
    }

    /// No máximo não dá para subir: deixa um pouco abaixo (sem aviso na tela)
    private func garantirEspacoVolume() {
        let v = AVAudioSession.sharedInstance().outputVolume
        volumeOriginal = min(v, 0.85)
        if v > 0.9 { mudarVolume(0.85) }
    }

    private func desligarVolume() { }

    private func mudarVolume(_ v: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        ajustando = true
        slider.setValue(v, animated: false)
        slider.sendActions(for: .valueChanged)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.ajustando = false }
    }

    // MARK: ícones oficiais do iPhone (SF Symbols)
    private func mandarIcones() {
        func png(_ nome: String, _ alt: String) -> String {
            let conf = UIImage.SymbolConfiguration(pointSize: 90, weight: .regular)
            guard let img = (UIImage(systemName: nome, withConfiguration: conf) ?? UIImage(systemName: alt, withConfiguration: conf))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) else { return "" }
            let f = UIGraphicsImageRendererFormat()
            f.scale = 3
            let r = UIGraphicsImageRenderer(size: img.size, format: f)
            let dados = r.pngData { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
            return "data:image/png;base64," + dados.base64EncodedString()
        }
        let l = png("flashlight.off.fill", "flashlight.off.fill")
        let c = png("camera.fill", "camera.fill")
        let js = "window.tlIcones&&tlIcones('\(l)','\(c)')"
        web?.evaluateJavaScript(js, completionHandler: nil)
    }
}
