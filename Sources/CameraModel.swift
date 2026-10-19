import AVFoundation
import SwiftUI
import UIKit

struct Reading: Identifiable {
    let id = UUID()
    let label: String
    let r: Double
    let g: Double
    let b: Double
    let sigma: Double
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Stato mostrato nella UI (sempre aggiornato sul main thread)
    @Published var capabilities = "Fotocamera non avviata"
    @Published var current = ""
    @Published var status = ""
    @Published var minISO: Float = 25
    @Published var maxISO: Float = 800
    @Published var liveR = 0.0
    @Published var liveG = 0.0
    @Published var liveB = 0.0
    @Published var liveSigma = 0.0
    @Published var blackout = false
    @Published var busy = false
    @Published var readings: [Reading] = []

    // MARK: - Stato interno (toccato solo dalla coda `queue`, se non indicato)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "vibecal.camera")
    private var device: AVCaptureDevice?
    private var roiFraction = 0.2
    private var history: [(Double, Double, Double)] = []
    private var collecting: [(Double, Double, Double)]?
    private var frameCount = 0
    private var savedBrightness: CGFloat = 0.5   // solo main thread

    // MARK: - Avvio
    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.queue.async { self.configure() }
                } else {
                    self.setStatus("Permesso fotocamera negato")
                }
            }
        default:
            setStatus("Permesso fotocamera negato: abilitalo in Impostazioni")
        }
    }

    private func configure() {
        guard session.inputs.isEmpty else { return }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            setStatus("Fotocamera frontale non trovata")
            return
        }
        device = dev

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration()
            setStatus("Impossibile aprire la fotocamera")
            return
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Niente HDR automatico, se la fotocamera lo permette
        if dev.activeFormat.isVideoHDRSupported {
            do {
                try dev.lockForConfiguration()
                dev.automaticallyAdjustsVideoHDREnabled = false
                dev.isVideoHDREnabled = false
                dev.unlockForConfiguration()
            } catch {}
        }

        session.startRunning()
        reportCapabilities(dev)
        refreshInfo()
    }

    private func reportCapabilities(_ d: AVCaptureDevice) {
        let f = d.activeFormat
        let yn: (Bool) -> String = { $0 ? "sì" : "no" }
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        var lines = [String]()
        lines.append("Camera: \(d.localizedName)")
        lines.append("Formato: \(dims.width)x\(dims.height)")
        lines.append("Esposizione manuale (custom): \(yn(d.isExposureModeSupported(.custom)))")
        lines.append("Esposizione bloccabile: \(yn(d.isExposureModeSupported(.locked)))")
        lines.append("ISO: \(Int(f.minISO)) - \(Int(f.maxISO))")
        lines.append("Durata: \(fmt(f.minExposureDuration.seconds, 5)) - \(fmt(f.maxExposureDuration.seconds, 5)) s")
        lines.append("Bilanciamento bloccabile: \(yn(d.isWhiteBalanceModeSupported(.locked)))")
        lines.append("Gain bianco personalizzati: \(yn(d.isLockingWhiteBalanceWithCustomDeviceGainsSupported))")
        lines.append("Gain bianco massimo: \(fmt(Double(d.maxWhiteBalanceGain), 2))")
        lines.append("Fuoco bloccabile: \(yn(d.isFocusModeSupported(.locked)))")
        lines.append("HDR video supportato: \(yn(f.isVideoHDRSupported))")
        let text = lines.joined(separator: "\n")
        let lo = f.minISO, hi = f.maxISO
        DispatchQueue.main.async {
            self.capabilities = text
            self.minISO = lo
            self.maxISO = hi
        }
    }

    private func refreshInfo() {
        queue.asyncAfter(deadline: .now() + 0.5) {
            guard let d = self.device else { return }
            let g = d.deviceWhiteBalanceGains
            let text = """
            Esposizione: \(Self.name(d.exposureMode)), ISO \(Int(d.iso)), \(self.fmt(d.exposureDuration.seconds, 5)) s
            Bilanciamento: \(Self.name(d.whiteBalanceMode)), gain R \(self.fmt(Double(g.redGain), 2)) G \(self.fmt(Double(g.greenGain), 2)) B \(self.fmt(Double(g.blueGain), 2))
            Fuoco: \(d.focusMode == .locked ? "bloccato" : "automatico")
            """
            DispatchQueue.main.async { self.current = text }
        }
    }

    private static func name(_ m: AVCaptureDevice.ExposureMode) -> String {
        switch m {
        case .locked: return "bloccata"
        case .autoExpose: return "automatica"
        case .continuousAutoExposure: return "automatica continua"
        case .custom: return "manuale"
        @unknown default: return "?"
        }
    }

    private static func name(_ m: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch m {
        case .locked: return "bloccato"
        case .autoWhiteBalance: return "automatico"
        case .continuousAutoWhiteBalance: return "automatico continuo"
        @unknown default: return "?"
        }
    }

    private func fmt(_ x: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", x)
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    // MARK: - Controlli della fotocamera
    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        queue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                body(d)
                d.unlockForConfiguration()
            } catch {
                self.setStatus("Errore di configurazione: \(error.localizedDescription)")
            }
            self.refreshInfo()
        }
    }

    func lockAllAtCurrent() {
        withDevice { d in
            if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
            if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
            if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        }
        setStatus("Bloccati esposizione, bilanciamento e fuoco ai valori attuali")
    }

    func unlockAll() {
        withDevice { d in
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
        setStatus("Controlli automatici riattivati")
    }

    func setNeutralGains() {
        withDevice { d in
            guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                self.setStatus("Gain del bianco personalizzati non supportati")
                return
            }
            let gains = AVCaptureDevice.WhiteBalanceGains(redGain: 1.0, greenGain: 1.0, blueGain: 1.0)
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            self.setStatus("Gain del bianco fissati a 1,1,1")
        }
    }

    /// Setup fisso per la calibrazione: ISO e otturatore manuali, gain del bianco 1/1/1, fuoco bloccato.
    /// Tutto in un'unica lockForConfiguration, indipendente dalla luminosità della scena
    /// (a differenza di lockAllAtCurrent, che congela ciò che l'auto-esposizione ha scelto).
    func applyFixedCalibration(iso: Float, shutter: Double) {
        withDevice { d in
            let f = d.activeFormat
            var report = [String]()

            if d.isFocusModeSupported(.locked) { d.focusMode = .locked }

            if d.isExposureModeSupported(.custom) {
                let i = min(max(iso, f.minISO), f.maxISO)
                let lo = f.minExposureDuration.seconds
                let hi = f.maxExposureDuration.seconds
                let t = CMTime(seconds: min(max(shutter, lo), hi), preferredTimescale: 1_000_000)
                d.setExposureModeCustom(duration: t, iso: i, completionHandler: nil)
                report.append("ISO \(Int(i)), \(self.fmt(t.seconds, 5)) s")
            } else if d.isExposureModeSupported(.locked) {
                d.exposureMode = .locked
                report.append("esposizione manuale non supportata: bloccata al valore attuale")
            }

            if d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let gains = AVCaptureDevice.WhiteBalanceGains(redGain: 1.0, greenGain: 1.0, blueGain: 1.0)
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                report.append("WB 1/1/1")
            } else if d.isWhiteBalanceModeSupported(.locked) {
                d.whiteBalanceMode = .locked
                report.append("gain personalizzati non supportati: WB bloccato al valore attuale")
            }

            self.setStatus("Calibrazione fissa: " + report.joined(separator: ", "))
        }
    }

    func setCustomExposure(iso: Float, shutter: Double) {
        withDevice { d in
            guard d.isExposureModeSupported(.custom) else {
                self.setStatus("Esposizione manuale non supportata")
                return
            }
            let f = d.activeFormat
            let i = min(max(iso, f.minISO), f.maxISO)
            let lo = f.minExposureDuration.seconds
            let hi = f.maxExposureDuration.seconds
            let t = CMTime(seconds: min(max(shutter, lo), hi), preferredTimescale: 1_000_000)
            d.setExposureModeCustom(duration: t, iso: i, completionHandler: nil)
            self.setStatus("Esposizione fissata: ISO \(Int(i)), \(self.fmt(t.seconds, 5)) s")
        }
    }

    func setROI(percent: Double) {
        queue.async { self.roiFraction = max(0.05, min(1.0, percent / 100.0)) }
    }

    // MARK: - Lettura dei frame
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let rw = max(1, Int(Double(w) * roiFraction))
        let rh = max(1, Int(Double(h) * roiFraction))
        let x0 = (w - rw) / 2
        let y0 = (h - rh) / 2
        let step = max(1, min(rw, rh) / 64)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sr = 0, sg = 0, sb = 0, n = 0
        var y = y0
        while y < y0 + rh {
            var x = x0
            while x < x0 + rw {
                let p = ptr + y * bpr + x * 4      // formato BGRA
                sb += Int(p[0])
                sg += Int(p[1])
                sr += Int(p[2])
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return }
        let sample = (Double(sr) / Double(n), Double(sg) / Double(n), Double(sb) / Double(n))

        history.append(sample)
        if history.count > 30 { history.removeFirst() }
        collecting?.append(sample)

        frameCount += 1
        if frameCount % 3 == 0 {
            let s = Self.stats(history)
            DispatchQueue.main.async {
                self.liveR = sample.0
                self.liveG = sample.1
                self.liveB = sample.2
                self.liveSigma = s.3
            }
        }
    }

    private static func stats(_ h: [(Double, Double, Double)]) -> (Double, Double, Double, Double) {
        guard !h.isEmpty else { return (0, 0, 0, 0) }
        let n = Double(h.count)
        let mr = h.reduce(0.0) { $0 + $1.0 } / n
        let mg = h.reduce(0.0) { $0 + $1.1 } / n
        let mb = h.reduce(0.0) { $0 + $1.2 } / n
        let v = h.reduce(0.0) { acc, s in
            acc + pow(s.0 - mr, 2) + pow(s.1 - mg, 2) + pow(s.2 - mb, 2)
        } / (n * 3.0)
        return (mr, mg, mb, v.squareRoot())
    }

    // MARK: - Misura con ritardo, schermo nero e vibrazione
    func measure(label: String, delay: Int) {
        DispatchQueue.main.async {
            guard !self.busy else { return }
            self.busy = true
            self.blackout = true
            self.savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
            self.tick(remaining: delay, label: label)
        }
    }

    private func tick(remaining: Int, label: String) {
        if remaining > 0 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.tick(remaining: remaining - 1, label: label)
            }
        } else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            queue.async { self.collecting = [] }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.finish(label: label)
            }
        }
    }

    private func finish(label: String) {
        queue.async {
            let data = self.collecting ?? []
            self.collecting = nil
            let s = Self.stats(data)
            DispatchQueue.main.async {
                if data.isEmpty {
                    self.status = "Nessun frame letto, riprova"
                } else {
                    self.readings.append(Reading(label: label, r: s.0, g: s.1, b: s.2, sigma: s.3))
                    self.status = "Registrato: \(label) (\(data.count) frame)"
                }
                UIScreen.main.brightness = self.savedBrightness
                self.blackout = false
                self.busy = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    func csv() -> String {
        let rows = readings.map { r in
            "\"\(r.label)\",\(fmt(r.r, 2)),\(fmt(r.g, 2)),\(fmt(r.b, 2)),\(fmt(r.sigma, 2))"
        }
        return (["etichetta,R,G,B,sigma"] + rows).joined(separator: "\n")
    }
}
