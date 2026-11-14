import UIKit
import WebKit
import AVFoundation

/// Peça comum a todos os apps de mágica: abre a pasta www (dentro do app) em tela cheia, sem internet.
/// A página conversa com o iPhone por três "recados":
///   barra  -> true esconde / false mostra a barra de cima (hora, sinal, bateria)
///   estilo -> "escuro" (letras pretas) ou "claro" (letras brancas) na barra de cima
///   som    -> toca o clique.mp3 do app (se existir) com o volume pedido (0 a 1)
///   ble    -> Bluetooth feito pelo próprio iPhone (ponte-bluetooth.js + PonteBluetooth.swift)
///   giro   -> true: pode deitar o iPhone (e já deita) / false: volta em pé (só apps com DEITAR=1)
///   segundoPlano -> true: um som mudo mantém o app acordado com a tela apagada (só apps com SEGUNDO_PLANO=1)
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var esconderBarra = false
    private var barraEscura = false
    private var clique: AVAudioPlayer?
    private let esconderIndicador = (Bundle.main.object(forInfoDictionaryKey: "EsconderIndicador") as? Bool) ?? false
    private let manterAcesa = (Bundle.main.object(forInfoDictionaryKey: "ManterTelaAcesa") as? Bool) ?? false
    private let ponte = PonteBluetooth()
    private var mudo: AVAudioPlayer?
    private var querMudo = false
    private let permiteDeitar = (Bundle.main.object(forInfoDictionaryKey: "PermiteDeitar") as? Bool) ?? false
    private var deitado = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // Avisa a página que ela está dentro do app
        let flag = WKUserScript(source: "window.__NATIVE_APP__=true;",
                                injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(flag)
        if let url = Bundle.main.url(forResource: "ponte-bluetooth", withExtension: "js"),
           let codigo = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: codigo, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for nome in ["barra", "estilo", "som", "ble", "segundoPlano", "giro"] {
            config.userContentController.add(self, name: nome)
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsLinkPreview = false
        view = webView
        ponte.webView = webView
        ponte.tela = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if manterAcesa { UIApplication.shared.isIdleTimerDisabled = true }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        prepararClique()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // a pinça é do efeito, não do zoom da página
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "barra":
            guard let esconder = message.body as? Bool, esconder != esconderBarra else { return }
            esconderBarra = esconder
            UIView.animate(withDuration: 0.15) { self.setNeedsStatusBarAppearanceUpdate() }
        case "estilo":
            let escura = (message.body as? String) == "escuro"
            guard escura != barraEscura else { return }
            barraEscura = escura
            setNeedsStatusBarAppearanceUpdate()
        case "som":
            tocarClique(volume: (message.body as? NSNumber)?.floatValue ?? 1)
        case "ble":
            ponte.receber(message.body)
        case "segundoPlano":
            ligarMudo((message.body as? Bool) ?? false)
        case "giro":
            girar((message.body as? Bool) ?? false)
        default:
            break
        }
    }

    // MARK: clique da câmera (só nos apps que têm o arquivo clique.mp3)
    private func prepararClique() {
        guard let url = Bundle.main.url(forResource: "clique", withExtension: "mp3") else { return }
        // .playback: toca mesmo com o iPhone no silencioso; mixWithOthers: não corta outros sons
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        clique = try? AVAudioPlayer(contentsOf: url)
        clique?.prepareToPlay()
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.clique?.prepareToPlay()
        }
    }

    private func tocarClique(volume: Float) {
        guard let p = clique, volume > 0 else { return }
        p.volume = min(1, max(0, volume))
        if p.isPlaying { p.stop() }
        p.currentTime = 0
        if !p.play() {
            try? AVAudioSession.sharedInstance().setActive(true)
            p.prepareToPlay()
            p.play()
        }
    }

    // MARK: segundo plano (tela apagada)
    private func ligarMudo(_ ligar: Bool) {
        querMudo = ligar
        guard ligar else { mudo?.stop(); return }
        let sessao = AVAudioSession.sharedInstance()
        try? sessao.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? sessao.setActive(true)
        if mudo == nil {
            mudo = try? AVAudioPlayer(data: PonteMudo.wav())
            mudo?.numberOfLoops = -1
            mudo?.volume = 0.01
            _ = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                // depois de uma ligação ou alarme, volta a tocar o som mudo
                guard let self = self, self.querMudo else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.mudo?.play()
            }
            _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                guard let self = self, self.querMudo else { return }
                if self.mudo?.isPlaying != true { self.mudo?.play() }
            }
        }
        mudo?.play()
    }

    // MARK: deitar o iPhone (escrita manual)
    private func girar(_ deitar: Bool) {
        guard permiteDeitar, deitar != deitado else { return }
        deitado = deitar
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            let mascara: UIInterfaceOrientationMask = deitar ? .landscape : .portrait
            view.window?.windowScene?.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mascara)) { _ in }
        } else {
            UIDevice.current.setValue((deitar ? UIInterfaceOrientation.landscapeRight : .portrait).rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    // MARK: janelinhas da página (alert, confirm, prompt) — sem isso o iPhone não mostra nada
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil else { return completionHandler() }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else { return completionHandler(false) }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard presentedViewController == nil else { return completionHandler(nil) }
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { campo in campo.text = defaultText; campo.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }

    // Libera o sensor de movimento sem perguntar
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    override var prefersStatusBarHidden: Bool { esconderBarra }
    override var preferredStatusBarStyle: UIStatusBarStyle { barraEscura ? .darkContent : .lightContent }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var prefersHomeIndicatorAutoHidden: Bool { esconderIndicador }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { deitado ? .landscape : .portrait }
}

/// Um segundo de "som" baixinho (inaudível), em formato WAV, feito na hora.
enum PonteMudo {
    static func wav() -> Data {
        let n = 8000
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(n * 2))
        for i in 0..<n { u16(i % 2 == 0 ? 1 : 0xFFFF) }
        return d
    }
}
