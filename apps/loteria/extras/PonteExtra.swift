import UIKit
import WebKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// Parte do iPhone só do app Loterias.
/// Recados da página: window.webkit.messageHandlers.lt.postMessage({cmd: ...}) devolve uma resposta.
///   buscar {url}            -> texto da página da internet (sem o bloqueio de "outro site" do navegador)
///   salvar {nome, dados}    -> guarda um arquivo (dados em base64) dentro do app
///   apagar {nome}           -> apaga o arquivo
///   escolherVideo           -> abre a galeria (só vídeos) e guarda o escolhido como abertura.mov
///   temVideo                -> true/false
///   tocarVideo              -> toca o vídeo da abertura por cima de tudo, em tela cheia; responde quando acaba
/// Arquivos guardados aparecem para a página pelo endereço ltarq://f/nome
@objc(PonteExtra)
final class PonteExtra: NSObject, ExtraDoApp, WKScriptMessageHandlerWithReply, WKURLSchemeHandler,
                        PHPickerViewControllerDelegate {
    typealias Resposta = (Any?, String?) -> Void

    private weak var web: WKWebView?
    private weak var tela: UIViewController?
    private var parados = Set<ObjectIdentifier>()
    private var escolhaResposta: Resposta?

    // vídeo da abertura
    private var player: AVPlayer?
    private var capa: UIView?
    private var fimVideo: Any?

    func instalar(_ config: WKWebViewConfiguration) {
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "lt")
        config.setURLSchemeHandler(self, forURLScheme: "ltarq")
    }

    func ligar(_ webView: WKWebView, tela: UIViewController) {
        web = webView
        self.tela = tela
    }

    private var pasta: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("loterias", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func arq(_ nome: String) -> URL {
        let limpo = nome.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return pasta.appendingPathComponent(limpo)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping Resposta) {
        let responder: Resposta = { valor, erro in DispatchQueue.main.async { replyHandler(valor, erro) } }
        guard let corpo = message.body as? [String: Any], let cmd = corpo["cmd"] as? String else {
            return responder(nil, "recado errado")
        }
        switch cmd {
        case "buscar":
            guard let s = corpo["url"] as? String, let url = URL(string: s) else { return responder(nil, "endereço") }
            var pedido = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            pedido.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            pedido.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                            forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: pedido) { dados, resp, erro in
                let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard erro == nil, codigo == 200, let d = dados, let txt = String(data: d, encoding: .utf8) else {
                    return responder(nil, "falhou \(codigo)")
                }
                responder(txt, nil)
            }.resume()
        case "salvar":
            guard let nome = corpo["nome"] as? String, let b64 = corpo["dados"] as? String,
                  let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return responder(false, nil) }
            do { try d.write(to: arq(nome), options: .atomic); responder(true, nil) } catch { responder(false, nil) }
        case "apagar":
            if let nome = corpo["nome"] as? String { try? FileManager.default.removeItem(at: arq(nome)) }
            responder(true, nil)
        case "temVideo":
            responder(FileManager.default.fileExists(atPath: arq("abertura.mov").path), nil)
        case "escolherVideo":
            escolherVideo(responder)
        case "tocarVideo":
            tocarVideo(responder)
        default:
            responder(nil, "desconhecido")
        }
    }

    // MARK: escolher o vídeo da abertura na galeria
    private func escolherVideo(_ resposta: @escaping Resposta) {
        guard let tela = tela else { return resposta(false, nil) }
        var cfg = PHPickerConfiguration()
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let p = PHPickerViewController(configuration: cfg)
        p.delegate = self
        escolhaResposta = resposta
        tela.present(p, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let resposta = escolhaResposta
        escolhaResposta = nil
        guard let item = results.first?.itemProvider,
              item.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { resposta?(false, nil); return }
        item.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let self = self, let url = url else { resposta?(false, nil); return }
            let destino = self.arq("abertura.mov")
            try? FileManager.default.removeItem(at: destino)
            do {
                try FileManager.default.copyItem(at: url, to: destino)
                DispatchQueue.main.async { resposta?(true, nil) }
            } catch {
                DispatchQueue.main.async { resposta?(false, nil) }
            }
        }
    }

    // MARK: tocar o vídeo da abertura por cima de tudo
    /// A faixa de cima do vídeo (hora, Wi-Fi, bateria da gravação) é coberta com a linha logo abaixo dela,
    /// esticada — assim aparece só a barra de status de verdade do iPhone.
    private func tocarVideo(_ resposta: @escaping Resposta) {
        let u = arq("abertura.mov")
        guard let tela = tela, FileManager.default.fileExists(atPath: u.path) else { return resposta(false, nil) }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        let p = AVPlayer(url: u)
        p.isMuted = true
        let v = UIView(frame: tela.view.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = .black
        v.isUserInteractionEnabled = true
        let principal = AVPlayerLayer(player: p)
        principal.videoGravity = .resizeAspectFill
        principal.frame = v.bounds
        v.layer.addSublayer(principal)

        let alto = max(tela.view.safeAreaInsets.top, 20) + 4
        let faixa = UIView(frame: CGRect(x: 0, y: 0, width: v.bounds.width, height: alto))
        faixa.clipsToBounds = true
        faixa.isUserInteractionEnabled = false
        let esticada = AVPlayerLayer(player: p)
        esticada.videoGravity = .resizeAspectFill
        let linha = alto + 3
        esticada.anchorPoint = CGPoint(x: 0.5, y: linha / v.bounds.height)
        esticada.frame = v.bounds
        esticada.transform = CATransform3DMakeScale(1, 60, 1)
        faixa.layer.addSublayer(esticada)
        v.addSubview(faixa)

        tela.view.addSubview(v)
        capa = v
        player = p
        var respondeu = false
        let terminar: () -> Void = { [weak self] in
            guard let self = self, !respondeu else { return }
            respondeu = true
            resposta(true, nil)
            // a página já está na tela azul por baixo: tira o vídeo de uma vez (corte seco)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.capa?.removeFromSuperview()
                self.capa = nil
                self.player?.pause()
                self.player = nil
                if let f = self.fimVideo { NotificationCenter.default.removeObserver(f) }
                self.fimVideo = nil
            }
        }
        fimVideo = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                          object: p.currentItem, queue: .main) { _ in terminar() }
        // segurança: se o vídeo não tocar, não fica preso
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { terminar() }
        p.play()
    }

    // MARK: arquivos guardados (ltarq://f/nome)
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let nome = url.lastPathComponent
        let tarefa = urlSchemeTask
        DispatchQueue.global(qos: .userInitiated).async {
            let d = try? Data(contentsOf: self.arq(nome))
            DispatchQueue.main.async {
                if self.parados.remove(ObjectIdentifier(tarefa)) != nil { return }
                let tipo = nome.hasSuffix(".png") ? "image/png" : "image/jpeg"
                guard let d = d, let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                           headerFields: ["Content-Type": tipo,
                                                                          "Content-Length": "\(d.count)",
                                                                          "Cache-Control": "no-store",
                                                                          "Access-Control-Allow-Origin": "*"]) else {
                    tarefa.didFailWithError(NSError(domain: "loterias", code: 404))
                    return
                }
                tarefa.didReceive(resp)
                tarefa.didReceive(d)
                tarefa.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        parados.insert(ObjectIdentifier(urlSchemeTask))
    }
}
