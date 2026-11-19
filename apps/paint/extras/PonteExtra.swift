import UIKit
import WebKit
import CoreHaptics
import AudioToolbox

/// Parte do iPhone só do app Paint.
/// O app abre, escondida por trás da tela de bloqueio falsa, a página de recebimento do paint.land
/// (paint.land/PhoneSimulation, com o login do Ricardo) e avisa a página do app a cada cor que chega.
///
/// Recados da página: window.webkit.messageHandlers.paint.postMessage({cmd: ...}) -> devolve uma resposta
///   vibrar {n, forca, tutu, rep} -> n "vum" + "tutu" no final, repetido rep vezes (força 100 = vibração clássica)
///   pararVibrar                  -> corta a vibração
///   iniciar                      -> abre a página do paint.land escondida (se ainda não abriu)
///   recarregar                   -> recarrega a página do paint.land (reconectar)
///   entrar                       -> mostra a página do paint.land na tela, para fazer o login
///   maleta                       -> desenho da maleta do iPhone (modo Foco), em PNG
///   telaCobrir / icones / ...    -> peça pronta TelasNativas (comum/telas)
/// O iPhone avisa a página: window.paintRx({tipo: ...})
///   url {path}                       -> endereço que a página do paint.land abriu
///   login                            -> o paint.land pediu login
///   estado {conectado, grupo}        -> conectado ao servidor e o número da página (ex.: 1108)
///   inicial {texto} / texto {texto}  -> texto que a página mostra embaixo (a cor que chegou)
///   msg {msg}                        -> recado bruto que chegou do servidor (para conferir)
///   mostrando {on}                   -> a página do paint.land está (ou não) na tela para o login
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private static let endereco = URL(string: "https://paint.land/PhoneSimulation")!

    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    private let telas = TelasNativas()

    private var receptor: WKWebView?
    private var fechar: UIButton?
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
            vibrar(Int(num("n", 1)), forca: num("forca", 100), tutu: (d["tutu"] as? Bool) ?? true, rep: Int(num("rep", 1)))
            responder(true)
        case "pararVibrar":
            cortarVibracao(); responder(true)
        case "iniciar":
            DispatchQueue.main.async { self.criarReceptor(); responder(true) }
        case "recarregar":
            DispatchQueue.main.async { self.recarregar(); responder(true) }
        case "entrar":
            DispatchQueue.main.async { self.mostrar(true); responder(true) }
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
        // fica por baixo de tudo: a página do app (fundo preto) cobre por inteiro
        web.insertSubview(r, at: 0)
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
        if tipo == "url", let path = d["path"] as? String {
            if path.lowercased().contains("/phonesimulation") {
                // login feito: a página de recebimento abriu, some da tela
                if mostrando { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.mostrar(false) } }
            }
        }
        avisar(d)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let path = webView.url?.path.lowercased() ?? ""
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

    /// Mostra (ou esconde) a página do paint.land por cima de tudo, para fazer o login.
    private func mostrar(_ on: Bool) {
        if receptor == nil { criarReceptor() }
        guard let r = receptor, let web = web else { return }
        mostrando = on
        if on {
            web.bringSubviewToFront(r)
            r.isUserInteractionEnabled = true
            r.frame = web.bounds
            r.scrollView.contentInsetAdjustmentBehavior = .automatic
            if fechar == nil {
                let b = UIButton(type: .system)
                b.setTitle("Fechar", for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
                b.setTitleColor(.white, for: .normal)
                b.backgroundColor = UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
                b.layer.cornerRadius = 18
                b.addTarget(self, action: #selector(tocouFechar), for: .touchUpInside)
                fechar = b
            }
            if let b = fechar {
                let topo = web.safeAreaInsets.top
                b.frame = CGRect(x: web.bounds.width - 106, y: topo + 6, width: 94, height: 36)
                b.autoresizingMask = [.flexibleLeftMargin]
                web.addSubview(b)
            }
            // abre a página de entrada do paint.land (se já estiver logado, cai direto na de recebimento)
            r.load(URLRequest(url: PonteExtra.endereco))
        } else {
            fechar?.removeFromSuperview()
            r.isUserInteractionEnabled = false
            r.scrollView.contentInsetAdjustmentBehavior = .never
            web.sendSubviewToBack(r)
            r.load(URLRequest(url: PonteExtra.endereco))
        }
        avisar(["tipo": "mostrando", "on": on])
    }

    @objc private func tocouFechar() { mostrar(false) }

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
    private func vibrar(_ n: Int, forca: Double, tutu: Bool, rep: Int) {
        let n = max(0, min(n, 12)), rep = max(1, min(rep, 5))
        DispatchQueue.main.async {
            self.cortarVibracao()
            guard n > 0 else { return }
            if forca >= 99 || self.motor == nil { return self.vibrarSistema(n, tutu: tutu, rep: rep) }
            let intensidade = Float(0.15 + 0.85 * min(forca, 100) / 100)
            var eventos: [CHHapticEvent] = []
            var t = 0.0
            for _ in 0..<rep {
                for i in 0..<n {
                    eventos.append(CHHapticEvent(eventType: .hapticContinuous,
                                                 parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensidade),
                                                              CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)],
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
