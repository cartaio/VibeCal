import Foundation
import Combine
import UIKit

/// Piano di misura di una singola patch (di solito arriva dal server dentro "display_patch").
struct PatchPlan {
    var exposures: [ExposureSpec]
    var frames: Int
    var discard: Int
    /// Se impostato, la scala di esposizioni si ferma dopo il primo scatto in cui
    /// il canale più alto raggiunge questo valore (le esposizioni più lunghe sarebbero saturate).
    var stopAbove: Double?
}

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
    private var exposures: [ExposureSpec] = [] // piano di default (comando "prepare"), usato se display_patch non ne porta uno
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
            parseDefaults(obj)
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
            let plan = makePlan(obj)
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + settleMs / 1000.0) { [weak self] in
                self?.measurePatch(patchId: patchId, plan: plan, gen: gen)
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

    // MARK: - Piano di misura

    private func exposureList(_ any: Any?) -> [ExposureSpec] {
        var out: [ExposureSpec] = []
        guard let list = any as? [[String: Any]] else { return out }
        for (i, e) in list.enumerated() {
            guard let iso = number(e["iso"]), let shutter = number(e["shutter_s"]), shutter > 0 else { continue }
            out.append(ExposureSpec(id: e["id"] as? String ?? "e\(i)", iso: Float(iso), shutter: shutter))
        }
        return out
    }

    /// Valori di default (da "prepare"): usati solo se una patch non porta un piano proprio.
    private func parseDefaults(_ obj: [String: Any]) {
        exposures = exposureList(obj["exposures"])
        if let n = number(obj["burst_frames"]) { burstFrames = max(1, Int(n)) }
        if let n = number(obj["discard_frames"]) { discardFrames = max(0, Int(n)) }
    }

    private func makePlan(_ obj: [String: Any]) -> PatchPlan {
        let own = exposureList(obj["exposures"])
        return PatchPlan(exposures: own.isEmpty ? exposures : own,
                         frames: number(obj["burst_frames"]).map { max(1, Int($0)) } ?? burstFrames,
                         discard: number(obj["discard_frames"]).map { max(0, Int($0)) } ?? discardFrames,
                         stopAbove: number(obj["stop_above"]))
    }

    private func measurePatch(patchId: String, plan: PatchPlan, gen: Int) {
        guard gen == generation, task != nil else { return }   // Stop/disconnessione: abbandona
        if burstProvider != nil && !plan.exposures.isEmpty {
            runShots(patchId: patchId, plan: plan, index: 0, shots: [], startedAt: Date(), gen: gen)
        } else {
            startSampling(patchId: patchId, frames: 8, intervalMs: 80)   // vecchio comportamento
        }
    }

    /// Una raffica per esposizione, in sequenza; alla fine un solo pacchetto "reading".
    private func runShots(patchId: String, plan: PatchPlan, index: Int, shots: [[String: Any]],
                          startedAt: Date, gen: Int) {
        guard gen == generation, task != nil else { return }
        guard index < plan.exposures.count, let burst = burstProvider else {
            sendReading(patchId: patchId, plan: plan, shots: shots, startedAt: startedAt)
            return
        }
        let spec = plan.exposures[index]
        status = "misuro \(patchId) [\(spec.id)] \(index + 1)/\(plan.exposures.count)…"
        burst(spec, plan.discard, plan.frames) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var acc = shots
                acc.append(result.json(id: spec.id))
                // Scala crescente: se il canale più alto è già al limite, le esposizioni più lunghe sono inutili
                var next = index + 1
                if let limit = plan.stopAbove, (result.mean.max() ?? 0) >= limit {
                    next = plan.exposures.count
                }
                self.runShots(patchId: patchId, plan: plan, index: next, shots: acc,
                              startedAt: startedAt, gen: gen)
            }
        }
    }

    private func sendReading(patchId: String, plan: PatchPlan, shots: [[String: Any]], startedAt: Date) {
        var packet: [String: Any] = [
            "type": "reading",
            "patch_id": patchId,
            "shots": shots,
            "frames_per_shot": plan.frames,
            "discard_frames": plan.discard,
            "planned_shots": plan.exposures.count,
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
        status = "misurato \(patchId) (\(shots.count)/\(plan.exposures.count) esposizioni)"
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
