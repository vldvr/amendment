import Foundation

/// Wording of Desk, dry as in Zamazka.
enum DeskText {
    static func status(_ moved: Int) -> String { moved == 0 ? "Стол: убирать нечего" : "Стол убрал: \(moved)" }
}
