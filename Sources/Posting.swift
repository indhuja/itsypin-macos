import Cocoa

// MARK: - Platform

enum Platform: String, CaseIterable, Codable, Identifiable {
    case x, threads, linkedin, bluesky

    var id: String { rawValue }

    var name: String {
        switch self {
        case .x: return "X"
        case .threads: return "Threads"
        case .linkedin: return "LinkedIn"
        case .bluesky: return "Bluesky"
        }
    }

    /// Template logo in the asset catalog (Assets.xcassets/PlatformLogos).
    /// Source: Simple Icons (simpleicons.org), CC0 1.0. X, Threads and Bluesky from
    /// simple-icons@15.0.0; LinkedIn from simple-icons@9.21.0 (removed in later releases
    /// at LinkedIn's request). The marks are their owners' trademarks, shown only to
    /// identify each platform.
    var logoName: String { "logo-\(rawValue)" }

    /// Approximate per-post character limit (X counts links as 23 and some emoji as 2).
    var limit: Int {
        switch self {
        case .x: return 280
        case .threads: return 500
        case .linkedin: return 3000
        case .bluesky: return 300
        }
    }

    var homeURL: String {
        switch self {
        case .x: return "https://x.com/home"
        case .threads: return "https://www.threads.com"
        case .linkedin: return "https://www.linkedin.com/feed/"
        case .bluesky: return "https://bsky.app"
        }
    }

    private var hosts: [String] {
        switch self {
        case .x: return ["x.com", "twitter.com"]
        case .threads: return ["threads.net", "threads.com"]
        case .linkedin: return ["linkedin.com"]
        case .bluesky: return ["bsky.app"]
        }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: "https?://\\S+")

    /// Characters as the platform counts them. X counts every link as 23.
    func count(_ text: String) -> Int {
        guard self == .x else { return text.count }
        let range = NSRange(text.startIndex..., in: text)
        var count = text.count
        for match in Self.linkPattern.matches(in: text, range: range) {
            count += 23 - (Range(match.range, in: text).map { text[$0].count } ?? 23)
        }
        return count
    }

    func matches(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The platform's own "share" link: opens its real compose box with the text filled in.
    /// The user still presses the site's Post button, so nothing is posted automatically.
    func composeURL(text: String) -> URL? {
        var components: URLComponents
        switch self {
        case .x:
            components = URLComponents(string: "https://x.com/intent/post")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .threads:
            components = URLComponents(string: "https://www.threads.com/intent/post")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .linkedin:
            components = URLComponents(string: "https://www.linkedin.com/feed/")!
            components.queryItems = [
                URLQueryItem(name: "shareActive", value: "true"),
                URLQueryItem(name: "text", value: text)
            ]
        case .bluesky:
            components = URLComponents(string: "https://bsky.app/intent/compose")!
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        }
        // URLComponents leaves "+" alone, which servers read as a space
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

// MARK: - Draft

struct Draft: Identifiable, Equatable {
    var id = UUID()
    var fileURL: URL?
    var text = ""
    /// Platforms this draft is meant for (or was sent to).
    var platforms: [Platform] = [.x]
    var created = Date()
    var sent: [Platform: Date] = [:]
    /// Attachment file names inside the drafts folder's `attachments/` directory.
    var images: [String] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    var preview: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        return images.isEmpty ? "Empty draft" : "Image post"
    }

    var hasBeenSent: Bool { !sent.isEmpty }
}

// MARK: - Draft Store (markdown files, Obsidian-friendly)

/// Drafts live as markdown files so they show up in an Obsidian vault:
///
///     <folder>/Drafts/Post 2026-11-15 130812.md
///     <folder>/Posted/...            (moved here once sent everywhere)
///     <folder>/attachments/...png    (embedded as ![[name.png]])
///
/// Notes written in Obsidian inside Drafts/ appear in the composer too.
final class DraftStore: ObservableObject {
    static let shared = DraftStore()

    @Published private(set) var drafts: [Draft] = []
    @Published var folderPath: String {
        didSet {
            UserDefaults.standard.set(folderPath, forKey: folderKey)
            reload()
        }
    }

    private let folderKey = "draftsFolder"
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private let fm = FileManager.default

    private static let isoFormatter = ISO8601DateFormatter()
    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    var root: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }
    var draftsDir: URL { root.appendingPathComponent("Drafts", isDirectory: true) }
    var postedDir: URL { root.appendingPathComponent("Posted", isDirectory: true) }
    var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }

    private init() {
        folderPath = UserDefaults.standard.string(forKey: folderKey) ?? "~/Documents/Posts"
        reload()
    }

    func imageURL(_ name: String) -> URL {
        attachmentsDir.appendingPathComponent(name)
    }

    // MARK: Loading

    func reload() {
        ensureFolders()
        let files = (try? fm.contentsOfDirectory(
            at: draftsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let dated: [(Draft, Date)] = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let draft = parse(url) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? draft.created
                return (draft, modified)
            }
        drafts = dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func ensureFolders() {
        for dir in [draftsDir, postedDir, attachmentsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func parse(_ url: URL) -> Draft? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var draft = Draft(fileURL: url)
        var body = content

        if content.hasPrefix("---\n"),
           let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            let front = content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound]
            body = String(content[end.upperBound...])
            for line in front.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let key = parts[0], value = parts[1]
                if key == "platforms" {
                    let names = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    draft.platforms = names.compactMap(Platform.init(rawValue:))
                } else if key == "created", let date = Self.isoFormatter.date(from: value) {
                    draft.created = date
                } else if key.hasPrefix("sent_"),
                          let platform = Platform(rawValue: String(key.dropFirst(5))),
                          let date = Self.isoFormatter.date(from: value) {
                    draft.sent[platform] = date
                }
            }
        }

        // Pull ![[image.png]] embeds out of the body into the attachment list
        var textLines: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]") {
                let name = String(trimmed.dropFirst(3).dropLast(2))
                    .split(separator: "|").first.map(String.init) ?? ""
                draft.images.append((name as NSString).lastPathComponent)
            } else {
                textLines.append(line)
            }
        }
        draft.text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    private func serialize(_ draft: Draft) -> String {
        var lines = ["---"]
        lines.append("platforms: [\(draft.platforms.map(\.rawValue).joined(separator: ", "))]")
        lines.append("created: \(Self.isoFormatter.string(from: draft.created))")
        for platform in Platform.allCases {
            if let date = draft.sent[platform] {
                lines.append("sent_\(platform.rawValue): \(Self.isoFormatter.string(from: date))")
            }
        }
        lines.append("---")
        lines.append("")
        lines.append(draft.text)
        if !draft.images.isEmpty {
            lines.append("")
            lines.append(contentsOf: draft.images.map { "![[\($0)]]" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Saving

    /// Debounced save while typing.
    func scheduleSave(_ draft: Draft) {
        pendingSaves[draft.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSaves[draft.id] = nil
            _ = self?.save(draft)
        }
        pendingSaves[draft.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes the draft now and returns it with its file assigned. Empty new drafts are not written.
    @discardableResult
    func save(_ draft: Draft) -> Draft {
        pendingSaves[draft.id]?.cancel()
        pendingSaves[draft.id] = nil

        var draft = draft
        if draft.fileURL == nil {
            guard !draft.isEmpty else { return draft }
            ensureFolders()
            let name = "Post \(Self.fileNameFormatter.string(from: draft.created)).md"
            draft.fileURL = draftsDir.appendingPathComponent(name)
        }
        guard let url = draft.fileURL else { return draft }
        try? serialize(draft).write(to: url, atomically: true, encoding: .utf8)

        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else if url.deletingLastPathComponent().standardizedFileURL == draftsDir.standardizedFileURL {
            drafts.insert(draft, at: 0)
        }
        return draft
    }

    /// Records a send. The draft stays in Drafts/ so it can go to other platforms too.
    func markSent(_ draft: Draft, platform: Platform) -> Draft {
        var draft = draft
        draft.sent[platform] = Date()
        if !draft.platforms.contains(platform) {
            draft.platforms = Platform.allCases.filter { draft.platforms.contains($0) || $0 == platform }
        }
        return save(draft)
    }

    /// Moves a finished draft to Posted/.
    func archive(_ draft: Draft) {
        let draft = save(draft)
        pendingSaves[draft.id]?.cancel()
        pendingSaves[draft.id] = nil
        if let url = draft.fileURL {
            try? fm.moveItem(at: url, to: postedDir.appendingPathComponent(url.lastPathComponent))
        }
        drafts.removeAll { $0.id == draft.id }
    }

    func delete(_ draft: Draft) {
        pendingSaves[draft.id]?.cancel()
        pendingSaves[draft.id] = nil
        if let url = draft.fileURL {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        drafts.removeAll { $0.id == draft.id }
    }

    /// Saves an image into attachments/ and returns its file name.
    func addImage(_ image: NSImage) -> String? {
        ensureFolders()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "post-\(Self.fileNameFormatter.string(from: Date()).replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString.prefix(4)).png"
        do {
            try png.write(to: imageURL(name))
            return name
        } catch {
            return nil
        }
    }
}

// MARK: - Sending

enum PostDispatcher {
    /// Opens the platform's real compose box (in its pinned bubble when there is one)
    /// with the draft's text filled in. Returns a status line for the composer.
    static func send(_ draft: Draft, to platform: Platform) -> String {
        guard let url = platform.composeURL(text: draft.text) else {
            return "Couldn't build the \(platform.name) link."
        }

        var note = ""
        if let first = draft.images.first,
           let image = NSImage(contentsOf: DraftStore.shared.imageURL(first)) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            note = draft.images.count > 1
                ? " First image copied: press ⌘V there, and drag the others in from the composer."
                : " Image copied: press ⌘V in the \(platform.name) compose box."
        }

        if let site = SettingsStore.shared.pinnedSites.first(where: { platform.matches($0.url) }),
           let delegate = NSApp.delegate as? AppDelegate {
            delegate.openCompose(url, in: site)
            return "Opened \(platform.name) with your text. Review it and press Post." + note
        }

        NSWorkspace.shared.open(url)
        return "\(platform.name) isn't pinned, so it opened in your browser." + note
    }
}
