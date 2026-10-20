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
    /// Raffica a esposizione fissa: (esposizione, frame da scartare, frame da misurare, completion)
    var burstProvider: ((ExposureSpec, Int, Int, @escaping (BurstResult) -> Void) -> Void)?
    /// Info sul dispositivo/camera da mandare nell'handshake
    var infoProvider: (() -> [String: Any])?

    private var task: URLSessionWebSocketTask?
    private var generation = 0                 // si incrementa a ogni connect/disconnect: invalida le misure in corso
    private var exposures: [ExposureSpec] = [] // ricevute dal server nel comando "prepare"
    private var burstFrames = 8
    private var discardFrames = 3

    func connect(to ip: String, port: Int = 8765) {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { status = "IP vuota"; return }
        guard let url = URL(string: "ws://\(trimmed):\(port)") else {
            status = "URL non valido: \(trimmed)"; return
        }
        task?.cancel()
        generation += 1
        let newTask = URLSession.shared.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        status = "connessione a \(trimmed):\(port)…"
        var handshake: [String: Any] = ["type": "handshake", "device": "iPhone"]
        if let info = infoProvider?(), !info.isEmpty { handshake["info"] = info }
        send(handshake)
        receive(on: newTask)
    }

    func disconnect() {
        task?.cancel()
        task = nil
        generation += 1
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
                    self.generation += 1
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

    private func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else {
            status = "msg non riconosciuto"; return
        }
        let settleMs = number(obj["settle_ms"]) ?? 1000.0

        switch command {
        case "countdown":
            let seconds = Int(number(obj["seconds"]) ?? 15)
            runCountdown(seconds)
        case "prepare":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            status = "preparazione: esposizione fissa…"
            parseExposures(obj)
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
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + settleMs / 1000.0) { [weak self] in
                self?.measurePatch(patchId: patchId, gen: gen)
            }
        case "finish":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            generation += 1
            blackoutHandler?(false)
            finishHandler?()
            status = "sessione completata ✅"
            currentPatch = "-"
        default:
            status = "comando ignoto: \(command)"
        }
    }

    // MARK: - Esposizioni multiple

    private func parseExposures(_ obj: [String: Any]) {
        exposures = []
        if let list = obj["exposures"] as? [[String: Any]] {
            for (i, e) in list.enumerated() {
                guard let iso = number(e["iso"]), let shutter = number(e["shutter_s"]), shutter > 0 else { continue }
                exposures.append(ExposureSpec(id: e["id"] as? String ?? "e\(i)",
                                              iso: Float(iso), shutter: shutter))
            }
        }
        if let n = number(obj["burst_frames"]) { burstFrames = max(1, Int(n)) }
        if let n = number(obj["discard_frames"]) { discardFrames = max(0, Int(n)) }
    }

    private func measurePatch(patchId: String, gen: Int) {
        guard gen == generation, task != nil else { return }   // Stop/disconnessione: abbandona
        if burstProvider != nil && !exposures.isEmpty {
            runShots(patchId: patchId, index: 0, shots: [], startedAt: Date(), gen: gen)
        } else {
            startSampling(patchId: patchId, frames: 8, intervalMs: 80)   // vecchio comportamento
        }
    }

    /// Una raffica per esposizione, in sequenza; alla fine un solo pacchetto "reading".
    private func runShots(patchId: String, index: Int, shots: [[String: Any]],
                          startedAt: Date, gen: Int) {
        guard gen == generation, task != nil else { return }
        guard index < exposures.count, let burst = burstProvider else {
            sendReading(patchId: patchId, shots: shots, startedAt: startedAt)
            return
        }
        let spec = exposures[index]
        status = "misuro \(patchId) [\(spec.id)] \(index + 1)/\(exposures.count)…"
        burst(spec, discardFrames, burstFrames) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var acc = shots
                acc.append(result.json(id: spec.id))
                self.runShots(patchId: patchId, index: index + 1, shots: acc,
                              startedAt: startedAt, gen: gen)
            }
        }
    }

    private func sendReading(patchId: String, shots: [[String: Any]], startedAt: Date) {
        var packet: [String: Any] = [
            "type": "reading",
            "patch_id": patchId,
            "shots": shots,
            "frames_per_shot": burstFrames,
            "discard_frames": discardFrames,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "phone_time": ISO8601DateFormatter().string(from: Date()),
            "measure_ms": Date().timeIntervalSince(startedAt) * 1000.0
        ]
        // Compatibilità col vecchio formato: valori della prima esposizione
        if let first = shots.first, let mean = first["mean"],
           let sigma = first["sigma"], let frames = first["frames"] {
            packet["raw_data"] = mean
            packet["sigma"] = sigma
            packet["frames"] = frames
        }
        send(packet)
        status = "misurato \(patchId) (\(shots.count) esposizioni)"
    }

    // MARK: - Vecchio campionamento (usato solo se il server non manda "exposures")

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
