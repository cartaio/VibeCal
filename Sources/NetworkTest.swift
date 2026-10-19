import Foundation
import Combine

final class NetworkManager: ObservableObject {
    @Published var status: String = "inattivo"
    @Published var lastMessage: String = "-"
    @Published var currentPatch: String = "-"

    private var task: URLSessionWebSocketTask?

    func connect(to ip: String, port: Int = 8765) {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { status = "IP vuota"; return }
        guard let url = URL(string: "ws://\(trimmed):\(port)") else {
            status = "URL non valido: \(trimmed)"; return
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
        currentPatch = "-"
    }

    private func send(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            status = "JSON non valido"; return
        }
        task?.send(.string(str)) { [weak self] err in
            if let err = err { self?.status = "invio fallito: \(err.localizedDescription)" }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.status = "disconnesso: \(err.localizedDescription)"
                self.currentPatch = "-"
            case .success(let msg):
                var text = ""
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                }
                self.lastMessage = text
                self.handle(text: text)
                self.receive()
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else {
            status = "msg non riconosciuto"
            return
        }

        switch command {
        case "display_patch":
            let patchId = obj["patch_id"] as? String ?? "?"
            let settleMs = (obj["settle_ms"] as? Double) ?? 1000.0
            currentPatch = patchId
            status = "misuro \(patchId)…"
            DispatchQueue.main.asyncAfter(deadline: .now() + settleMs / 1000.0) { [weak self] in
                self?.sendMockReading(patchId: patchId)
            }
        case "session_end":
            status = "sessione completata ✅"
            currentPatch = "-"
        default:
            status = "comando ignoto: \(command)"
        }
    }

    private func sendMockReading(patchId: String) {
        // MOCK — next step: replace with real CameraModel ROI average
        send(["type": "reading", "patch_id": patchId, "raw_data": [4095, 120, 95]])
    }
}