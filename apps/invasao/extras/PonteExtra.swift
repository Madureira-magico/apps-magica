import UIKit
import WebKit

/// Parte do iPhone só do app Invasão.
/// Conversa direto com o aparelho EXPLODE SYSTEM (ESP32) pela rede Wi-Fi dele (http://192.168.4.1).
/// O pedido é feito pelo próprio iPhone (e não pela página), assim não tem bloqueio de navegador.
///
/// Recados da página: window.webkit.messageHandlers.invasao.postMessage({cmd: ...}) -> devolve uma resposta
///   http {caminho, tempo}  -> GET http://192.168.4.1 + caminho; responde {ok, status, corpo}
///                             ex.: /api/setword?word=6%20%E2%99%A6%EF%B8%8F, /api/start, /api/stop,
///                                  /api/status, /api/wifi_scan, /api/gpio20?on=1&brightness=50&blink_tx=1
///   toque                  -> um toquinho de vibração (cada rede que se transforma, se ligado no menu)
///   erro                   -> vibração de erro (o aparelho não respondeu)
///   telaCobrir / icones / bateria ... -> peça pronta TelasNativas (comum/telas)
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply {
    private weak var web: WKWebView?
    private let telas = TelasNativas()

    /// Sessão só para a rede local: sem cache e sem usar os dados móveis (o aparelho está no Wi-Fi).
    private lazy var sessao: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.allowsCellularAccess = false
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 30
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "invasao")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        telas.web = webView
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let responder: (Any?) -> Void = { valor in DispatchQueue.main.async { replyHandler(valor, nil) } }
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String else { return responder(false) }
        if telas.tratar(cmd, d, responder) { return }
        switch cmd {
        case "http":
            let caminho = (d["caminho"] as? String) ?? "/"
            let tempo = max(1, min(30, (d["tempo"] as? NSNumber)?.doubleValue ?? 5))
            pedir(caminho, tempo: tempo, responder)
        case "toque":
            DispatchQueue.main.async {
                let g = UIImpactFeedbackGenerator(style: .light)
                g.prepare()
                g.impactOccurred()
                responder(true)
            }
        case "erro":
            DispatchQueue.main.async {
                let g = UINotificationFeedbackGenerator()
                g.prepare()
                g.notificationOccurred(.error)
                responder(true)
            }
        default:
            responder(false)
        }
    }

    private func pedir(_ caminho: String, tempo: Double, _ responder: @escaping (Any?) -> Void) {
        // o caminho já vem com os acentos e símbolos codificados pela página (%E2%99%A6...)
        let limpo = caminho.hasPrefix("/") ? caminho : "/" + caminho
        guard let url = URL(string: "http://192.168.4.1" + limpo) else {
            return responder(["ok": false, "status": 0, "corpo": "", "erro": "endereço inválido"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = tempo
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpMethod = "GET"
        sessao.dataTask(with: req) { data, resp, err in
            let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let corpo = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            responder(["ok": err == nil && st >= 200 && st < 300, "status": st, "corpo": corpo,
                       "erro": err?.localizedDescription ?? ""])
        }.resume()
    }
}
