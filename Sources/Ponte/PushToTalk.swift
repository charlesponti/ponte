import Foundation

/// How the dictation key behaves.
enum HotKeyMode: String, CaseIterable {
    /// Press to start, press again to stop — what Ponte has always done.
    case toggle
    /// Hold to talk: press, speak, release.
    case pushToTalk

    var label: String {
        switch self {
        case .toggle: return "Press to start, press to stop"
        case .pushToTalk: return "Hold to talk"
        }
    }

    static var current: HotKeyMode {
        HotKeyMode(rawValue: UserDefaults.standard.string(forKey: SettingKey.hotKeyMode) ?? "") ?? .toggle
    }
}

/// What the dictation key should do, given the mode and the take's state.
///
/// Pure, because the interesting cases are the ones a person cannot reproduce on demand: a tap that is shorter than
/// the engine's floor, a release that arrives while the take is still starting, a press that lands while the previous
/// transcription is still running.
///
/// The rules worth stating out loud:
///
/// - In **push-to-talk**, the release is what ends the take. A quick tap therefore never leaves a recording running:
///   a release that arrives while the take is still *starting* cancels it, and nothing is written.
/// - A release is never a *toggle*. Deciding that a short tap means "toggle" is how someone ends up with a take they
///   cannot stop.
/// - In **toggle**, a release does nothing at all. The key-up of the chord that started a dictation must not end it.
enum PushToTalk {

    enum Event: Equatable {
        case press
        case release
    }

    enum Action: Equatable {
        case none
        case start
        case finish
        /// Throw the take away: no transcription, no note, audio deleted.
        case cancel
    }

    /// A take that reaches this long ends itself, whatever the keyboard is doing.
    ///
    /// Not a feature — a ceiling. Three ordinary things lose the key-up: switching app mid-hold, focus moving into a
    /// secure input field (password prompts swallow key events entirely), and the keyboard going away. Without a
    /// ceiling, a lost release records until the microphone is stopped by hand.
    static let ceiling: TimeInterval = 300

    static func action(mode: HotKeyMode, state: AppState, event: Event) -> Action {
        switch mode {
        case .toggle:
            guard event == .press else { return .none }
            switch state {
            case .idle: return .start
            case .starting, .working: return .none
            case .recording: return .finish
            }

        case .pushToTalk:
            switch event {
            case .press:
                switch state {
                case .idle: return .start
                case .starting, .recording, .working: return .none
                }
            case .release:
                switch state {
                case .starting: return .cancel     // a tap shorter than the engine's floor
                case .recording: return .finish
                case .idle, .working: return .none
                }
            }
        }
    }

    /// Whether a take has run past the ceiling and has to end by itself.
    static func hasReachedCeiling(_ elapsed: TimeInterval) -> Bool {
        elapsed >= ceiling
    }
}
