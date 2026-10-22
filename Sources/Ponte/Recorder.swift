import AVFoundation
import Foundation
import WaveformCapture
import WaveformCore

/// Ponte's capture: the shared engine in `WaveformCapture`, in the configuration on-device
/// transcription wants — a 16 kHz mono 16-bit WAV, exactly what whisper.cpp and Parakeet read, so no
/// conversion step is ever needed.
///
/// This used to be `AVAudioRecorder` plus a 30 Hz dB meter. The engine does both better: real RMS at
/// 120 columns a second with meter ballistics, the same analysis Thames draws its orb from, and the
/// route-change and cut-short handling that comes with it.
final class Recorder {
    private var engine: EngineRecorder?
    private var meterTimer: Timer?
    private(set) var currentURL: URL?

    /// One meter tick: how loud the microphone is, and how high its peak was, both mapped onto the
    /// display range by the same `Scale` the orb uses.
    var onMeter: ((_ level: Float, _ peak: Float) -> Void)?

    /// The recording's columns, newest last: what the orb is drawn from. Ponte reads the newest entry
    /// here for now; the orb moves onto this ring directly with the SwiftUI HUD.
    var columns: ColumnRing? { engine?.columns }

    var isRecording: Bool { engine != nil }

    /// How much has been recorded, from the frames written rather than from a wall clock.
    var elapsed: TimeInterval { engine?.seconds ?? 0 }

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
        // Defensive: never leak a running recording — that leaves a header-only WAV behind and a
        // microphone that stays hot.
        if engine != nil {
            vlog("recorder already running — stopping it before restarting")
            stop()
        }
        // Touching the engine's input node before the grant is not safe.
        guard Self.isAuthorized else { throw PonteError.recordFailed }
        try FileManager.default.createDirectory(at: AppPaths.audio, withIntermediateDirectories: true)

        // Which mic? Honour the system default input; log it so history is traceable.
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        let url = AppPaths.audio.appendingPathComponent("rec-\(AppPaths.stamp()).wav")

        let recorder = EngineRecorder(settings: .localTranscription)
        try recorder.start(to: url)
        engine = recorder
        currentURL = url
        vlog("record start device=\(deviceName) file=\(url.lastPathComponent) format=16kHz-mono-wav")
        startMetering()
        return url
    }

    @discardableResult
    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        let url = currentURL
        let seconds = elapsed
        var incomplete: String?
        do {
            _ = try engine?.stop()
        } catch {
            incomplete = error.localizedDescription
        }
        engine = nil
        currentURL = nil
        if let url {
            vlog(String(format: "record stop file=%@ duration=%.2fs", url.lastPathComponent, seconds))
        }
        if let incomplete { vlog("record incomplete: \(incomplete)") }
        return url
    }

    /// Reads the newest column at a steady 30 a second and reports it on the display scale.
    private func startMetering() {
        let scale = Scale.decibels(floor: -55)
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let columns = self.columns, columns.count > 0 else { return }
            var column = Column.silent
            _ = withUnsafeMutablePointer(to: &column) { pointer in
                columns.snapshot(1, into: pointer)
            }
            let peak = max(abs(column.high), abs(column.low))
            self.onMeter?(max(0, scale.height(column.level)), max(0, scale.height(peak)))
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }
}
