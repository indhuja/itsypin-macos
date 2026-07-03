import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let composerPasteImage = Notification.Name("composerPasteImage")
    static let composerDidOpen = Notification.Name("composerDidOpen")
}

// MARK: - Look of each platform's compose box (dark mode)

private struct ComposeSkin {
    let placeholder: String
    let replyLine: String
    let replyIcon: String
    let accent: Color
    let buttonFill: Color
    let buttonText: Color
    let buttonCorner: CGFloat
    let showsName: Bool

    static func of(_ platform: Platform) -> ComposeSkin {
        switch platform {
        case .x:
            return ComposeSkin(placeholder: "What's happening?", replyLine: "Everyone can reply", replyIcon: "globe.americas.fill",
                               accent: Color(red: 0.11, green: 0.61, blue: 0.94), buttonFill: .white, buttonText: .black,
                               buttonCorner: 18, showsName: false)
        case .threads:
            return ComposeSkin(placeholder: "What's new?", replyLine: "Anyone can reply & quote", replyIcon: "",
                               accent: Color(white: 0.55), buttonFill: .white, buttonText: .black,
                               buttonCorner: 10, showsName: true)
        case .linkedin:
            return ComposeSkin(placeholder: "What do you want to talk about?", replyLine: "Post to Anyone", replyIcon: "globe",
                               accent: Color(red: 0.44, green: 0.71, blue: 0.98), buttonFill: Color(red: 0.44, green: 0.71, blue: 0.98),
                               buttonText: .black, buttonCorner: 18, showsName: true)
        case .bluesky:
            return ComposeSkin(placeholder: "What's up?", replyLine: "Everybody can reply", replyIcon: "globe",
                               accent: Color(red: 0.06, green: 0.51, blue: 1.0), buttonFill: Color(red: 0.06, green: 0.51, blue: 1.0),
                               buttonText: .white, buttonCorner: 18, showsName: false)
        }
    }
}

private enum Palette {
    static let background = Color.black
    static let sidebar = Color(white: 0.06)
    static let border = Color(white: 0.18)
    static let secondary = Color(red: 0.44, green: 0.46, blue: 0.48) // X's #71767B
    static let warning = Color(red: 1.0, green: 0.83, blue: 0.0)      // X's #FFD400
    static let danger = Color(red: 0.96, green: 0.13, blue: 0.18)     // X's #F4212E
}

// MARK: - Composer

struct ComposerView: View {
    @ObservedObject private var store = DraftStore.shared
    @State private var draft = Draft()
    @State private var platform: Platform = .x
    @State private var status: String?
    @State private var isDropTargeted = false
    @FocusState private var editorFocused: Bool

    private let displayName = NSFullUserName().isEmpty ? "You" : NSFullUserName()
    private var initial: String { String(displayName.first ?? "Y").uppercased() }
    private var skin: ComposeSkin { .of(platform) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Rectangle().fill(Palette.border).frame(width: 1)
            VStack(spacing: 0) {
                platformTabs
                Rectangle().fill(Palette.border).frame(height: 1)
                composeBox
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .onChange(of: draft) { newValue in
            store.scheduleSave(newValue)
        }
        .onChange(of: platform) { newValue in
            // Remember which platform this draft is being written for
            if !draft.platforms.contains(newValue) && !draft.hasBeenSent {
                draft.platforms = [newValue]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerPasteImage)) { note in
            if let image = note.object as? NSImage { addImage(image) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerDidOpen)) { _ in
            editorFocused = true
        }
        .onAppear {
            // Debug aid: `--compose-first` opens the newest draft
            if ProcessInfo.processInfo.arguments.contains("--compose-first"), let first = store.drafts.first {
                select(first)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Drafts").font(.system(size: 15, weight: .bold))
                Text("\(store.drafts.count)")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                Spacer()
                Button(action: newDraft) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New draft (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.drafts) { item in
                        draftRow(item)
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            Button {
                NSWorkspace.shared.open(store.root)
            } label: {
                Label("Saved in \((store.folderPath as NSString).lastPathComponent)", systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
            }
            .buttonStyle(.plain)
            .help(store.root.path)
            .padding(14)
        }
        .background(Palette.sidebar)
    }

    private func draftRow(_ item: Draft) -> some View {
        let selected = item.id == draft.id
        return Button {
            select(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.preview)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(shortDate(item.created))
                        if !item.images.isEmpty {
                            Label("\(item.images.count)", systemImage: "photo")
                        }
                        ForEach(Platform.allCases.filter { item.sent[$0] != nil }) { sent in
                            Text("✓ \(sent.name)")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondary)
                }
                Spacer(minLength: 0)
                if let first = item.images.first, let image = NSImage(contentsOf: store.imageURL(first)) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(white: 0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move to Posted") {
                store.archive(item)
                if item.id == draft.id { draft = Draft(platforms: [platform]) }
            }
            Button("Delete draft", role: .destructive) {
                store.delete(item)
                if item.id == draft.id { draft = Draft(platforms: [platform]) }
            }
        }
    }

    /// "now", "5m", "3h", "Nov 15", like X's timestamps. Static, so it doesn't tick.
    private func shortDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Platform tabs

    /// Which compose box you're writing in. Switching changes the look, the
    /// character limit and where Post sends it.
    private var platformTabs: some View {
        HStack(spacing: 0) {
            ForEach(Platform.allCases) { item in
                let selected = item == platform
                Button {
                    platform = item
                } label: {
                    VStack(spacing: 8) {
                        Image(item.logoName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundColor(selected ? .white : Palette.secondary)
                            .accessibilityHidden(true)
                        HStack(spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 14, weight: selected ? .bold : .medium))
                                .foregroundColor(selected ? .white : Palette.secondary)
                            if draft.sent[item] != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.secondary)
                            }
                        }
                        Capsule()
                            .fill(selected ? ComposeSkin.of(item).accent : .clear)
                            .frame(width: 44, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 38)
    }

    // MARK: Compose box

    private var composeBox: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 10) {
                        if skin.showsName {
                            Text(displayName).font(.system(size: 15, weight: .bold))
                        }
                        textArea
                        if !draft.images.isEmpty {
                            mediaGrid
                        }
                        replyLine
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(skin.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
                    .opacity(isDropTargeted ? 1 : 0)
            )
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted, perform: handleDrop)

            if let status {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 68)

            toolbar
                .padding(.leading, 60)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.61, blue: 0.94), .purple],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
            .overlay(Text(initial).font(.system(size: 17, weight: .bold)).foregroundColor(.white))
    }

    /// Grows with the text, like the real compose boxes.
    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            // Invisible copy of the text sizes the editor
            Text(draft.text.isEmpty ? " " : draft.text + "\n")
                .font(.system(size: 20))
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
            if draft.text.isEmpty {
                Text(skin.placeholder)
                    .font(.system(size: 20))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft.text)
                .font(.system(size: 20))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .background(Color.clear)
                .focused($editorFocused)
        }
        .frame(minHeight: 56)
    }

    private var mediaGrid: some View {
        let single = draft.images.count == 1
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: single ? 1 : 2)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(draft.images, id: \.self) { name in
                mediaTile(name, height: single ? 300 : 150)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func mediaTile(_ name: String, height: CGFloat) -> some View {
        let url = store.imageURL(name)
        return ZStack(alignment: .topLeading) {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    // Drag a tile straight into the site's compose box
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Drag into the \(platform.name) compose box to attach")
            } else {
                Rectangle().fill(Color(white: 0.1)).frame(height: height)
            }
            Button {
                draft.images.removeAll { $0 == name }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.black.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    private var replyLine: some View {
        HStack(spacing: 5) {
            if !skin.replyIcon.isEmpty {
                Image(systemName: skin.replyIcon).font(.system(size: 12))
            }
            Text(skin.replyLine).font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(skin.accent)
        .padding(.top, 4)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("photo", help: "Add images (or paste / drop them)", action: pickImage)
            toolButton("face.smiling", help: "Emoji") {
                editorFocused = true
                NSApp.orderFrontCharacterPalette(nil)
            }

            Spacer()

            if draft.hasBeenSent {
                Button("Done") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 8)
                    .help("Move this draft to Posted")
            }

            if !draft.text.isEmpty {
                CharacterRing(count: platform.count(draft.text), limit: platform.limit, accent: skin.accent)
                Rectangle().fill(Palette.border).frame(width: 1, height: 26).padding(.horizontal, 8)
            }

            Button(action: send) {
                Text(draft.sent[platform] != nil ? "Post again" : "Post")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(skin.buttonText)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: skin.buttonCorner).fill(skin.buttonFill))
                    .opacity(draft.isEmpty ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Opens \(platform.name)'s compose box with this text (⌘↵). You press Post there.")
        }
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundColor(skin.accent)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Actions

    private func newDraft() {
        if !draft.isEmpty { store.save(draft) }
        draft = Draft(platforms: [platform])
        status = nil
        editorFocused = true
    }

    private func select(_ item: Draft) {
        if !draft.isEmpty { store.save(draft) }
        draft = item
        if let first = item.platforms.first(where: { item.sent[$0] == nil }) ?? item.platforms.first {
            platform = first
        }
        status = nil
        editorFocused = true
    }

    private func send() {
        guard !draft.isEmpty else { return }
        draft = store.save(draft)
        let message = PostDispatcher.send(draft, to: platform)
        draft = store.markSent(draft, platform: platform)
        status = message + " Switch tabs to post it somewhere else too, or press Done."
    }

    private func finish() {
        store.archive(draft)
        draft = Draft(platforms: [platform])
        status = "Moved to Posted."
        editorFocused = true
    }

    private func addImage(_ image: NSImage) {
        guard let name = store.addImage(image) else { return }
        draft.images.append(name)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let image = NSImage(contentsOf: url) { addImage(image) }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async { addImage(image) }
            }
        }
        return handled
    }
}

// MARK: - Character ring (X style)

/// A ring that fills as you type. Shows the remaining count from 20 left,
/// turns yellow there and red past the limit, the way X's does.
private struct CharacterRing: View {
    let count: Int
    let limit: Int
    let accent: Color

    private var remaining: Int { limit - count }
    private var color: Color {
        remaining < 0 ? Palette.danger : (remaining <= 20 ? Palette.warning : accent)
    }

    var body: some View {
        let showsNumber = remaining <= 20
        ZStack {
            Circle().stroke(Color(white: 0.2), lineWidth: 2)
            if remaining > -10 {
                Circle()
                    .trim(from: 0, to: min(1, Double(count) / Double(limit)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showsNumber {
                Text("\(remaining)")
                    .font(.system(size: 12))
                    .foregroundColor(remaining < 0 ? Palette.danger : Palette.secondary)
            }
        }
        .frame(width: showsNumber ? 30 : 22, height: showsNumber ? 30 : 22)
        .animation(.easeOut(duration: 0.15), value: showsNumber)
        .help("\(count) / \(limit) characters")
    }
}

// MARK: - Window

final class ComposerWindowController: NSObject, NSWindowDelegate {
    static let shared = ComposerWindowController()

    private var panel: NSPanel?
    private var pasteMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible && panel?.isKeyWindow == true {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.title = "New Post"
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .black
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: ComposerView())
            panel.center()
            panel.setFrameAutosaveName("ComposerWindow")
            panel.delegate = self
            self.panel = panel
            installPasteMonitor()
        }

        DraftStore.shared.reload() // pick up edits made in Obsidian
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .composerDidOpen, object: nil)
    }

    /// ⌘V with an image (screenshot or copied image file) adds it to the draft
    /// instead of going to the text editor, which only accepts text.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }

            let pasteboard = NSPasteboard.general
            let imageFiles = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
            ) as? [URL] ?? []

            var images = imageFiles.compactMap { NSImage(contentsOf: $0) }
            if images.isEmpty, pasteboard.string(forType: .string) == nil,
               let image = NSImage(pasteboard: pasteboard) {
                images = [image]
            }
            guard !images.isEmpty else { return event }

            for image in images {
                NotificationCenter.default.post(name: .composerPasteImage, object: image)
            }
            return nil
        }
    }
}
