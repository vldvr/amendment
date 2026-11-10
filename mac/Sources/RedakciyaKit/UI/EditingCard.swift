import AppKit
import SwiftUI

/// Wording of the card. Texts follow spec/link-rules.md «Формулировки»: the tag may belong to whoever
/// sent the link, and the recipient does not see the sender — the service does.
enum EditingText {
    static let service: [String: String] = [
        "instagram": "Instagram", "youtube": "YouTube", "spotify": "Spotify", "tiktok": "TikTok", "x": "X",
    ]

    static func from(_ app: String) -> String { "Редактура, скопировано в \(app)" }
    static let title = "В ссылке метка аккаунта"
    static let returnedTitle = "Хвост возвращён"
    static let returnedBody = "В буфере ссылка как была."
    static let stale = "В буфере уже другое."
    static func silent(_ n: Int) -> String { "Убрано хвостов: \(n)" }

    /// Names that gave the person away, in input order, without repeats.
    static func givingAway(_ e: EditingEvent, rules: LinkRules) -> [String] {
        var seen = Set<String>()
        return e.cleaned.removed.filter { name in
            classOf(name, e: e, rules: rules) == .givesAway && seen.insert(name).inserted
        }
    }

    static func trackingCount(_ e: EditingEvent, rules: LinkRules) -> Int {
        e.cleaned.removed.filter { classOf($0, e: e, rules: rules) != .givesAway }.count
    }

    /// Class of a removed name, for wording only. The cleaner already decided what to remove.
    private static func classOf(_ name: String, e: EditingEvent, rules: LinkRules) -> LinkRules.TailClass {
        let domain = rules.domains.first { $0.id == e.cleaned.domain }
        if let p = domain?.params.first(where: { $0.name.map { $0.lowercased() == name } ?? name.hasPrefix($0.prefix!.lowercased()) }) {
            return p.class
        }
        if rules.global.params.contains(where: { $0.name.map { $0.lowercased() == name } ?? name.hasPrefix($0.prefix!.lowercased()) }) {
            return .tracks
        }
        return domain?.unknownClass ?? .tracks
    }

    static func body(_ e: EditingEvent, rules: LinkRules) -> AttributedString {
        let names = givingAway(e, rules: rules)
        var s = AttributedString(names.count == 1 ? "По хвосту " : "По хвостам ")
        for (i, n) in names.enumerated() {
            if i > 0 { s += AttributedString(", ") }
            var b = AttributedString(n)
            b.foregroundColor = Theme.ink
            b.font = .system(size: 13, weight: .semibold)
            s += b
        }
        let who = e.cleaned.domain.flatMap { service[$0] } ?? "сервис"
        s += AttributedString(" \(who) связывает ссылку с тем, кто ей поделился. В буфере уже чистая ссылка.")
        let tracks = trackingCount(e, rules: rules)
        if tracks > 0 { s += AttributedString(" Ещё убраны метки перехода: \(tracks).") }
        return s
    }

    /// The original link without the scheme, removed segments marked.
    static func marked(_ e: EditingEvent) -> [(text: String, removed: Bool)] {
        var original = e.original
        if let r = original.range(of: "://") { original = String(original[r.upperBound...]) }
        if original.lowercased().hasPrefix("www.") { original = String(original.dropFirst(4)) }
        let removed = Set(e.cleaned.removed)
        var out: [(String, Bool)] = []
        var buffer = ""
        var inParams = false
        var segment = ""
        var segmentStart = ""
        func flushSegment() {
            guard !segment.isEmpty || !segmentStart.isEmpty else { return }
            let name = LinkCleaner.percentDecode(String(segment.split(separator: "=", maxSplits: 1).first ?? "")).lowercased()
            let isRemoved = removed.contains(name)
            if !buffer.isEmpty { out.append((buffer, false)); buffer = "" }
            out.append((segmentStart + segment, isRemoved))
            segment = ""
            segmentStart = ""
        }
        for ch in original {
            if ch == "?" || ch == "#" || (ch == "&" && inParams) {
                if inParams { flushSegment() }
                inParams = true
                segmentStart = String(ch)
            } else if inParams {
                segment.append(ch)
            } else {
                buffer.append(ch)
            }
        }
        if inParams { flushSegment() }
        if !buffer.isEmpty { out.append((buffer, false)) }
        // Merge neighbours of the same kind so the marker runs as one stroke.
        var merged: [(text: String, removed: Bool)] = []
        for part in out {
            if let lastPart = merged.last, lastPart.removed == part.1 {
                merged[merged.count - 1].text += part.0
            } else {
                merged.append((part.0, part.1))
            }
        }
        return merged
    }
}

@MainActor
final class EditingCardModel: ObservableObject {
    @Published var event: EditingEvent
    @Published var returned = false
    @Published var stale = false
    let rules: LinkRules

    init(event: EditingEvent, rules: LinkRules) {
        self.event = event
        self.rules = rules
    }
}

struct EditingCardView: View {
    @ObservedObject var model: EditingCardModel
    var onReturn: () -> Void
    var onCleanAgain: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 12))
                Text(EditingText.from(model.event.appName))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.graphite)
            .padding(.bottom, 6)

            Text(model.returned ? EditingText.returnedTitle : EditingText.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 8)

            link
                .padding(.bottom, 10)

            Group {
                if model.returned {
                    Text(EditingText.returnedBody)
                } else {
                    Text(EditingText.body(model.event, rules: model.rules))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.graphite)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                if model.stale {
                    Text(EditingText.stale).font(.system(size: 12)).foregroundStyle(Theme.graphite)
                }
                Spacer()
                if !model.stale {
                    if model.returned {
                        Button("Убрать снова", action: onCleanAgain).buttonStyle(CardButtonStyle())
                    } else {
                        Button("Вернуть хвост", action: onReturn).buttonStyle(CardButtonStyle())
                    }
                }
                Button("Готово", action: onClose)
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 364, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Color(red: 40 / 255, green: 44 / 255, blue: 40 / 255).opacity(0.18), radius: 16, x: 0, y: 10)
    }

    private var link: some View {
        let parts = EditingText.marked(model.event)
        var s = AttributedString()
        for p in parts {
            var a = AttributedString(p.text)
            if p.removed {
                a.backgroundColor = Theme.markerFill
                a.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.markerEdge)
                if !model.returned { a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.ink) }
            }
            s += a
        }
        return Text(s)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
            .textSelection(.enabled)
    }
}

/// The card panel under the menu bar icon. One card at a time; a new copy replaces it.
@MainActor
final class EditingCardController {
    private var panel: NSPanel?
    private var model: EditingCardModel?
    private var staleTimer: Timer?
    var anchorScreen: () -> NSScreen? = { nil }
    var editor: ClipboardEditor?

    func show(_ event: EditingEvent) {
        guard let editor else { return }
        let model = EditingCardModel(event: event, rules: editor.rules)
        self.model = model
        let view = EditingCardView(
            model: model,
            onReturn: { [weak self] in
                if self?.editor?.returnTail() == true { model.returned = true } else { model.stale = true }
            },
            onCleanAgain: { [weak self] in
                if self?.editor?.cleanAgain() == true { model.returned = false } else { model.stale = true }
            },
            onClose: { [weak self] in self?.close() }
        )
        let pad: CGFloat = 28 // room for the shadow
        let host = NSHostingView(rootView: view.padding(pad))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        // As in the mockups: 14 pt from the right edge, just under the menu bar.
        let screen = (anchorScreen() ?? NSScreen.main)?.visibleFrame ?? .zero
        let right = screen.maxX - 14 + pad
        let top = screen.maxY - 6 + pad
        let frame = NSRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = p.isVisible
        if reduce || wasVisible {
            p.setFrame(frame, display: true)
            p.alphaValue = 1
            p.orderFrontRegardless()
        } else {
            p.setFrame(frame.offsetBy(dx: 0, dy: 8), display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(frame, display: true)
                p.animator().alphaValue = 1
            }
        }

        staleTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editor, let model = self.model else { return }
                let stale = !editor.lastIsCurrent
                if model.stale != stale { model.stale = stale }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        staleTimer = t
    }

    func close() {
        staleTimer?.invalidate()
        staleTimer = nil
        panel?.orderOut(nil)
        model = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView?.wantsLayer = true
        return p
    }
}
