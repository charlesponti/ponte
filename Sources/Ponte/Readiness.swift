import Foundation

/// Whether Ponte can dictate yet, and what to say when it cannot.
///
/// The first run has a cold cost the app used to pay invisibly. Parakeet's models are ~613 MB and are
/// not on disk yet; the launch-time preload began fetching them with no progress reported anywhere, and
/// a hotkey press in that window recorded a take and then waited for the download — which is how a first
/// dictation could take minutes and read as a freeze. The same was true after switching to a model that
/// was not installed: the menu offered the switch, the download ran behind it, and the next dictation
/// stalled.
///
/// So the state is explicit now. The app says what it is doing, and it declines to start a take it cannot
/// finish promptly, rather than swallowing one.
enum Readiness: Equatable {
    case ready
    case preparing(percent: Int?, note: String)
    case failed(String)

    /// Can a dictation start? Only when everything it needs is on disk and loaded.
    var allowsDictation: Bool { self == .ready }

    /// The menu's first line while this is the state.
    var menuTitle: String {
        switch self {
        case .ready: return "Start Recording"
        case .preparing(let percent, let note):
            return percent.map { "\(note) — \($0)%" } ?? note
        case .failed(let message): return message
        }
    }

    /// What to say when someone dictates anyway. Short enough for the pill — the square box fits about
    /// sixteen characters under the orb — with the rest in the log and the menu.
    ///
    /// Note what this is *not*: a failure. A first-run download is the app doing what it said it would,
    /// so the pill shows it in amber, not the red of an error.
    var refusalLabel: String {
        switch self {
        case .ready: return ""
        case .preparing(let percent, _): return percent.map { "Loading — \($0)%" } ?? "Loading"
        case .failed: return "Not ready"
        }
    }

    /// Whether the HUD can show this as a number in progress, rather than a finished pill.
    var percent: Int? {
        if case .preparing(let percent, _) = self { return percent }
        return nil
    }

    /// The percentage out of an engine progress line such as
    /// "Downloading Parakeet models… 43% (12/20 files)". Nil when there is no number in it.
    ///
    /// The lookbehind matters: without it `1234%` matches its last three digits and reads as 234%.
    static func percent(in message: String) -> Int? {
        guard let range = message.range(of: #"(?<!\d)(\d{1,3})%"#, options: .regularExpression),
              let value = Int(message[range].dropLast()) else { return nil }
        return value
    }
}
