import UIKit
import WebKit
import AVFoundation

/// Peça comum a todos os apps de mágica: abre a pasta www (dentro do app) em tela cheia, sem internet.
/// A página conversa com o iPhone por três "recados":
///   barra  -> true esconde / false mostra a barra de cima (hora, sinal, bateria)
///   estilo -> "escuro" (letras pretas) ou "claro" (letras brancas) na barra de cima
///   som    -> toca o clique.mp3 do app (se existir) com o volume pedido (0 a 1)
///   ble    -> Bluetooth feito pelo próprio iPhone (ponte-bluetooth.js + PonteBluetooth.swift)
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var esconderBarra = false
    private var barraEscura = false
    private var clique: AVAudioPlayer?
    private let esconderIndicador = (Bundle.main.object(forInfoDictionaryKey: "EsconderIndicador") as? Bool) ?? false
    private let manterAcesa = (Bundle.main.object(forInfoDictionaryKey: "ManterTelaAcesa") as? Bool) ?? false
    private let ponte = PonteBluetooth()

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
        for nome in ["barra", "estilo", "som", "ble"] {
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
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}
