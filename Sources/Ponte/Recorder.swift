import AVFoundation
import Foundation

/// Records the default input device to a 16 kHz mono 16-bit WAV — exactly what
/// whisper.cpp wants, so no conversion step is ever needed.
final class Recorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var currentURL: URL?
    private(set) var startedAt: Date?

    /// One meter tick: how loud the microphone is, and how high its peak was. Both are 0…1, mapped
    /// from dBFS the way Waveform's `Scale.decibels` maps a sample onto its display range.
    var onMeter: ((_ level: Float, _ peak: Float) -> Void)?

    var isRecording: Bool { recorder?.isRecording ?? false }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws -> URL {
        // Defensive: never leak a running recorder — that leaves a header-only WAV
        // behind and a mic that stays hot.
        if recorder?.isRecording == true {
            vlog("recorder already running — stopping it before restarting")
            stop()
        }
        try FileManager.default.createDirectory(at: AppPaths.audio, withIntermediateDirectories: true)

        // Which mic? Honour the system default input; log it so history is traceable.
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        let url = AppPaths.audio.appendingPathComponent("rec-\(AppPaths.stamp()).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.prepareToRecord()
        guard r.record() else { throw PonteError.recordFailed }

        recorder = r
        currentURL = url
        startedAt = Date()
        vlog("record start device=\(deviceName) file=\(url.lastPathComponent)")
        startMetering()
        return url
    }

    @discardableResult
    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        let url = currentURL
        let seconds = elapsed
        recorder = nil
        currentURL = nil
        startedAt = nil
        if let url {
            vlog(String(format: "record stop file=%@ duration=%.2fs", url.lastPathComponent, seconds))
        }
        return url
    }

    private func startMetering() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder, r.isRecording else { return }
            r.updateMeters()
            // Both powers are dBFS in -160...0; map -55 dB up to 1.0.
            func norm(_ db: Float) -> Float {
                Float(max(0.0, min(1.0, (Double(db) + 55.0) / 55.0)))
            }
            self.onMeter?(norm(r.averagePower(forChannel: 0)), norm(r.peakPower(forChannel: 0)))
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }
}
