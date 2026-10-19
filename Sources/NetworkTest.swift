import Foundation
import Combine

final class NetworkManager: ObservableObject {
    @Published var status: String = "inattivo"
    @Published var lastMessage: String = "-"

    private var task: URLSessionWebSocketTask?

    func connect(to ip: String, port: Int = 8765) {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            status = "IP vuota"
            return
        }
        guard let url = URL(string: "ws://\(trimmed):\(port)") else {
            status = "URL non valido: \(trimmed)"
            return
        }

        task?.cancel()
        let newTask = URLSession.shared.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        status = "connessione a \(trimmed):\(port)…"

        send(["type": "handshake", "device": "iPhone"])
        receive()
    }

    func disconnect() {
        task?.cancel()
        task = nil
        status = "disconnesso"
    }

    private func send(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            status = "JSON non valido"
            return
        }
        task?.send(.string(str)) { [weak self] err in
            if let err = err {
                self?.status = "invio fallito: \(err.localizedDescription)"
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.status = "ricezione fallita: \(err.localizedDescription)"
            case .success(let msg):
                var text = "<sconosciuto>"
                switch msg {
                case .string(let s):
                    text = s
                case .data(let d):
                    text = String(data: d, encoding: .utf8) ?? "<dati>"
                }
                self.lastMessage = text
                self.status = "comando ricevuto"

                // Mock: finge una misura della fotocamera dopo 0.5 s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.send([
                        "type": "reading",
                        "patch_id": "test_red_01",
                        "raw_data": [4095, 120, 95]
                    ])
                }
                self.receive()
            }
        }
    }
}