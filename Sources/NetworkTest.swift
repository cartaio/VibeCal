import Foundation
import Combine
import UIKit

final class NetworkManager: ObservableObject {
    @Published var status: String = "inattivo"
    @Published var lastMessage: String = "-"
    @Published var currentPatch: String = "-"

    // Wired by ContentView to the camera
    var sampleProvider: (() -> [Double]?)?
    var prepareHandler: (() -> Void)?
    var finishHandler: (() -> Void)?
    var blackoutHandler: ((Bool) -> Void)?

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
        blackoutHandler?(false)
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
                self.blackoutHandler?(false)
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
    private func runCountdown(_ remaining: Int) {
        guard task != nil else { return }   // aborted via Stop
        if remaining <= 0 {
            status = "attendo prepare…"
            return
        }
        status = "posiziona il telefono… \(remaining)"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runCountdown(remaining - 1)
        }
    }
    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else {
            status = "msg non riconosciuto"; return
        }
        let settleMs = (obj["settle_ms"] as? Double) ?? 1000.0

        switch command {
        case "countdown":
            let seconds = Int(obj["seconds"] as? Double ?? 15)
            runCountdown(seconds)    
        case "prepare":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            status = "preparazione: blocco AE/WB…"
            blackoutHandler?(true)
            prepareHandler?()
            DispatchQueue.main.asyncAfter(deadline: .now() + settleMs / 1000.0) { [weak self] in
                self?.send(["type": "ready"])
                self?.status = "pronto, in attesa delle patch"
            }
        case "display_patch":
            let patchId = obj["patch_id"] as? String ?? "?"
            currentPatch = patchId
            status = "misuro \(patchId)…"
            DispatchQueue.main.asyncAfter(deadline: .now() + settleMs / 1000.0) { [weak self] in
                self?.startSampling(patchId: patchId, frames: 8, intervalMs: 80)
            }
        case "finish":
            UINotificationFeedbackGenerator().notificationOccurred(.success)        
            blackoutHandler?(false)
            finishHandler?()
            status = "sessione completata ✅"
            currentPatch = "-"
        default:
            status = "comando ignoto: \(command)"
        }
    }

    private func startSampling(patchId: String, frames: Int, intervalMs: Double) {
        var samples: [[Double]] = []
        func step() {
            if let s = self.sampleProvider?(), s.count >= 3 { samples.append(s) }
            if samples.count < frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + intervalMs / 1000.0, execute: step)
            } else {
                let n = Double(samples.count)
                var sum = [0.0, 0.0, 0.0]
                for s in samples { sum[0] += s[0]; sum[1] += s[1]; sum[2] += s[2] }
                let avg = sum.map { $0 / n }
                let sigma = samples.last?.count ?? 0 > 3 ? samples[frames - 1][3] : -1.0
                self.send(["type": "reading", "patch_id": patchId,
                           "raw_data": avg, "sigma": sigma, "frames": samples.count])
                self.status = "misurato \(patchId)"
            }
        }
        step()
    }
}