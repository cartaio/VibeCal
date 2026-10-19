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
        receive(on: newTask)
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
            guard let err = err else { return }
            DispatchQueue.main.async {
                self?.status = "invio fallito: \(err.localizedDescription)"
            }
        }
    }

    // Le callback di URLSessionWebSocketTask arrivano su un thread in background.
    // Tutto il resto (stato SwiftUI, luminosità, feedback aptico) deve girare sul main thread.
    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Ignora i messaggi di un socket vecchio (es. dopo Stop o un secondo Connetti)
                guard self.task === socket else { return }
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
                    @unknown default: break
                    }
                    self.lastMessage = text
                    self.handle(text: text)
                    self.receive(on: socket)
                }
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
        var attempts = 0
        func step() {
            attempts += 1
            if let s = self.sampleProvider?(), s.count >= 3 { samples.append(s) }
            if samples.count < frames && attempts < frames * 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + intervalMs / 1000.0, execute: step)
            } else {
                var avg = [0.0, 0.0, 0.0]
                var sigma = -1.0
                if !samples.isEmpty {
                    let n = Double(samples.count)
                    var sum = [0.0, 0.0, 0.0]
                    for s in samples { sum[0] += s[0]; sum[1] += s[1]; sum[2] += s[2] }
                    avg = sum.map { $0 / n }
                    if let last = samples.last, last.count > 3 { sigma = last[3] }
                }
                self.send(["type": "reading", "patch_id": patchId,
                           "raw_data": avg, "sigma": sigma, "frames": samples.count])
                self.status = "misurato \(patchId)"
            }
        }
        step()
    }
}