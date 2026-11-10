import AppKit
import LocalAuthentication
import SwiftUI
import Vision

/// The «Выдачи» tab: the journal, search by code or text, and search by a dropped copy.
@MainActor
final class IssuesModel: ObservableObject {
    @Published var journal: IssueJournal?
    @Published var query = ""
    @Published var message: String?
    @Published var found: [String]?
    let store: ArchiveStore

    init(store: ArchiveStore) { self.store = store }

    func unlock() async {
        do {
            let ctx = try await store.confirm(reason: "показать выдачи")
            defer { ctx?.invalidate() }
            journal = try IssueJournal(store: store, context: ctx)
            message = nil
        } catch ArchiveError.cancelled {
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// After a sheet: take its journal, already open, instead of keeping a confirmed context around.
    func adopt(_ j: IssueJournal?) {
        if journal != nil, let j { journal = j }
    }

    /// The window closed: the journal leaves memory, the next look asks Touch ID again.
    func lock() {
        journal = nil
        query = ""
        found = nil
        message = nil
    }

    var shown: [Issue] {
        guard let issues = journal?.issues else { return [] }
        if let found { return issues.filter { found.contains($0.code) }.reversed() }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return issues.reversed() }
        return ReprintRules.search(q, in: issues).map { issues[$0] }.reversed()
    }

    /// OCR of a copy, then the code reader of spec/issue-code.md.
    func find(copy url: URL) {
        guard let journal else { return }
        message = ReprintText.reading
        found = nil
        let codes = Set(journal.codes)
        Task.detached {
            let lines = Self.lines(url)
            let r = ReprintRules.find(lines: lines, journal: codes)
            await MainActor.run {
                switch r {
                case .code(let c, _): self.found = [c]; self.message = nil
                case .ambiguous(let cs): self.found = cs; self.message = ReprintText.several(cs)
                case .none: self.found = []; self.message = ReprintText.notFound
                }
            }
        }
    }

    nonisolated static func lines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let src = try? ReprintSource(data: data, name: url.lastPathComponent) else { return [] }
        return src.pages.flatMap { img -> [String] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["ru-RU", "en-US"]
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: img).perform([req])
            return (req.results ?? []).flatMap { $0.topCandidates(3).map(\.string) }
        }
    }
}

struct IssuesView: View {
    @ObservedObject var model: IssuesModel
    @State private var targeted = false

    var body: some View {
        if model.journal == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text(ReprintText.issuesLocked).font(.system(size: 13)).foregroundStyle(Theme.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                if let m = model.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.ink) }
                Button(ReprintText.showIssues) { Task { await model.unlock() } }.buttonStyle(CardButtonStyle(primary: true))
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TextField(ReprintText.search, text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.query) { model.found = nil; model.message = nil }
                    Button(ReprintText.findByCopy) { pick() }.buttonStyle(CardButtonStyle())
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                if let m = model.message {
                    Text(m).font(.system(size: 12)).foregroundStyle(Theme.ink).padding(.horizontal, 20).padding(.bottom, 6)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.journal?.issues.isEmpty == true {
                            Text(ReprintText.issuesEmpty).font(.system(size: 12)).foregroundStyle(Theme.graphite).padding(20)
                        }
                        ForEach(model.shown) { i in
                            row(i)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                Text(ReprintText.dropCopy).font(.system(size: 11)).foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity).padding(8)
                    .background(targeted ? Theme.markerFill : Color.clear)
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.find(copy: url) } }
                }
                return true
            }
        }
    }

    private func row(_ i: Issue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(i.code).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(model.found?.contains(i.code) == true ? Theme.markerFill : .clear))
            VStack(alignment: .leading, spacing: 2) {
                Text("Для: \(i.purpose)").font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(i.title), \(Self.via(i))").font(.system(size: 11)).foregroundStyle(Theme.graphite).lineLimit(1)
            }
            Spacer()
            Text(Self.date.string(from: i.at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.graphite)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    static func via(_ i: Issue) -> String {
        if i.via == "downloads" { return "в Загрузки" }
        guard let app = i.app else { return "перетаскиванием" }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app).map { FileManager.default.displayName(atPath: $0.path) }
        return "в \((name ?? app).replacingOccurrences(of: ".app", with: ""))"
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    private func pick() {
        let p = NSOpenPanel()
        p.title = ReprintText.findByCopy
        p.allowedContentTypes = [.image, .pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        model.find(copy: u)
    }
}
