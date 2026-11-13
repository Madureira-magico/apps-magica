import UIKit
import WebKit
import CoreBluetooth

/// Faz o Bluetooth pelo próprio iPhone para a página (ponte-bluetooth.js).
/// Só liga o Bluetooth quando a página pede pela primeira vez.
final class PonteBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var webView: WKWebView?
    weak var tela: UIViewController?

    private var central: CBCentralManager?
    private var aoLigar: [() -> Void] = []
    private var aparelhos: [UUID: CBPeripheral] = [:]
    private var conectando: [UUID: Int] = [:]
    private var faltaDescobrir: [UUID: Int] = [:]
    private var escrevendo: [String: [Int]] = [:]
    private var avisando: [String: [Int]] = [:]

    // procura (para escolher o aparelho)
    private var procura: (req: Int, filtros: [[String: Any]], todos: Bool)?
    private var achados: [(p: CBPeripheral, nome: String)] = []

    private let chaveConhecidos = "ponte_ble_conhecidos"

    // MARK: recados da página
    func receber(_ corpo: Any) {
        guard let m = corpo as? [String: Any], let cmd = m["cmd"] as? String else { return }
        let req = (m["req"] as? NSNumber)?.intValue ?? 0
        quandoLigado(req) { [weak self] in self?.fazer(cmd, m, req) }
    }

    private func quandoLigado(_ req: Int, _ f: @escaping () -> Void) {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
        guard let c = central else { return }
        switch c.state {
        case .poweredOn: f()
        case .unauthorized: responder(req, erro: "Bluetooth não autorizado para este app (Ajustes > Privacidade > Bluetooth)")
        case .unsupported: responder(req, erro: "Este iPhone não tem Bluetooth")
        case .poweredOff: aoLigar.append(f)   // espera o usuário ligar
        default: aoLigar.append(f)
        }
    }

    private func fazer(_ cmd: String, _ m: [String: Any], _ req: Int) {
        let id = (m["id"] as? String).flatMap(UUID.init(uuidString:))
        switch cmd {
        case "request":
            procurar(req, filtros: m["filters"] as? [[String: Any]] ?? [], todos: (m["all"] as? Bool) ?? false)
        case "known":
            responder(req, valor: conhecidos())
        case "connect":
            guard let id = id, let p = aparelho(id) else { return responder(req, erro: "aparelho não encontrado") }
            if p.state == .connected, p.services != nil, (faltaDescobrir[id] ?? 0) == 0 {
                return responder(req, valor: true)
            }
            if let antigo = conectando[id] { responder(antigo, erro: "nova tentativa") }
            conectando[id] = req
            if p.state != .connecting { central?.connect(p, options: nil) }
        case "disconnect":
            if let id = id, let p = aparelho(id) { central?.cancelPeripheralConnection(p) }
            responder(req, valor: true)
        case "svc":
            guard let id = id, let p = aparelhos[id], p.state == .connected else { return responder(req, erro: "não conectado") }
            let alvo = (m["svc"] as? String ?? "").lowercased()
            if p.services?.contains(where: { uuidTexto($0.uuid) == alvo }) == true { responder(req, valor: true) }
            else { responder(req, erro: "serviço não encontrado") }
        case "chr":
            if caracteristica(m) != nil { responder(req, valor: true) } else { responder(req, erro: "característica não encontrada") }
        case "write":
            guard let id = id, let p = aparelhos[id], let ch = caracteristica(m),
                  let b64 = m["b64"] as? String, let dados = Data(base64Encoded: b64) else {
                return responder(req, erro: "não conectado")
            }
            let comResposta = (m["resp"] as? Bool) ?? false
            if comResposta && ch.properties.contains(.write) {
                escrevendo[chave(id, ch), default: []].append(req)
                p.writeValue(dados, for: ch, type: .withResponse)
            } else {
                p.writeValue(dados, for: ch, type: ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
                responder(req, valor: true)
            }
        case "notify":
            guard let id = id, let p = aparelhos[id], let ch = caracteristica(m) else { return responder(req, erro: "não conectado") }
            let ligar = (m["on"] as? Bool) ?? true
            if ch.isNotifying == ligar { return responder(req, valor: true) }
            avisando[chave(id, ch), default: []].append(req)
            p.setNotifyValue(ligar, for: ch)
        default:
            responder(req, erro: "comando desconhecido")
        }
    }

    // MARK: escolher aparelho
    private func procurar(_ req: Int, filtros: [[String: Any]], todos: Bool) {
        if let p = procura { responder(p.req, erro: "cancelado") }
        procura = (req, filtros, todos)
        achados = []
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.mostrarLista(req) }
    }

    private func passa(_ nome: String, _ servicos: [String]) -> Bool {
        guard let p = procura else { return false }
        if p.todos || p.filtros.isEmpty { return true }
        for f in p.filtros {
            var ok = true
            if let pre = f["namePrefix"] as? String, !pre.isEmpty, !nome.uppercased().hasPrefix(pre.uppercased()) { ok = false }
            if let n = f["name"] as? String, !n.isEmpty, nome != n { ok = false }
            if let s = f["services"] as? [String], !s.isEmpty, !s.allSatisfy({ servicos.contains($0.lowercased()) }) { ok = false }
            if ok { return true }
        }
        return false
    }

    private func mostrarLista(_ req: Int) {
        guard let p = procura, p.req == req else { return }
        central?.stopScan()
        let lista = achados
        if lista.isEmpty { procura = nil; return responder(req, erro: "Nenhum aparelho encontrado") }
        let alerta = UIAlertController(title: "Escolha o aparelho", message: nil, preferredStyle: .actionSheet)
        for a in lista {
            alerta.addAction(UIAlertAction(title: a.nome, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.procura = nil
                self.aparelhos[a.p.identifier] = a.p
                self.lembrar(a.p.identifier, a.nome)
                self.responder(req, valor: ["id": a.p.identifier.uuidString, "name": a.nome])
            })
        }
        alerta.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { [weak self] _ in
            self?.procura = nil
            self?.responder(req, erro: "cancelado")
        })
        if let pop = alerta.popoverPresentationController, let v = tela?.view {
            pop.sourceView = v; pop.sourceRect = CGRect(x: v.bounds.midX, y: v.bounds.maxY - 40, width: 1, height: 1)
        }
        tela?.present(alerta, animated: true)
    }

    // MARK: aparelhos conhecidos (para reconectar sozinho)
    private func conhecidos() -> [[String: String]] {
        (UserDefaults.standard.array(forKey: chaveConhecidos) as? [[String: String]]) ?? []
    }
    private func lembrar(_ id: UUID, _ nome: String) {
        var l = conhecidos().filter { $0["id"] != id.uuidString }
        l.insert(["id": id.uuidString, "name": nome], at: 0)
        UserDefaults.standard.set(Array(l.prefix(6)), forKey: chaveConhecidos)
    }
    private func aparelho(_ id: UUID) -> CBPeripheral? {
        if let p = aparelhos[id] { return p }
        if let p = central?.retrievePeripherals(withIdentifiers: [id]).first {
            p.delegate = self; aparelhos[id] = p; return p
        }
        return nil
    }

    // MARK: CoreBluetooth
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            let l = aoLigar; aoLigar = []
            l.forEach { $0() }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard procura != nil else { return }
        let nome = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let servicos = ((ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(uuidTexto)
        if nome.isEmpty && servicos.isEmpty { return }
        guard passa(nome, servicos), !achados.contains(where: { $0.p.identifier == p.identifier }) else { return }
        p.delegate = self
        achados.append((p, nome.isEmpty ? "Aparelho sem nome" : nome))
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if let req = conectando.removeValue(forKey: p.identifier) { responder(req, erro: "não conectou") }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if let req = conectando.removeValue(forKey: p.identifier) { responder(req, erro: "desconectou") }
        faltaDescobrir[p.identifier] = nil
        rodar("window.__ble&&__ble.desconectou(\(js(p.identifier.uuidString)))")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let s = p.services ?? []
        if s.isEmpty { return terminouDescoberta(p) }
        faltaDescobrir[p.identifier] = s.count
        s.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let falta = (faltaDescobrir[p.identifier] ?? 1) - 1
        faltaDescobrir[p.identifier] = falta
        if falta <= 0 { terminouDescoberta(p) }
    }

    private func terminouDescoberta(_ p: CBPeripheral) {
        faltaDescobrir[p.identifier] = 0
        if let req = conectando.removeValue(forKey: p.identifier) { responder(req, valor: true) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        let k = chave(p.identifier, ch)
        guard var l = escrevendo[k], !l.isEmpty else { return }
        let req = l.removeFirst(); escrevendo[k] = l
        if let e = error { responder(req, erro: e.localizedDescription) } else { responder(req, valor: true) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let k = chave(p.identifier, ch)
        let l = avisando[k] ?? []; avisando[k] = []
        for req in l {
            if let e = error { responder(req, erro: e.localizedDescription) } else { responder(req, valor: true) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let v = ch.value else { return }
        rodar("window.__ble&&__ble.valor(\(js(p.identifier.uuidString)),\(js(uuidTexto(ch.uuid))),\(js(v.base64EncodedString())))")
    }

    // MARK: ajudantes
    private func caracteristica(_ m: [String: Any]) -> CBCharacteristic? {
        guard let id = (m["id"] as? String).flatMap(UUID.init(uuidString:)), let p = aparelhos[id] else { return nil }
        let s = (m["svc"] as? String ?? "").lowercased(), c = (m["chr"] as? String ?? "").lowercased()
        return p.services?.first(where: { uuidTexto($0.uuid) == s })?
            .characteristics?.first(where: { uuidTexto($0.uuid) == c })
    }
    private func chave(_ id: UUID, _ ch: CBCharacteristic) -> String { id.uuidString + "|" + uuidTexto(ch.uuid) }
    private func uuidTexto(_ u: CBUUID) -> String {
        let s = u.uuidString.lowercased()
        return s.count == 4 ? "0000\(s)-0000-1000-8000-00805f9b34fb" : s
    }
    private func js(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [v]), var s = String(data: d, encoding: .utf8) else { return "null" }
        s.removeFirst(); s.removeLast(); return s
    }
    private func responder(_ req: Int, valor: Any) { rodar("window.__ble&&__ble.r(\(req),null,\(js(valor)))") }
    private func responder(_ req: Int, erro: String) { rodar("window.__ble&&__ble.r(\(req),\(js(erro)),null)") }
    private func rodar(_ codigo: String) {
        DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(codigo, completionHandler: nil) }
    }
}
