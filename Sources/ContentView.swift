import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @StateObject private var net = NetworkManager()
    @State private var pcIP = "192.168.1.50"
    @State private var roi = 20.0
    @State private var iso: Float = 100
    @State private var shutterIndex = 2
    @State private var delay = 5
    @State private var label = "Bianco"

    private let shutters: [Double] = [1.0 / 1000, 1.0 / 250, 1.0 / 60, 1.0 / 30, 1.0 / 15]
    private let shutterNames = ["1/1000", "1/250", "1/60", "1/30", "1/15"]
    private static let order = ["Nero", "Grigio 10%", "Grigio 20%", "Grigio 30%", "Grigio 40%",
                                "Grigio 50%", "Grigio 60%", "Grigio 70%", "Grigio 80%", "Grigio 90%",
                                "Bianco", "Rosso", "Verde", "Blu", "Ciano", "Magenta", "Giallo"]

    private static func next(after text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        for i in 0..<(order.count - 1) where order[i].lowercased() == t {
            return order[i + 1]
        }
        return ""
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("VibeCal: test").font(.title2.bold())

                    GroupBox("Capacità della fotocamera frontale") {
                        Text(cam.capabilities)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Stato attuale") {
                        Text(cam.current.isEmpty ? "-" : cam.current)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Controlli") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Blocca tutto") { cam.lockAllAtCurrent() }
                                Button("Sblocca") { cam.unlockAll() }
                                Button("WB 1,1,1") { cam.setNeutralGains() }
                            }
                            .buttonStyle(.bordered)

                            Text("ISO \(Int(iso))")
                            Slider(value: Binding(get: { Double(iso) },
                                                  set: { iso = Float($0) }),
                                   in: Double(cam.minISO)...Double(cam.maxISO))

                            Picker("Otturatore", selection: $shutterIndex) {
                                ForEach(0..<shutters.count, id: \.self) { i in
                                    Text(shutterNames[i]).tag(i)
                                }
                            }
                            .pickerStyle(.segmented)

                            Button("Applica esposizione fissa") {
                                cam.setCustomExposure(iso: iso, shutter: shutters[shutterIndex])
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    GroupBox("Rete (mock)") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("IP del PC", text: $pcIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                            HStack {
                                Button("Connetti") { net.connect(to: pcIP) }
                                    .buttonStyle(.borderedProminent)
                                Button("Stop") { net.disconnect() }
                                    .buttonStyle(.bordered)
                            }
                            Text("Stato: \(net.status)")
                                .font(.system(.footnote, design: .monospaced))
                            Text("Ultimo: \(net.lastMessage)")
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(3)
                        }
                    }
                    GroupBox("Lettura live") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Rectangle()
                                    .fill(Color(red: cam.liveR / 255, green: cam.liveG / 255, blue: cam.liveB / 255))
                                    .frame(width: 56, height: 56)
                                    .cornerRadius(8)
                                VStack(alignment: .leading) {
                                    Text(String(format: "R %.1f  G %.1f  B %.1f", cam.liveR, cam.liveG, cam.liveB))
                                        .font(.system(.body, design: .monospaced))
                                    Text(String(format: "σ %.2f", cam.liveSigma))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Text("Area di misura: \(Int(roi))%")
                            Slider(value: $roi, in: 5...100, step: 5)
                                .onChange(of: roi) { _, newValue in cam.setROI(percent: newValue) }
                        }
                    }

                    GroupBox("Misura con ritardo") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Etichetta", text: $label)
                                .textFieldStyle(.roundedBorder)
                            Picker("Ritardo", selection: $delay) {
                                Text("3 s").tag(3)
                                Text("5 s").tag(5)
                                Text("8 s").tag(8)
                                Text("12 s").tag(12)
                            }
                            .pickerStyle(.segmented)
                            Button("Registra con ritardo") {
                                let current = label
                                cam.measure(label: current.isEmpty ? "misura \(cam.readings.count + 1)" : current,
                                            delay: delay)
                                label = Self.next(after: current)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(cam.busy)
                            Text("Lo schermo diventa nero. Senti una vibrazione al secondo, una forte quando parte la misura (1 s) e una di conferma alla fine.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Misure registrate") {
                        VStack(alignment: .leading, spacing: 6) {
                            if cam.readings.isEmpty {
                                Text("Nessuna misura").foregroundStyle(.secondary)
                            }
                            ForEach(cam.readings) { r in
                                HStack {
                                    Text(r.label)
                                    Spacer()
                                    Text(String(format: "%.1f %.1f %.1f  σ%.2f", r.r, r.g, r.b, r.sigma))
                                        .font(.system(.footnote, design: .monospaced))
                                }
                            }
                            HStack {
                                Button("Copia CSV") { UIPasteboard.general.string = cam.csv() }
                                    .disabled(cam.readings.isEmpty)
                                Button("Svuota") { cam.readings = [] }
                                    .disabled(cam.readings.isEmpty)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !cam.status.isEmpty {
                        Text(cam.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }

            if cam.blackout {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
            }
        }
        .statusBarHidden(cam.blackout)
        .onAppear { cam.start() }
    }
}
