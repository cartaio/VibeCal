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

/// Esposizione fissa richiesta dal server (ISO + tempo di otturazione).
struct ExposureSpec {
    let id: String
    let iso: Float
    let shutter: Double      // secondi
}

/// Risultato di una raffica di frame a esposizione fissa.
struct BurstResult {
    var mean: [Double] = [0, 0, 0]       // R, G, B (0-255), media sui frame
    var std: [Double] = [0, 0, 0]        // deviazione standard temporale per canale
    var sigma = 0.0                      // RMS delle tre deviazioni (come nella vecchia versione)
    var frames = 0
    var clipHigh: [Double] = [0, 0, 0]   // frazione di pixel della ROI con canale >= 250
    var clipLow: [Double] = [0, 0, 0]    // frazione di pixel della ROI con canale <= 2
    var reqISO: Float = 0
    var reqShutter = 0.0
    var iso: Float = 0                   // valori reali riletti dalla camera a fine raffica
    var shutter = 0.0
    var gains: [Double] = [1, 1, 1]
    var stable = true                    // false se ISO/otturatore sono cambiati durante la raffica
    var roiPercent = 0.0
    var elapsedMs = 0.0
    var timedOut = false
    var error: String?

    /// Dizionario compatibile con JSONSerialization (niente NaN/inf).
    func json(id: String) -> [String: Any] {
        func f(_ x: Double) -> Double { x.isFinite ? x : -1 }
        var d: [String: Any] = [
            "id": id,
            "req_iso": f(Double(reqISO)),
            "req_shutter_s": f(reqShutter),
            "iso": f(Double(iso)),
            "shutter_s": f(shutter),
            "gains": gains.map(f),
            "mean": mean.map(f),
            "std": std.map(f),
            "sigma": f(sigma),
            "frames": frames,
            "clip_high": clipHigh.map(f),
            "clip_low": clipLow.map(f),
            "exposure_stable": stable,
            "roi_percent": f(roiPercent),
            "elapsed_ms": f(elapsedMs),
            "timed_out": timedOut
        ]
        if let e = error { d["error"] = e }
        return d
    }
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

    // Raffica a esposizione fissa (tutto toccato solo dalla coda `queue`)
    private struct FrameSample {
        var r: Double, g: Double, b: Double
        var hi: [Double]      // frazione di pixel saturi per canale
        var lo: [Double]      // frazione di pixel a zero per canale
    }
    private var burst: [FrameSample]?
    private var burstSkip = 0
    private var burstTarget = 0
    private var burstToken = 0
    private var burstCompletion: ((BurstResult) -> Void)?
    private var burstReq = (iso: Float(0), shutter: 0.0)
    private var burstStart = (iso: Float(0), shutter: 0.0)
    private var burstRequestedAt = Date()

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

    // MARK: - Raffica a esposizione fissa
    /// Imposta ISO e otturatore manuali, scarta `discard` frame (l'esposizione impiega qualche frame
    /// ad assestarsi), poi raccoglie `frames` frame e restituisce le statistiche.
    /// `completion` viene chiamata sulla coda della camera (NON sul main thread).
    func captureBurst(spec: ExposureSpec, discard: Int, frames: Int,
                      completion: @escaping (BurstResult) -> Void) {
        queue.async {
            func fail(_ msg: String) {
                var r = BurstResult()
                r.reqISO = spec.iso
                r.reqShutter = spec.shutter
                r.error = msg
                completion(r)
            }
            guard let d = self.device else { return fail("camera non disponibile") }
            guard d.isExposureModeSupported(.custom) else { return fail("esposizione manuale non supportata") }
            guard self.burstCompletion == nil else { return fail("raffica già in corso") }

            let f = d.activeFormat
            let iso = min(max(spec.iso, f.minISO), f.maxISO)
            let lo = f.minExposureDuration.seconds
            let hi = f.maxExposureDuration.seconds
            let t = CMTime(seconds: min(max(spec.shutter, lo), hi), preferredTimescale: 1_000_000)

            self.burstToken &+= 1
            let token = self.burstToken
            self.burst = nil
            self.burstReq = (spec.iso, spec.shutter)
            self.burstCompletion = completion
            self.burstSkip = max(0, discard)
            self.burstTarget = max(1, frames)
            self.burstRequestedAt = Date()

            do {
                try d.lockForConfiguration()
                d.setExposureModeCustom(duration: t, iso: iso) { [weak self] _ in
                    self?.queue.async { self?.beginBurst(token: token) }
                }
                d.unlockForConfiguration()
            } catch {
                self.burstCompletion = nil
                return fail("lockForConfiguration: \(error.localizedDescription)")
            }
            // Reti di sicurezza: se il completion handler non arriva parti comunque, poi timeout
            self.queue.asyncAfter(deadline: .now() + 1.5) { self.beginBurst(token: token) }
            self.queue.asyncAfter(deadline: .now() + 8.0) {
                if self.burstToken == token { self.completeBurst(timedOut: true) }
            }
        }
    }

    private func beginBurst(token: Int) {
        guard token == burstToken, burst == nil, burstCompletion != nil, let d = device else { return }
        burstStart = (d.iso, d.exposureDuration.seconds)
        burst = []
    }

    private func handleBurstFrame(_ s: FrameSample) {
        if burstSkip > 0 { burstSkip -= 1; return }
        burst?.append(s)
        if (burst?.count ?? 0) >= burstTarget { completeBurst(timedOut: false) }
    }

    private func completeBurst(timedOut: Bool) {
        guard let done = burstCompletion else { return }
        let samples = burst ?? []
        burst = nil
        burstCompletion = nil
        burstToken &+= 1

        var res = BurstResult()
        res.reqISO = burstReq.iso
        res.reqShutter = burstReq.shutter
        res.frames = samples.count
        res.timedOut = timedOut
        res.roiPercent = roiFraction * 100
        res.elapsedMs = Date().timeIntervalSince(burstRequestedAt) * 1000

        if samples.isEmpty {
            res.error = "nessun frame letto"
        } else {
            let n = Double(samples.count)
            var sumR = 0.0, sumG = 0.0, sumB = 0.0
            var hi = [0.0, 0.0, 0.0], lo = [0.0, 0.0, 0.0]
            for s in samples {
                sumR += s.r; sumG += s.g; sumB += s.b
                for c in 0..<3 { hi[c] += s.hi[c]; lo[c] += s.lo[c] }
            }
            let mR = sumR / n, mG = sumG / n, mB = sumB / n
            var vR = 0.0, vG = 0.0, vB = 0.0
            for s in samples {
                vR += (s.r - mR) * (s.r - mR)
                vG += (s.g - mG) * (s.g - mG)
                vB += (s.b - mB) * (s.b - mB)
            }
            vR /= n; vG /= n; vB /= n
            res.mean = [mR, mG, mB]
            res.std = [vR.squareRoot(), vG.squareRoot(), vB.squareRoot()]
            res.sigma = ((vR + vG + vB) / 3.0).squareRoot()
            res.clipHigh = hi.map { $0 / n }
            res.clipLow = lo.map { $0 / n }
        }

        if let d = device {
            res.iso = d.iso
            res.shutter = d.exposureDuration.seconds
            let g = d.deviceWhiteBalanceGains
            res.gains = [Double(g.redGain), Double(g.greenGain), Double(g.blueGain)]
            let isoOK = abs(res.iso - burstStart.iso) < 0.5
            let shutterOK = burstStart.shutter <= 0
                || abs(res.shutter - burstStart.shutter) / burstStart.shutter < 0.02
            res.stable = isoOK && shutterOK
        }
        done(res)
    }

    // MARK: - Info dispositivo (per l'handshake). Da chiamare solo dal main thread.
    func deviceInfo() -> [String: Any] {
        var info: [String: Any] = [
            "model": Self.modelIdentifier(),
            "os": UIDevice.current.systemVersion,
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue
        ]
        queue.sync {
            guard let d = self.device else { return }
            let f = d.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            info["camera"] = d.localizedName
            info["format"] = "\(dims.width)x\(dims.height)"
            info["min_iso"] = Double(f.minISO)
            info["max_iso"] = Double(f.maxISO)
            info["min_exposure_s"] = f.minExposureDuration.seconds
            info["max_exposure_s"] = f.maxExposureDuration.seconds
            info["max_wb_gain"] = Double(d.maxWhiteBalanceGain)
            info["custom_exposure"] = d.isExposureModeSupported(.custom)
            info["custom_wb_gains"] = d.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            info["min_frame_duration_s"] = d.activeVideoMinFrameDuration.seconds
        }
        // JSON non accetta NaN/inf (es. CMTime non valido)
        for (k, v) in info {
            if let x = v as? Double, !x.isFinite { info[k] = nil }
        }
        return info
    }

    private static func modelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
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
        var hr = 0, hg = 0, hb = 0      // pixel saturi (>= 250) per canale
        var lr = 0, lg = 0, lb = 0      // pixel a zero (<= 2) per canale
        var y = y0
        while y < y0 + rh {
            var x = x0
            while x < x0 + rw {
                let p = ptr + y * bpr + x * 4      // formato BGRA
                let vb = Int(p[0]), vg = Int(p[1]), vr = Int(p[2])
                sb += vb
                sg += vg
                sr += vr
                if vr >= 250 { hr += 1 }
                if vg >= 250 { hg += 1 }
                if vb >= 250 { hb += 1 }
                if vr <= 2 { lr += 1 }
                if vg <= 2 { lg += 1 }
                if vb <= 2 { lb += 1 }
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return }
        let dn = Double(n)
        let sample = (Double(sr) / dn, Double(sg) / dn, Double(sb) / dn)

        history.append(sample)
        if history.count > 30 { history.removeFirst() }
        collecting?.append(sample)

        if burst != nil {
            handleBurstFrame(FrameSample(r: sample.0, g: sample.1, b: sample.2,
                                         hi: [Double(hr) / dn, Double(hg) / dn, Double(hb) / dn],
                                         lo: [Double(lr) / dn, Double(lg) / dn, Double(lb) / dn]))
        }

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
