import UIKit
import WebKit
import CoreMotion
import CoreHaptics
import AudioToolbox

/// Parte do iPhone só do app Detector (detector de ímã).
/// Recados da página: window.webkit.messageHandlers.ima.postMessage({cmd: ...})
///   ligar {ajustes}   -> liga o sensor e aprende a sala (2 s); pronto = vum vum vum
///   desligar          -> desliga o sensor
///   ajustes {sens, adapt, forca, dupla, saidaLonga, dormir, dormirMin}
///   bolso {ligar}     -> sensor de proximidade (tela apaga no bolso)
/// O iPhone responde:
///   window.imaSinal(valor µT, limite µT, estado)
///     0 desligado, 1 aprendendo, 2 pronto, 3 ímã perto, 4 dormindo, 5 acordando,
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandler {
    private enum Modo { case parado, aprendendo, pronto, dormindo, acordando, auto }

    private weak var web: WKWebView?
    private let mm = CMMotionManager()
    private let fila: OperationQueue = { let f = OperationQueue(); f.maxConcurrentOperationCount = 1; return f }()
    private var motor: CHHapticEngine?
    private var ocupadoAte: TimeInterval = 0      // só na fila principal
    private var geracao = 0                        // muda ao desligar: corta vibrações que ainda iam tocar
    private var tocando: CHHapticPatternPlayer?

    // ajustes (só na fila do sensor)
    private var sens = 60.0, adapt = 70.0, forca = 70.0
    private var dupla = true, saidaLonga = false, dormir = true, dormirMin = 5.0

    // estado (só na fila do sensor)
    private var modo = Modo.parado
    private var t0: TimeInterval = 0
    private var soma = SIMD3<Double>(0, 0, 0)
    private var nSoma = 0
    private var base = SIMD3<Double>(0, 0, 0)
    private var suave = SIMD3<Double>(0, 0, 0)
    private var temSuave = false
    private var giroS = 0.0
    private var valor = 0.0
    private var limAtual = 10.0
    private var perto = false
    private var acima = 0
    private var congeladoDesde: TimeInterval = 0
    private var silencioAte: TimeInterval = 0
    private var ultimaAtividade: TimeInterval = 0
    private var ultimoEnvio: TimeInterval = 0
    private var contAcordar = 0
    private var limpoDesde: TimeInterval = 0
    private var autoFase = 0

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
            iniciarSensor()
            fila.addOperation { if self.modo != .auto { self.comecarAprender() } }
        case "desligar":
            cortarVibracao()
            fila.addOperation {
                guard self.modo != .auto else { return }
                self.modo = .parado
                self.enviar(0, forcar: true)
                DispatchQueue.main.async { self.pararSensor() }
            }
        case "ajustes":
            lerAjustes(corpo)
        case "bolso":
            UIDevice.current.isProximityMonitoringEnabled = (corpo["ligar"] as? Bool) ?? false
        default:
            break
        }
    }

    private func lerAjustes(_ c: [String: Any]) {
        func num(_ k: String) -> Double? { (c[k] as? NSNumber)?.doubleValue }
        let s = num("sens"), a = num("adapt"), f = num("forca"), dm = num("dormirMin")
        let d = c["dupla"] as? Bool, sl = c["saidaLonga"] as? Bool, dr = c["dormir"] as? Bool
        fila.addOperation {
            if let s = s { self.sens = s }
            if let a = a { self.adapt = a }
            if let f = f { self.forca = f }
            if let dm = dm { self.dormirMin = dm }
            if let d = d { self.dupla = d }
            if let sl = sl { self.saidaLonga = sl }
            if let dr = dr { self.dormir = dr }
        }
    }

    // MARK: sensor
    private func iniciarSensor() {
        guard mm.isMagnetometerAvailable else { return }
        if mm.isDeviceMotionAvailable && !mm.isDeviceMotionActive {
            mm.deviceMotionUpdateInterval = 1.0 / 50
            mm.startDeviceMotionUpdates(using: .xArbitraryZVertical)   // só o giroscópio: o ímã não atrapalha
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

    /// Limite em µT: barra 0 = 80 µT (só bem perto), barra 100 = 3,2 µT (bem sensível)
    private func limitePara(_ s: Double) -> Double { 80 * pow(0.04, s / 100) }
    private var limite: Double { limitePara(sens) }

    private func comecarAprender() {
        modo = .aprendendo
        t0 = 0
        soma = .zero; nSoma = 0
        perto = false; acima = 0
        enviar(0, forcar: true)
    }

    private func processar(_ cru: SIMD3<Double>, _ t: TimeInterval) {
        guard modo != .parado else { return }
        if !temSuave { suave = cru; temSuave = true } else { suave += (cru - suave) * 0.35 }   // alisa o tremor
        let giro = mm.deviceMotion.map { r -> Double in
            let g = r.rotationRate; return (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        } ?? 0
        giroS += (giro - giroS) * 0.1
        let dif = suave - base
        valor = (dif.x * dif.x + dif.y * dif.y + dif.z * dif.z).squareRoot()
        limAtual = limite

        // enquanto o próprio celular vibra (e logo depois), o sensor não conta: o motor de vibração tem ímã
        if t < silencioAte && (modo == .pronto || modo == .dormindo || modo == .acordando) {
            contAcordar = 0
            enviar(t)
            return
        }

        switch modo {
        case .aprendendo: aprender(t)
        case .pronto: detectar(t, dif)
        case .dormindo: dormindo(t, dif)
        case .acordando: acordando(t)
        case .auto: break
        case .parado: break
        }
        enviar(t)
    }

    private func aprender(_ t: TimeInterval) {
        if t0 == 0 { t0 = t }
        if t - t0 > 0.3 { soma += suave; nSoma += 1 }     // descarta o começo
        if t - t0 >= 2.0 && nSoma > 20 {
            base = soma / Double(nSoma)
            modo = .pronto
            perto = false; acima = 0
            congeladoDesde = 0
            silencioAte = max(silencioAte, t + 0.3)
            ultimaAtividade = t
            tocar(3, 0.37, gap: 0.28)                                 // pronto: vum vum vum
        }
    }

    private func detectar(_ t: TimeInterval, _ dif: SIMD3<Double>) {
        let a = adapt / 100
        let k = 0.3 + 6 * (1 - a)                          // quanto o movimento "esconde" o sinal
        let limEf = limite * (1 + k * giroS)
        limAtual = limEf
        if giroS > 1.0 + 2.0 * a {                         // girando muito: não vibra e reaprende rápido
            base += dif * 0.08
            silencioAte = max(silencioAte, t + 0.35)
            perto = false; acima = 0
            return
        }
        // a base acompanha a sala (mais rápido quando o celular se mexe), mas congela quando algo forte aparece
        if valor < limEf * 0.5 {
            base += dif * (0.004 + (0.02 + 0.1 * (1 - a)) * min(giroS, 2))
            congeladoDesde = 0
        } else {
            if congeladoDesde == 0 { congeladoDesde = t }
            if t - congeladoDesde > 5 {                    // mudado muito tempo: é a sala, não o ímã
                base = suave; congeladoDesde = 0; perto = false; acima = 0
            }
        }
        if t >= silencioAte {
            if !perto {
                acima = valor > limEf ? acima + 1 : 0
                if acima >= 2 {
                    perto = true
                    ultimaAtividade = t
                    tocar(3, 0.37, gap: 0.28)                         // chegou: vum vum vum
                }
            } else if valor < limEf * 0.6 {
                perto = false
                acima = 0
                ultimaAtividade = t
                if dupla {
                    if saidaLonga { tocar(1, 1.0) } else { tocar(3, 0.37, gap: 0.28) }   // saiu
                }
            }
        }
        if dormir && !perto && t - ultimaAtividade > dormirMin * 60 {
            modo = .dormindo
            contAcordar = 0
        }
    }

    /// Dormindo: não vibra. Acorda com o ímã bem encostado por ~1 s.
    private var forteAcordar: Double { max(60, limite * 4) }

    private func dormindo(_ t: TimeInterval, _ dif: SIMD3<Double>) {
        if giroS > 0.3 { base = suave; contAcordar = 0; return }
        if valor > forteAcordar {
            contAcordar += 1
            if contAcordar >= 80 {
                modo = .acordando
                t0 = t
                limpoDesde = 0
                tocar(1, 0.4)                              // acordei: um vum
            }
        } else {
            contAcordar = max(0, contAcordar - 2)
            if valor < forteAcordar * 0.3 { base += dif * 0.01 }
        }
    }

    /// Acordou: espera tirar o ímã de perto e reaprende a sala.
    private func acordando(_ t: TimeInterval) {
        if valor < forteAcordar * 0.25 && giroS < 0.5 {
            if limpoDesde == 0 { limpoDesde = t }
            if t - limpoDesde > 0.6 { comecarAprender(); return }
        } else {
            limpoDesde = 0
        }
        if t - t0 > 8 { comecarAprender() }
    }

    private func enviar(_ t: TimeInterval, forcar: Bool = false) {
        guard forcar || t - ultimoEnvio > 0.05 else { return }
        ultimoEnvio = t
        var estado = 0
        switch modo {
        case .parado: estado = 0
        case .aprendendo: estado = 1
        case .pronto: estado = perto ? 3 : 2
        case .dormindo: estado = 4
        case .acordando: estado = 5
        case .auto: estado = autoFase == 0 ? 6 : (autoFase == 1 ? 7 : 8)
        }
        let v = (modo == .pronto || modo == .dormindo || (modo == .auto && autoFase > 0)) ? valor : 0
        let js = String(format: "window.imaSinal&&imaSinal(%.2f,%.2f,%ld)", v, limAtual, estado)
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

    /// Chamado na fila do sensor. Toca depois que a vibração anterior terminar (não se misturam).
    /// Chamado na fila do sensor. Um aviso de cada vez: se já está vibrando, não acumula outro.
    private func tocar(_ pulsos: Int, _ dur: Double, gap: Double = 0.1, forcaMin: Double = 0) {
        let f = max(forca, forcaMin)
        let total = Double(pulsos) * dur + Double(pulsos - 1) * gap
        let agoraFila = ProcessInfo.processInfo.systemUptime
        silencioAte = max(silencioAte, agoraFila + total + 0.6)    // fica "surdo" já, antes de começar a vibrar
        DispatchQueue.main.async {
            let agora = ProcessInfo.processInfo.systemUptime
            guard self.ocupadoAte <= agora else { return }
            self.ocupadoAte = agora + total
            self.vibrar(pulsos, dur, gap, f)
        }
    }

    /// Desligou: para a vibração que está tocando e as que ainda iam tocar.
    private func cortarVibracao() {
        geracao += 1
        ocupadoAte = 0
        try? tocando?.stop(atTime: CHHapticTimeImmediate)
        tocando = nil
    }

    private func vibrar(_ pulsos: Int, _ dur: Double, _ gap: Double, _ forca: Double) {
        let intensidade = Float(0.15 + 0.85 * forca / 100)
        // força no máximo: usa a vibração clássica do iPhone (a de chamada), a mais forte
        guard forca < 99, let m = motor else { return vibrarSistema(pulsos, dur + gap) }
        var eventos: [CHHapticEvent] = []
        for i in 0..<pulsos {
            eventos.append(CHHapticEvent(eventType: .hapticContinuous,
                                         parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensidade),
                                                      CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)],
                                         relativeTime: Double(i) * (dur + gap), duration: dur))
        }
        do {
            try m.start()
            let p = try m.makePlayer(with: CHHapticPattern(events: eventos, parameters: []))
            try p.start(atTime: CHHapticTimeImmediate)
            tocando = p
        } catch {
            vibrarSistema(pulsos, dur + gap)
        }
    }

    private func vibrarSistema(_ pulsos: Int, _ passo: Double) {
        let g = geracao
        for i in 0..<pulsos {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * max(passo, 0.5)) {
                guard g == self.geracao else { return }
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
