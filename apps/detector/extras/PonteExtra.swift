import UIKit
import WebKit
import CoreMotion
import CoreHaptics
import AudioToolbox

/// Parte do iPhone só do app Detector (detector de ímã).
/// Recados da página: window.webkit.messageHandlers.ima.postMessage({cmd: ...})
///   ligar {sens, forca, tempo, dupla} -> liga o sensor e aprende a sala (2 s)
///   desligar                          -> desliga o sensor
///   ajustes {sens, forca, tempo, dupla}
///   recalibrar                        -> aprende a sala de novo
///   vibrar                            -> vibração de teste com a força e o tempo atuais
///   bolso {ligar}                     -> sensor de proximidade (tela apaga no bolso)
/// O iPhone responde chamando window.imaSinal(valor µT, limite µT, estado)
///   estado: 0 desligado, 1 aprendendo, 2 pronto, 3 ímã perto
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandler {
    private weak var web: WKWebView?
    private let mm = CMMotionManager()
    private let fila: OperationQueue = { let f = OperationQueue(); f.maxConcurrentOperationCount = 1; return f }()
    private var motor: CHHapticEngine?

    // ajustes (lidos e escritos só na fila do sensor)
    private var sens = 60.0, forca = 70.0, tempo = 40.0
    private var dupla = true

    // estado do detector
    private var ligado = false
    private var aprendendo = false
    private var inicioAprender: TimeInterval = 0
    private var soma = SIMD3<Double>(0, 0, 0)
    private var nSoma = 0
    private var base = SIMD3<Double>(0, 0, 0)
    private var suave = SIMD3<Double>(0, 0, 0)
    private var temSuave = false
    private var perto = false
    private var acima = 0
    private var congeladoDesde: TimeInterval = 0
    private var silencioAte: TimeInterval = 0
    private var ultimaVib: TimeInterval = 0
    private var ultimoEnvio: TimeInterval = 0
    private var valor = 0.0

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "ima")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        prepararVibracao()
    }

    // MARK: recados da página
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let corpo = message.body as? [String: Any], let cmd = corpo["cmd"] as? String else { return }
        switch cmd {
        case "ligar":
            lerAjustes(corpo)
            fila.addOperation { self.ligado = true; self.comecarAprender() }
            iniciarSensor()
        case "desligar":
            pararSensor()
            fila.addOperation { self.ligado = false; self.aprendendo = false; self.perto = false; self.enviar(0, forcar: true) }
        case "ajustes":
            lerAjustes(corpo)
        case "recalibrar":
            fila.addOperation { if self.ligado { self.comecarAprender() } }
        case "vibrar":
            fila.addOperation { let f = self.forca, t = self.tempo; DispatchQueue.main.async { self.vibrar(forca: f, tempo: t) } }
        case "bolso":
            UIDevice.current.isProximityMonitoringEnabled = (corpo["ligar"] as? Bool) ?? false
        default:
            break
        }
    }

    private func lerAjustes(_ c: [String: Any]) {
        let s = (c["sens"] as? NSNumber)?.doubleValue, f = (c["forca"] as? NSNumber)?.doubleValue
        let t = (c["tempo"] as? NSNumber)?.doubleValue, d = c["dupla"] as? Bool
        fila.addOperation {
            if let s = s { self.sens = s }
            if let f = f { self.forca = f }
            if let t = t { self.tempo = t }
            if let d = d { self.dupla = d }
        }
    }

    // MARK: sensor
    private func iniciarSensor() {
        guard mm.isMagnetometerAvailable else { return }
        if mm.isDeviceMotionAvailable && !mm.isDeviceMotionActive {
            mm.deviceMotionUpdateInterval = 1.0 / 50
            mm.startDeviceMotionUpdates(using: .xArbitraryZVertical)   // só o giroscópio, o ímã não atrapalha
        }
        if !mm.isMagnetometerActive {
            mm.magnetometerUpdateInterval = 1.0 / 100
            mm.startMagnetometerUpdates(to: fila) { [weak self] dado, _ in
                guard let self = self, let d = dado else { return }
                self.processar(SIMD3(d.magneticField.x, d.magneticField.y, d.magneticField.z), d.timestamp)
            }
        }
    }

    private func pararSensor() {
        mm.stopMagnetometerUpdates()
        mm.stopDeviceMotionUpdates()
    }

    private func comecarAprender() {
        aprendendo = true
        inicioAprender = 0
        soma = .zero; nSoma = 0
        perto = false; acima = 0
        temSuave = false
        enviar(0, forcar: true)
    }

    /// Limite em µT: barra 0 = 80 µT (só bem perto), barra 100 = 3,2 µT (bem sensível)
    private var limite: Double { 80 * pow(0.04, sens / 100) }

    private func processar(_ cru: SIMD3<Double>, _ t: TimeInterval) {
        guard ligado else { return }
        // alisa o tremor do sensor
        if !temSuave { suave = cru; temSuave = true } else { suave += (cru - suave) * 0.35 }

        if aprendendo {
            if inicioAprender == 0 { inicioAprender = t }
            if t - inicioAprender > 0.3 { soma += suave; nSoma += 1 }       // descarta o começo
            if t - inicioAprender >= 2.0 && nSoma > 20 {
                base = soma / Double(nSoma)
                aprendendo = false
                congeladoDesde = 0
                silencioAte = t + 0.3
                DispatchQueue.main.async { self.vibrar(forca: 25, tempo: 0, pronto: true) }   // toquinho de "pronto"
            }
            enviar(t)
            return
        }

        // celular girando ou balançando: não vibra e reaprende rápido
        let giro = mm.deviceMotion.map { r -> Double in
            let g = r.rotationRate; return (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        } ?? 0
        let lim = limite
        let dif = suave - base
        valor = (dif.x * dif.x + dif.y * dif.y + dif.z * dif.z).squareRoot()

        if giro > 0.7 {
            base += dif * 0.08
            silencioAte = t + 0.35
            if perto { perto = false }
            acima = 0
            enviar(t)
            return
        }

        // a base acompanha devagar as mudanças da sala, mas congela quando algo forte aparece
        if valor < lim * 0.5 {
            base += dif * 0.004
            congeladoDesde = 0
        } else {
            if congeladoDesde == 0 { congeladoDesde = t }
            if t - congeladoDesde > 5 {           // ficou mudado muito tempo: é a sala, não o ímã
                base = suave; congeladoDesde = 0; perto = false; acima = 0
            }
        }

        if t >= silencioAte {
            if !perto {
                acima = valor > lim ? acima + 1 : 0
                if acima >= 2 {
                    perto = true
                    avisar(t)
                }
            } else if valor < lim * 0.6 {
                perto = false
                acima = 0
                if dupla { avisar(t) }
            }
        }
        enviar(t)
    }

    private func avisar(_ t: TimeInterval) {
        guard t - ultimaVib > 0.25 else { return }
        ultimaVib = t
        let f = forca, d = tempo
        DispatchQueue.main.async { self.vibrar(forca: f, tempo: d) }
    }

    private func enviar(_ t: TimeInterval, forcar: Bool = false) {
        guard forcar || t - ultimoEnvio > 0.05 else { return }
        ultimoEnvio = t
        let estado = !ligado ? 0 : (aprendendo ? 1 : (perto ? 3 : 2))
        let v = ligado && !aprendendo ? valor : 0
        let js = String(format: "window.imaSinal&&imaSinal(%.2f,%.2f,%ld)", v, limite, estado)
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }

    // MARK: vibração
    private func prepararVibracao() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let m = try CHHapticEngine()
            m.playsHapticsOnly = true
            m.isAutoShutdownEnabled = false
            m.resetHandler = { [weak self] in try? self?.motor?.start() }
            m.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { try? self?.motor?.start() } }
            try m.start()
            motor = m
        } catch { motor = nil }
    }

    /// forca 0–100, tempo 0–100 (toque curto até 0,6 s)
    private func vibrar(forca: Double, tempo: Double, pronto: Bool = false) {
        let intensidade = Float(0.15 + 0.85 * forca / 100)
        let duracao = pronto ? 0.04 : 0.04 + 0.56 * tempo / 100
        guard let m = motor else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        let ev = CHHapticEvent(eventType: .hapticContinuous,
                               parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensidade),
                                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                               relativeTime: 0, duration: duracao)
        do {
            try m.start()
            let p = try m.makePlayer(with: CHHapticPattern(events: [ev], parameters: []))
            try p.start(atTime: CHHapticTimeImmediate)
        } catch {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}
