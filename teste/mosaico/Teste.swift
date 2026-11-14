import UIKit
import WebKit

@main
final class AD: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let g = GaleriaNativa()
    var passos: [() -> Void] = []
    func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds); window = w
        let vc = UIViewController(); w.rootViewController = vc; w.makeKeyAndVisible()
        let web = WKWebView(frame: vc.view.bounds); vc.view.addSubview(web)
        let dir = FileManager.default.temporaryDirectory
        for k in 0..<20 {
            let im = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { c in
                UIColor(hue: CGFloat(k) / 20, saturation: 0.8, brightness: 0.9, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            }
            try? im.jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent("f\(k).jpg"))
        }
        try? UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { c in UIColor.gray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 400)) }
            .jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent("m.jpg"))
        g.urlMini = { _ in dir.appendingPathComponent("nada.jpg") }
        g.urlArq = { n in dir.appendingPathComponent(n) }
        g.evento = { print("EVENTO", $0) }
        g.instalar(em: web)
        let n = 600, cols = 60
        let seq = (0..<n).map { "arq:f\($0 % 20).jpg" }
        let mos: [String: Any] = ["ids": seq, "tinta": [Int](repeating: 120, count: n * 3), "cols": cols, "primeira": 0, "linhas": n / cols,
                                  "ultima": n / cols - 1, "ini": 0, "img": "m.jpg", "v": "1"]
        let cfg: [String: Any] = ["reforco": 0.4, "cor": "cor", "escuro": true, "n0": 3, "st": 47, "sb": 34, "zonas": [[0, 0, 390, 40]], "selecao": false, "sel": [], "ativa": true]
        let nada: (Any?, String?) -> Void = { _, e in if let e = e { print("ERRO", e) } }
        passos.append { print("PASSO ligar"); _ = self.g.recado("galeria", ["on": true, "ativa": true], nada) }
        passos.append { print("PASSO dados"); _ = self.g.recado("galeriaDados", ["seq": seq, "mos": mos, "cfg": cfg, "zerar": true], nada) }
        let p = CGPoint(x: 200, y: 500)
        func pinca(_ nome: String, de: CGFloat, ate: CGFloat, n: Int, soltar: Bool = true) {
            passos.append { print("PASSO", nome); self.g.pinca(0, p, de) }
            for k in 1...n { let e = de * pow(ate / de, CGFloat(k) / CGFloat(n)); passos.append { self.g.pinca(1, CGPoint(x: p.x, y: p.y + CGFloat(k % 5)), e) } }
            if soltar { passos.append { self.g.pinca(2, p, ate) } }
            for _ in 0..<30 { passos.append {} }
        }
        pinca("afastar ate o rosto", de: 1, ate: 0.04, n: 120)
        pinca("aproximar de volta", de: 1, ate: 30, n: 120)
        pinca("meio caminho e solta", de: 1, ate: 0.75, n: 20)
        pinca("meio caminho e volta", de: 1, ate: 0.5, n: 15)
        pinca("vai e volta", de: 0.5, ate: 1.6, n: 20)
        pinca("rapido", de: 1, ate: 0.02, n: 6)
        pinca("rapido volta", de: 1, ate: 60, n: 6)
        passos.append { print("PASSO rolar"); _ = self.g.recado("galeriaVer", ["i": 10], nada); _ = self.g.recado("galeriaRect", ["i": 590], { r, _ in print("RECT", r ?? "nil") }) }
        passos.append { _ = self.g.recado("galeriaDados", ["seq": Array(seq.prefix(300)), "mos": NSNull(), "cfg": cfg, "zerar": false], nada) }
        pinca("sem mosaico", de: 1, ate: 0.05, n: 40)
        passos.append { _ = self.g.recado("galeriaNivel", ["n": 13], nada) }
        passos.append { print("TUDO OK"); exit(0) }
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { t in
            if self.passos.isEmpty { t.invalidate(); return }
            self.passos.removeFirst()()
        }
        return true
    }
}
