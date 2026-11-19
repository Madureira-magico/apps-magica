import UIKit
import WebKit
import CoreHaptics
import AudioToolbox

/// Parte do iPhone só do app Paint.
/// O app abre, escondida por trás da tela de bloqueio falsa, a página de recebimento do paint.land
/// (paint.land/PhoneSimulation, com o login do Ricardo) e avisa a página do app a cada cor que chega.
///
/// Recados da página: window.webkit.messageHandlers.paint.postMessage({cmd: ...}) -> devolve uma resposta
///   vibrar {n, forca, tutu, rep, grave} -> n "vum" + "tutu" no final, repetido rep vezes
///                                (clássica com força 100 = vibração de chamada; grave = tremor grosso)
///   toque                        -> um toquinho de vibração (confirma o Reconectar pelo botão da câmera)
///   pararVibrar                  -> corta a vibração
///   iniciar                      -> abre a página do paint.land escondida (se ainda não abriu)
///   recarregar                   -> recarrega a página do paint.land (reconectar)
///   entrar                       -> abre uma tela própria com a página do paint.land, para fazer o login
///   maleta                       -> desenho da maleta do iPhone (modo Foco), em PNG
///   telaCobrir / icones / ...    -> peça pronta TelasNativas (comum/telas)
/// O iPhone avisa a página: window.paintRx({tipo: ...})
///   url {path} / pagina {path}       -> endereço que a página do paint.land abriu
///   login                            -> o paint.land pediu login
///   estado {conectado, grupo}        -> conectado ao servidor e o número da página (ex.: 1108)
///   inicial {texto} / texto {texto}  -> texto que a página mostra embaixo (a cor que chegou)
///   msg {msg}                        -> recado bruto que chegou do servidor (para conferir)
///   mostrando {on}                   -> a página do paint.land está (ou não) na tela para o login
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private static let endereco = URL(string: "https://paint.land/PhoneSimulation")!
    private static let enderecoLogin = URL(string: "https://paint.land/Identity/Account/Login?ReturnUrl=%2Fadmin")!

    /// O app se apresenta ao site igual ao Safari do iPhone (sem isso o paint.land não responde).
    static var nomeSafari: String {
        let v = UIDevice.current.systemVersion.split(separator: ".")
        let versao = v.prefix(2).joined(separator: ".")
        return "Version/\(versao) Mobile/15E148 Safari/604.1"
    }

    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    private let telas = TelasNativas()

    private var receptor: WKWebView?
    private weak var telaLogin: TelaLogin?
    private var mostrando = false
    private var conectado = false
    private var desconectadoDesde = Date()
    private var vigia: Timer?

    private var motor: CHHapticEngine?
    private var tocando: CHHapticPatternPlayer?
    private var geracao = 0

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "paint")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
        telas.web = webView
        prepararVibracao()
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.voltouParaApp() }
    }

    // MARK: recados da página do app
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let responder: (Any?) -> Void = { valor in DispatchQueue.main.async { replyHandler(valor, nil) } }
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String else { return responder(false) }
        if telas.tratar(cmd, d, responder) { return }
        func num(_ k: String, _ p: Double) -> Double { (d[k] as? NSNumber)?.doubleValue ?? p }
        switch cmd {
        case "vibrar":
            vibrar(Int(num("n", 1)), forca: num("forca", 100), tutu: (d["tutu"] as? Bool) ?? true,
                   rep: Int(num("rep", 1)), grave: (d["grave"] as? Bool) ?? false)
            responder(true)
        case "toque":
            DispatchQueue.main.async {
                let g = UIImpactFeedbackGenerator(style: .heavy)
                g.prepare()
                g.impactOccurred()
                responder(true)
            }
        case "pararVibrar":
            cortarVibracao(); responder(true)
        case "iniciar":
            DispatchQueue.main.async { self.criarReceptor(); responder(true) }
        case "recarregar":
            DispatchQueue.main.async { self.recarregar(); responder(true) }
        case "entrar":
            DispatchQueue.main.async { self.abrirLogin(); responder(true) }
        case "maleta":
            responder(maleta())
        default:
            responder(false)
        }
    }

    private func avisar(_ o: [String: Any]) {
        guard let dados = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: dados, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.paintRx&&window.paintRx(\(json))", completionHandler: nil) }
    }

    // MARK: página do paint.land, escondida atrás da tela do app
    private func criarReceptor() {
        guard receptor == nil, let web = web else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // guarda o login de uma vez para a outra
        config.applicationNameForUserAgent = PonteExtra.nomeSafari
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let uc = config.userContentController
        uc.add(Recado(self), name: "rx")
        uc.addUserScript(WKUserScript(source: PonteExtra.espiao, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let r = WKWebView(frame: web.bounds, configuration: config)
        r.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        r.navigationDelegate = self
        r.isUserInteractionEnabled = false
        r.backgroundColor = .white
        // fica por baixo de tudo, atrás da tela do app (que cobre por inteiro); só serve para receber
        if let jan = web.window {
            r.frame = jan.bounds
            jan.insertSubview(r, at: 0)
        } else {
            web.insertSubview(r, at: 0)
        }
        receptor = r
        r.load(URLRequest(url: PonteExtra.endereco))
        vigia?.invalidate()
        vigia = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.vigiar() }
    }

    private func recarregar() {
        guard let r = receptor else { return criarReceptor() }
        conectado = false
        desconectadoDesde = Date()
        r.load(URLRequest(url: PonteExtra.endereco))
    }

    /// Caiu a conexão e não voltou sozinha: recarrega a página (não mexe enquanto o login está na tela).
    private func vigiar() {
        guard receptor != nil, !mostrando, !conectado else { return }
        if Date().timeIntervalSince(desconectadoDesde) > 20 { recarregar() }
    }

    private func voltouParaApp() {
        guard let r = receptor, !mostrando else { return }
        // ao voltar para o app, confere na hora se a página ainda está conectada
        r.evaluateJavaScript("window.__paintEstado&&window.__paintEstado(true)", completionHandler: nil)
        if !conectado && Date().timeIntervalSince(desconectadoDesde) > 3 { recarregar() }
    }

    fileprivate func recebeu(_ corpo: Any) {
        guard let d = corpo as? [String: Any], let tipo = d["tipo"] as? String else { return }
        if tipo == "estado" {
            let c = (d["conectado"] as? Bool) ?? false
            if c != conectado { conectado = c; if !c { desconectadoDesde = Date() } }
        }
        avisar(d)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let path = webView.url?.path.lowercased() ?? ""
        avisar(["tipo": "pagina", "path": webView.url?.path ?? ""])
        if path.contains("/login") || path.contains("/identity/account") {
            conectado = false
            avisar(["tipo": "login"])
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        conectado = false
        avisar(["tipo": "erro"])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        conectado = false
        avisar(["tipo": "erro"])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        conectado = false
        recarregar()
    }

    /// Abre o login numa tela própria (como uma janela normal do iPhone). O login fica guardado
    /// no mesmo lugar que a página escondida usa, então ela passa a entrar sozinha.
    private func abrirLogin() {
        guard telaLogin == nil, let tela = tela else { return }
        let t = TelaLogin(endereco: PonteExtra.enderecoLogin)
        t.terminou = { [weak self] in self?.loginTerminou() }
        t.modalPresentationStyle = .fullScreen
        telaLogin = t
        mostrando = true
        avisar(["tipo": "mostrando", "on": true])
        var topo = tela
        while let p = topo.presentedViewController { topo = p }
        topo.present(t, animated: true)
    }

    private func loginTerminou() {
        mostrando = false
        avisar(["tipo": "mostrando", "on": false])
        recarregar()
    }

    /// Desenho da maleta do modo Foco do iPhone (o mesmo da tela bloqueada de verdade).
    private func maleta() -> String {
        let conf = UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        guard let img = UIImage(systemName: "briefcase.fill", withConfiguration: conf)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return "" }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        let r = UIGraphicsImageRenderer(size: img.size, format: f)
        let dados = r.pngData { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
        return "data:image/png;base64," + dados.base64EncodedString()
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

    private func cortarVibracao() {
        geracao += 1
        try? tocando?.stop(atTime: CHHapticTimeImmediate)
        tocando = nil
    }

    // tempos medidos no vídeo do outro app
    private let vum = 0.43, pausa = 0.37, entreTutu = 0.09, entreRepeticoes = 2.0

    /// n "vum" + "tutu" (dois toquinhos rápidos) no final; tudo repetido rep vezes.
    /// Uma cor nova corta a vibração que ainda estava tocando.
    private func vibrar(_ n: Int, forca: Double, tutu: Bool, rep: Int, grave: Bool) {
        let n = max(0, min(n, 12)), rep = max(1, min(rep, 5))
        DispatchQueue.main.async {
            self.cortarVibracao()
            guard n > 0 else { return }
            if (forca >= 99 && !grave) || self.motor == nil { return self.vibrarSistema(n, tutu: tutu, rep: rep) }
            // grave: "nitidez" no mínimo = tremor mais grosso; a clássica ajustável fica um pouco mais aguda
            let nitidez: Float = grave ? 0.0 : 0.2
            let intensidade = Float(0.15 + 0.85 * min(forca, 100) / 100)
            var eventos: [CHHapticEvent] = []
            var t = 0.0
            for _ in 0..<rep {
                for i in 0..<n {
                    eventos.append(CHHapticEvent(eventType: .hapticContinuous,
                                                 parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensidade),
                                                              CHHapticEventParameter(parameterID: .hapticSharpness, value: nitidez)],
                                                 relativeTime: t, duration: self.vum))
                    t += self.vum + (i < n - 1 ? self.pausa : 0)
                }
                if tutu {
                    t += self.pausa
                    for k in 0..<2 {
                        eventos.append(CHHapticEvent(eventType: .hapticTransient,
                                                     parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.75)],
                                                     relativeTime: t + Double(k) * self.entreTutu))
                    }
                    t += self.entreTutu
                }
                t += self.entreRepeticoes
            }
            do {
                try self.motor?.start()
                guard let m = self.motor else { return }
                let p = try m.makePlayer(with: CHHapticPattern(events: eventos, parameters: []))
                try p.start(atTime: CHHapticTimeImmediate)
                self.tocando = p
            } catch {
                self.vibrarSistema(n, tutu: tutu, rep: rep)
            }
        }
    }

    /// Força no máximo: a vibração clássica do iPhone (a de chamada), a mais forte. O "tutu" são dois toques curtos.
    private func vibrarSistema(_ n: Int, tutu: Bool, rep: Int) {
        let g = geracao
        let passo = 0.8           // a vibração clássica dura ~0,4 s e não pode ser mais curta
        var t = 0.0
        func em(_ s: Double, _ som: SystemSoundID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                guard g == self.geracao else { return }
                AudioServicesPlaySystemSound(som)
            }
        }
        for _ in 0..<rep {
            for i in 0..<n {
                em(t, kSystemSoundID_Vibrate)
                t += i < n - 1 ? passo : 0.6
            }
            if tutu {
                em(t, 1520); em(t + 0.12, 1520)
                t += 0.12
            }
            t += entreRepeticoes
        }
    }

    // MARK: o que roda dentro da página do paint.land (só observa, não muda nada nela)
    private static let espiao = """
    (function(){
      if(window.__paintRx) return; window.__paintRx = 1;
      function post(o){ try{ window.webkit.messageHandlers.rx.postMessage(o); }catch(e){} }
      post({tipo:'url', path: location.pathname});
      function vis(id){ var e = document.getElementById(id); if(!e) return false; return getComputedStyle(e).display !== 'none'; }
      var ult = null;
      window.__paintEstado = function(forcar){
        var b = document.querySelector('#connected b');
        var o = {tipo:'estado', conectado: vis('connected'), grupo: b ? b.textContent.trim() : '', usuario: vis('userConnected')};
        var k = JSON.stringify(o);
        if(forcar || k !== ult){ ult = k; post(o); }
      };
      setInterval(function(){ window.__paintEstado(false); }, 700);
      window.__paintEstado(true);
      var nc = document.getElementById('namedColor');
      if(nc){
        post({tipo:'inicial', texto: nc.textContent});
        new MutationObserver(function(){ post({tipo:'texto', texto: nc.textContent}); })
          .observe(nc, {childList:true, characterData:true, subtree:true});
      }
      try{
        var orig = window.ClientSendDataCallback;
        if(typeof orig === 'function'){
          window.ClientSendDataCallback = function(m){
            try{ post({tipo:'msg', msg: JSON.parse(JSON.stringify(m))}); }catch(e){}
            return orig.apply(this, arguments);
          };
        }
      }catch(e){}
    })();
    """
}

/// Repassa os recados da página do paint.land sem prender o PonteExtra na memória.
private final class Recado: NSObject, WKScriptMessageHandler {
    weak var dono: PonteExtra?
    init(_ dono: PonteExtra) { self.dono = dono }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        dono?.recebeu(message.body)
    }
}

/// Tela do login do paint.land: barra de cima com o endereço, Recarregar e Fechar.
/// Fecha sozinha quando sai das páginas de login (entrou) e volta para a página de recebimento.
final class TelaLogin: UIViewController, WKNavigationDelegate {
    var terminou: (() -> Void)?
    private let endereco: URL
    private var web: WKWebView!
    private let titulo = UILabel()
    private let carregando = UIActivityIndicatorView(style: .medium)
    private var viuLogin = false
    private var fechou = false
    private var progresso: NSKeyValueObservation?
    private var demora: Timer?

    init(endereco: URL) { self.endereco = endereco; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let barra = UIView()
        barra.backgroundColor = .secondarySystemBackground
        barra.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barra)

        let fechar = UIButton(type: .system)
        fechar.setTitle("Fechar", for: .normal)
        fechar.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        fechar.addTarget(self, action: #selector(tocouFechar), for: .touchUpInside)
        let recarregar = UIButton(type: .system)
        recarregar.setTitle("Recarregar", for: .normal)
        recarregar.titleLabel?.font = .systemFont(ofSize: 17)
        recarregar.addTarget(self, action: #selector(tocouRecarregar), for: .touchUpInside)
        titulo.font = .systemFont(ofSize: 13)
        titulo.textColor = .secondaryLabel
        titulo.textAlignment = .center
        titulo.adjustsFontSizeToFitWidth = true
        titulo.minimumScaleFactor = 0.7
        titulo.text = "Abrindo o paint.land…"
        carregando.hidesWhenStopped = true
        for v in [fechar, recarregar, titulo, carregando] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            barra.addSubview(v)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = PonteExtra.nomeSafari
        web = WKWebView(frame: .zero, configuration: config)
        progresso = web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            guard let self = self, w.isLoading else { return }
            self.titulo.text = "Carregando \(Int(w.estimatedProgress * 100))%"
        }
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        NSLayoutConstraint.activate([
            barra.topAnchor.constraint(equalTo: view.topAnchor),
            barra.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barra.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barra.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            recarregar.leadingAnchor.constraint(equalTo: barra.leadingAnchor, constant: 14),
            recarregar.bottomAnchor.constraint(equalTo: barra.bottomAnchor, constant: -8),
            fechar.trailingAnchor.constraint(equalTo: barra.trailingAnchor, constant: -14),
            fechar.centerYAnchor.constraint(equalTo: recarregar.centerYAnchor),
            titulo.centerXAnchor.constraint(equalTo: barra.centerXAnchor),
            titulo.centerYAnchor.constraint(equalTo: recarregar.centerYAnchor),
            titulo.leadingAnchor.constraint(greaterThanOrEqualTo: recarregar.trailingAnchor, constant: 8),
            titulo.trailingAnchor.constraint(lessThanOrEqualTo: fechar.leadingAnchor, constant: -8),
            carregando.trailingAnchor.constraint(equalTo: fechar.leadingAnchor, constant: -6),
            carregando.centerYAnchor.constraint(equalTo: recarregar.centerYAnchor),
            web.topAnchor.constraint(equalTo: barra.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        carregar()
    }

    private func carregar() {
        web.load(URLRequest(url: endereco, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        demora?.invalidate()
        demora = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.web.isLoading else { return }
            self.titulo.text = "Demorando… toque em Recarregar"
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
    override var prefersStatusBarHidden: Bool { false }

    @objc private func tocouFechar() { sair() }
    @objc private func tocouRecarregar() { carregar() }

    private func sair() {
        guard !fechou else { return }
        fechou = true
        dismiss(animated: true) { [weak self] in self?.terminou?() }
    }

    private func mostrarEndereco() {
        guard let u = web.url else { return }
        titulo.text = (u.host ?? "") + u.path
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        carregando.startAnimating()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        mostrarEndereco()
        conferir(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        carregando.stopAnimating()
        demora?.invalidate()
        mostrarEndereco()
        conferir(webView)
    }

    private func conferir(_ webView: WKWebView) {
        let path = webView.url?.path.lowercased() ?? ""
        if path.contains("/identity/account") || path.contains("/login") {
            viuLogin = true
        } else if !path.isEmpty {
            // saiu do login (entrou) ou já estava logado: volta para o app
            titulo.text = "Entrou! Voltando…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.sair() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        carregando.stopAnimating()
        demora?.invalidate()
        if (error as NSError).code == NSURLErrorCancelled { return }
        titulo.text = "Erro: " + error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        carregando.stopAnimating()
        demora?.invalidate()
        if (error as NSError).code == NSURLErrorCancelled { return }
        titulo.text = "Erro: " + error.localizedDescription
    }
}
