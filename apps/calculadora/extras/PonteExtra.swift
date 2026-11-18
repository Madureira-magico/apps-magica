import UIKit
import WebKit
import Photos

/// Parte do iPhone só do app Calculadora.
/// Recados da página: window.webkit.messageHandlers.calc.postMessage({cmd: ...}) -> devolve uma resposta
///   salvarFoto {png}  -> guarda a imagem (base64) direto no app Fotos; responde "ok", "negado" ou "erro"
///   imprimir {png}    -> abre a janela de impressão do iPhone com a imagem (folha em pé)
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply {
    private weak var web: WKWebView?
    private weak var tela: UIViewController?

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "calc")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let responder: (Any?) -> Void = { valor in DispatchQueue.main.async { replyHandler(valor, nil) } }
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String else { return responder("erro") }
        switch cmd {
        case "salvarFoto":
            guard let img = imagem(d["png"]) else { return responder("erro") }
            salvar(img, responder)
        case "imprimir":
            guard let img = imagem(d["png"]) else { return responder("erro") }
            DispatchQueue.main.async { self.imprimir(img, responder) }
        default:
            responder("erro")
        }
    }

    private func imagem(_ v: Any?) -> UIImage? {
        guard var s = v as? String else { return nil }
        if let i = s.range(of: "base64,") { s = String(s[i.upperBound...]) }
        guard let dados = Data(base64Encoded: s) else { return nil }
        return UIImage(data: dados)
    }

    private func salvar(_ img: UIImage, _ responder: @escaping (Any?) -> Void) {
        let grava = {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }) { ok, _ in responder(ok ? "ok" : "erro") }
        }
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch st {
        case .authorized, .limited: grava()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { novo in
                if novo == .authorized || novo == .limited { grava() } else { responder("negado") }
            }
        default: responder("negado")
        }
    }

    private func imprimir(_ img: UIImage, _ responder: @escaping (Any?) -> Void) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Nome"
        info.orientation = .portrait
        let p = UIPrintInteractionController.shared
        p.printInfo = info
        p.printingItem = img
        p.present(animated: true) { _, feito, _ in responder(feito ? "ok" : "cancelado") }
    }
}
