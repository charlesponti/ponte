import AppKit
import Foundation
import SwiftUI

/// Which composition the window draws.
///
/// Three directions from the design brainstorm, plus `plain` for the build that shipped before them. Kept as one flag
/// (`--variant`, or `defaults write com.ponti.ponte windowVariant ledger`) so a direction can be looked at — and
/// measured — as it really renders, instead of as an approximation in a board.
enum WindowVariant: String, CaseIterable {
    /// The shipped build: flat rows, no reading surface, full-bleed content.
    case plain
    /// Timeline: day sections, a spine of duration ticks, and the selected dictation read as prose.
    case ledger
    /// A dark room with one lit object: the content pane floats as a card on a warm base.
    case studio
    /// A narrow icon rail instead of a labelled sidebar, giving the content its width back.
    case rail

    static var current: WindowVariant {
        // `ledger` is the approved direction; the others stay reachable by flag for comparison.
        WindowVariant(rawValue: UserDefaults.standard.string(forKey: "windowVariant") ?? "") ?? .ledger
    }

    /// Day sections and the reading surface. In every direction *except* the shipped one: a long dictation cannot be
    /// read in the window at all otherwise, and all three assume it can.
    var groupsByDay: Bool { self != .plain }
    var reads: Bool { self != .plain }
    var floatsContent: Bool { self == .studio }
    var usesRail: Bool { self == .rail }
    /// The app's own mark, above the navigation. The menu bar glyph, not a drawing of one.
    var showsMark: Bool { self == .ledger || self == .studio }

    var summary: String {
        switch self {
        case .plain: return "Shipped build — flat rows, full-bleed content"
        case .ledger: return "Day sections, duration ticks, the selection read as prose"
        case .studio: return "Floating content card on a warm base, plus the mark"
        case .rail: return "Icon rail, content gets the width back"
        }
    }
}

extension Pane {
    /// What the rail uses in place of a label.
    var symbol: String {
        switch self {
        case .dictations: return "tray.full"
        case .general: return "slider.horizontal.3"
        case .speech: return "waveform"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// One day of dictations, with the honest totals for its header.
struct DaySection: Identifiable {
    let id: String
    let title: String
    let notes: [History.Note]

    var count: Int { notes.count }
    var seconds: Double { notes.reduce(0) { $0 + DaySection.seconds(of: $1) } }

    var summary: String {
        let n = count == 1 ? "1 dictation" : "\(count) dictations"
        guard seconds > 0 else { return n }
        return "\(n) · \(DaySection.duration(seconds))"
    }

    /// A note's stored duration, e.g. "13.9s". Anything unexpected counts as zero rather than breaking a header.
    static func seconds(of note: History.Note) -> Double {
        let raw = note.duration.trimmingCharacters(in: .whitespaces).lowercased()
        guard raw.hasSuffix("s") else { return 0 }
        return Double(raw.dropLast()) ?? 0
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) m \(Int(seconds) % 60) s" }
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    /// Group in the order the notes arrive (newest first), keeping that order between sections.
    static func group(_ notes: [History.Note]) -> [DaySection] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: (Date, [History.Note])] = [:]

        for note in notes {
            let date = note.date ?? Date.distantPast
            let day = calendar.startOfDay(for: date)
            let key = ISO8601DateFormatter.dayFormatter.string(from: day)
            if buckets[key] == nil {
                buckets[key] = (day, [])
                order.append(key)
            }
            buckets[key]?.1.append(note)
        }

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        return order.compactMap { key in
            guard let (day, notes) = buckets[key], !notes.isEmpty else { return nil }
            let title: String
            if day == today { title = "Today" }
            else if day == yesterday { title = "Yesterday" }
            else {
                let f = DateFormatter()
                f.dateFormat = calendar.isDate(day, equalTo: today, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
                title = f.string(from: day)
            }
            return DaySection(id: key, title: title, notes: notes)
        }
    }
}

private extension ISO8601DateFormatter {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
