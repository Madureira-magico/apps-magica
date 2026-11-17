import UIKit
import WebKit
import AVFoundation
import AudioToolbox

/// Parte do iPhone só do app Sensor (teste para o Timeline).
/// Recados da página: window.webkit.messageHandlers.sensor.postMessage({cmd: ...})
///   modo {modo: "prox" | "camera" | "mov" | "off"}
///   sens {valor: 0...100}     -> sensibilidade da câmera
///   recalibrar                -> câmera aprende a luz da sala de novo
/// O iPhone responde:
///   window.sensorSinal(coberto 0/1, nivel 0...1, limite 0...1)
///   window.sensorMov(nivel, limite, estado)  estado: 0 calmo, 1 algo passando, 2 parado na frente (ignorado)
///   window.sensorPassada()                   uma passada rápida de mão
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandler, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var web: WKWebView?
    private var modo = "off"

    // câmera
    private let sessao = AVCaptureSession()
    private let filaCam = DispatchQueue(label: "sensor.camera")
    private var camPronta = false
    private var device: AVCaptureDevice?
    private var base = 0.0          // brilho normal da sala
    private var temBase = false
    private var coberto = false
    private var sens = 50.0
    private var inicio: TimeInterval = 0
    private var ultimoEnvio: TimeInterval = 0
    private var ultimoC = -1

    // movimento
    private let GX = 16, GY = 12
    private var fundo: [Double] = []
    private var movDesde: TimeInterval = 0
    private var movEstado = 0
    private var calmoDesde: TimeInterval = 0

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "sensor")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        NotificationCenter.default.addObserver(self, selector: #selector(proxMudou),
                                               name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let corpo = message.body as? [String: Any], let cmd = corpo["cmd"] as? String else { return }
        switch cmd {
        case "modo":
            trocarModo((corpo["modo"] as? String) ?? "off")
        case "sens":
            let v = (corpo["valor"] as? NSNumber)?.doubleValue ?? 50
            filaCam.async { self.sens = v }
        case "recalibrar":
            if modo == "camera" || modo == "mov" { filaCam.async { self.recalibrar() } }
        default: break
        }
    }

    private func trocarModo(_ novo: String) {
        modo = novo
        UIDevice.current.isProximityMonitoringEnabled = (novo == "prox")
        if novo == "camera" || novo == "mov" { ligarCamera() } else { desligarCamera() }
        enviar(0, 0, 0)
    }

    // MARK: sensor de proximidade
    @objc private func proxMudou() {
        guard modo == "prox" else { return }
        let perto = UIDevice.current.proximityState
        if perto { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        enviar(perto ? 1 : 0, 0, 0)
    }

    // MARK: câmera frontal (mede a luz; a mão faz sombra)
    private func ligarCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: iniciarCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in if ok { DispatchQueue.main.async { self.iniciarCamera() } } }
        default:
            DispatchQueue.main.async { self.web?.evaluateJavaScript("window.semCamera&&semCamera()", completionHandler: nil) }
        }
    }

    private func iniciarCamera() {
        filaCam.async {
            if !self.camPronta {
                guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                      let entrada = try? AVCaptureDeviceInput(device: d) else { return }
                self.sessao.beginConfiguration()
                self.sessao.sessionPreset = .low
                if self.sessao.canAddInput(entrada) { self.sessao.addInput(entrada) }
                let saida = AVCaptureVideoDataOutput()
                saida.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                saida.alwaysDiscardsLateVideoFrames = true
                saida.setSampleBufferDelegate(self, queue: self.filaCam)
                if self.sessao.canAddOutput(saida) { self.sessao.addOutput(saida) }
                self.sessao.commitConfiguration()
                self.device = d
                self.camPronta = true
            }
            self.recalibrar()
            if !self.sessao.isRunning { self.sessao.startRunning() }
        }
    }

    private func desligarCamera() {
        filaCam.async { if self.sessao.isRunning { self.sessao.stopRunning() } }
    }

    /// Deixa a câmera ajustar a luz por 1 segundo e depois trava, para a sombra da mão aparecer bem.
    private func recalibrar() {
        temBase = false
        coberto = false
        fundo = []
        movEstado = 0
        inicio = ProcessInfo.processInfo.systemUptime
        if let d = device, (try? d.lockForConfiguration()) != nil {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            d.unlockForConfiguration()
        }
        filaCam.asyncAfter(deadline: .now() + 1.0) {
            if let d = self.device, (try? d.lockForConfiguration()) != nil {
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                d.unlockForConfiguration()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard modo == "camera" || modo == "mov", let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
        let linha = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let b = p.assumingMemoryBound(to: UInt8.self)
        if modo == "mov" { movimento(b, w, h, linha); return }
        var soma = 0, n = 0
        var y = 0
        while y < h { var x = 0; while x < w { soma += Int(b[y * linha + x]); n += 1; x += 8 }; y += 8 }
        let brilho = n > 0 ? Double(soma) / Double(n) / 255.0 : 0

        let agora = ProcessInfo.processInfo.systemUptime
        if agora - inicio < 1.3 { base = brilho; temBase = true; enviar(0, 1, 0, agora); return }
        guard temBase, base > 0.01 else { base = max(brilho, 0.01); temBase = true; return }

        // sensibilidade 0 = precisa escurecer 80%; 100 = basta escurecer 10%
        let queda = 0.8 - 0.7 * (sens / 100)
        let nivel = min(1.5, brilho / base)
        if !coberto {
            if nivel < 1 - queda {
                coberto = true
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            } else {
                base += (brilho - base) * 0.01      // acompanha devagar a luz da sala
            }
        } else if nivel > 1 - queda * 0.6 {
            coberto = false
        }
        enviar(coberto ? 1 : 0, nivel, 1 - queda, agora)
    }

    /// Modo Movimento: compara a imagem com o "fundo" (o teto). Só conta passada rápida:
    /// algo entra e sai em menos de 1 s. Se fica parado na frente (o rosto), é ignorado e vira fundo.
    private func movimento(_ b: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, _ linha: Int) {
        var g = [Double](repeating: 0, count: GX * GY)
        for cy in 0..<GY {
            for cx in 0..<GX {
                var soma = 0, n = 0
                let x0 = cx * w / GX, x1 = (cx + 1) * w / GX, y0 = cy * h / GY, y1 = (cy + 1) * h / GY
                var y = y0
                while y < y1 { var x = x0; while x < x1 { soma += Int(b[y * linha + x]); n += 1; x += 4 }; y += 4 }
                g[cy * GX + cx] = n > 0 ? Double(soma) / Double(n) : 0
            }
        }
        let agora = ProcessInfo.processInfo.systemUptime
        if fundo.count != g.count || agora - inicio < 1.3 { fundo = g; enviarMov(0, 1, 0); return }
        var dif = 0.0
        for i in 0..<g.count { dif += abs(g[i] - fundo[i]) }
        dif /= Double(g.count)
        // sensibilidade 0 = precisa mudar muito (40); 100 = qualquer coisinha (3)
        let lim = 40 * pow(0.075, sens / 100)

        switch movEstado {
        case 0:
            if dif > lim { movEstado = 1; movDesde = agora }
            else { for i in 0..<g.count { fundo[i] += (g[i] - fundo[i]) * 0.05 } }
        case 1:
            if dif < lim * 0.5 {
                let dur = agora - movDesde
                movEstado = 0
                if dur >= 0.06 && dur <= 1.0 {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    DispatchQueue.main.async { self.web?.evaluateJavaScript("window.sensorPassada&&sensorPassada()", completionHandler: nil) }
                }
            } else if agora - movDesde > 1.0 {
                movEstado = 2; calmoDesde = 0           // ficou parado: é rosto ou mudança da sala
            }
        default:
            // ignora e aprende o novo fundo até a imagem ficar parada
            for i in 0..<g.count { fundo[i] += (g[i] - fundo[i]) * 0.15 }
            if dif < lim * 0.5 {
                if calmoDesde == 0 { calmoDesde = agora }
                if agora - calmoDesde > 0.5 { movEstado = 0 }
            } else { calmoDesde = 0 }
        }
        enviarMov(dif, lim, movEstado, agora)
    }

    private func enviarMov(_ dif: Double, _ lim: Double, _ e: Int, _ t: TimeInterval = 0) {
        if t > 0 && t - ultimoEnvio < 0.05 { return }
        ultimoEnvio = t
        let js = String(format: "window.sensorMov&&sensorMov(%.2f,%.2f,%ld)", dif, lim, e)
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func enviar(_ c: Int, _ nivel: Double, _ lim: Double, _ t: TimeInterval = 0) {
        if t > 0 && t - ultimoEnvio < 0.05 && c == ultimoC { return }
        ultimoEnvio = t
        ultimoC = c
        let js = String(format: "window.sensorSinal&&sensorSinal(%ld,%.3f,%.3f)", c, nivel, lim)
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }
}
