import UIKit
import WebKit
import CoreHaptics
import AudioToolbox
import AVFoundation
import Speech

/// Parte do iPhone só do app Telão.
/// Recados da página: window.webkit.messageHandlers.telao.postMessage({cmd: ...}) -> devolve uma resposta
///   vibrar {tipo}   -> "curta" (enviou), "dupla" (o telão confirmou) ou "longa" (falhou / chegou tarde)
///   vozLigar        -> liga o microfone e o reconhecimento de fala em português (enquanto segura o botão)
///   vozDesligar     -> desliga; o último texto entendido já foi avisado
///   telaCobrir / icones / ... -> peça pronta TelasNativas (comum/telas)
/// O iPhone avisa a página: window.telaoRx({tipo: 'voz', texto, final}) e window.telaoRx({tipo: 'vozFim'})
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply {
    private weak var web: WKWebView?
    private let telas = TelasNativas()

    private var motorVib: CHHapticEngine?

    private var audio: AVAudioEngine?
    private var pedidoVoz: SFSpeechAudioBufferRecognitionRequest?
    private var tarefaVoz: SFSpeechRecognitionTask?
    private var vozLimite: DispatchWorkItem?

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "telao")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        telas.web = webView
        prepararVibracao()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let responder: (Any?) -> Void = { valor in DispatchQueue.main.async { replyHandler(valor, nil) } }
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String else { return responder(false) }
        if telas.tratar(cmd, d, responder) { return }
        switch cmd {
        case "vibrar":
            vibrar((d["tipo"] as? String) ?? "curta"); responder(true)
        case "vozLigar":
            vozLigar(responder)
        case "vozDesligar":
            DispatchQueue.main.async { self.pararVoz(avisar: true); responder(true) }
        default:
            responder(false)
        }
    }

    private func avisar(_ o: [String: Any]) {
        guard let dados = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: dados, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.telaoRx&&window.telaoRx(\(json))", completionHandler: nil) }
    }

    // MARK: vibração
    private func prepararVibracao() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let m = try CHHapticEngine()
            m.playsHapticsOnly = true
            m.isAutoShutdownEnabled = false
            m.resetHandler = { [weak self] in try? self?.motorVib?.start() }
            m.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { try? self?.motorVib?.start() } }
            try m.start()
            motorVib = m
        } catch { motorVib = nil }
    }

    /// curta = um toque firme; dupla = dois toques; longa = uma vibração comprida
    private func vibrar(_ tipo: String) {
        DispatchQueue.main.async {
            let pulsos: [(Double, Double)]          // (início, duração)
            switch tipo {
            case "dupla": pulsos = [(0, 0.16), (0.32, 0.16)]
            case "longa": pulsos = [(0, 0.7)]
            default:      pulsos = [(0, 0.16)]
            }
            guard let m = self.motorVib else { return self.vibrarSistema(tipo) }
            let eventos = pulsos.map { p in
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                           CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)],
                              relativeTime: p.0, duration: p.1)
            }
            do {
                try m.start()
                let player = try m.makePlayer(with: CHHapticPattern(events: eventos, parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
            } catch { self.vibrarSistema(tipo) }
        }
    }

    /// sem o motor de vibração: a vibração clássica do iPhone
    private func vibrarSistema(_ tipo: String) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        if tipo == "dupla" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        }
    }

    // MARK: microfone (segurar o botão e falar a hora)
    private func vozLigar(_ r: @escaping (Any?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            guard st == .authorized else { return r("reconhecimento de fala negado") }
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                guard ok else { return r("microfone negado") }
                DispatchQueue.main.async { r(self.comecarVoz()) }
            }
        }
    }

    private func comecarVoz() -> Any {
        pararVoz(avisar: false)
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")), rec.isAvailable else {
            return "reconhecimento indisponível"
        }
        let sessao = AVAudioSession.sharedInstance()
        do {
            try sessao.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try sessao.setActive(true)
        } catch { return "áudio ocupado" }
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
            restaurarAudio()
            return "microfone não ligou"
        }
        audio = m
        pedidoVoz = pedido
        tarefaVoz = rec.recognitionTask(with: pedido) { [weak self] res, _ in
            if let res = res {
                self?.avisar(["tipo": "voz", "texto": res.bestTranscription.formattedString, "final": res.isFinal])
            }
        }
        // segurança: no máximo 20 s ouvindo
        let w = DispatchWorkItem { [weak self] in self?.pararVoz(avisar: true) }
        vozLimite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
        return true
    }

    private func pararVoz(avisar deveAvisar: Bool) {
        vozLimite?.cancel()
        vozLimite = nil
        guard let m = audio else { return }
        m.stop()
        m.inputNode.removeTap(onBus: 0)
        pedidoVoz?.endAudio()
        let tarefa = tarefaVoz
        audio = nil
        pedidoVoz = nil
        tarefaVoz = nil
        // dá um instante para o último pedaço da fala chegar, depois encerra
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            tarefa?.finish()
            self.restaurarAudio()
            if deveAvisar { self.avisar(["tipo": "vozFim"]) }
        }
    }

    /// volta o som ao modo do app (o "som mudo" que mantém o app acordado com a tela apagada)
    private func restaurarAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }
}
