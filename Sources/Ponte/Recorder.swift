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
    private(set) var currentURL: URL?

    /// The recording's columns, newest last: what the orb is drawn from, with the ballistics and the
    /// dB mapping applied by the engine and by `WaveformUI`'s view.
    var columns: ColumnRing? { engine?.columns }

    /// Where the audio's time meets the screen's, so the orb's picture moves smoothly between buffers.
    var clock: StreamClock? { engine?.clock }

    /// The microphone this take is coming from — logged, and part of explaining a quiet take.
    private(set) var deviceName = "unknown"

    /// The loudest sample in the newest column, in dBFS: what `InputWatch` reads.
    var newestPeakDB: Float? {
        guard let ring = engine?.columns else { return nil }
        var column = Column.silent
        let found = withUnsafeMutablePointer(to: &column) { ring.copyLast(1, into: $0) }
        return found > 0 ? InputWatch.peakDB(column) : nil
    }

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
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        let url = AppPaths.audio.appendingPathComponent("rec-\(AppPaths.stamp()).wav")

        let recorder = EngineRecorder(settings: .localTranscription)
        try recorder.start(to: url)
        engine = recorder
        currentURL = url
        deviceName = device
        vlog("record start device=\(device) file=\(url.lastPathComponent) format=16kHz-mono-wav")
        return url
    }

    @discardableResult
    func stop() -> URL? {
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
}
