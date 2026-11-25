import Cocoa
import WebKit
import os

let composeLog = Logger(subsystem: "com.itsypin.app", category: "compose")

class BubbleWindow: NSPanel {
    static var collapsedSize: NSSize {
        let side = SettingsStore.shared.bubbleSize
        return NSSize(width: side, height: side)
    }
    static let expandedSize = NSSize(width: 420, height: 650)
    private static let hoverDelay: TimeInterval = 0.4
    private static let animationDuration: TimeInterval = 0.2
    private static let dragThreshold: CGFloat = 5

    private(set) var site: PinnedSite
    private(set) var isExpanded = false
    private(set) var isPinned = false
    /// Pinned by the app (typing, file picker, compose link) rather than by the user's pin button.
    private var isAutoPinned = false
    private var wakeObserver: NSObjectProtocol?
    private var idleUnpinTimer: Timer?
    /// An auto-pin lets go after this long without typing. Collapsing is safe:
    /// the page stays loaded, so a half-written post is still there next hover.
    private static let idleUnpinDelay: TimeInterval = 120
    private var isAnimating = false
    /// The bubble's slot in the dock, and the edge the dock is on.
    private var dockedFrame: NSRect?
    private var dockEdge: BubbleEdge = .right
    private var snapshotImage: NSImage?
    private var faviconImage: NSImage?
    private var webViewController: WebViewController?
    private var hoverTimer: Timer?
    private var bubbleContentView: BubbleContentView!
    private var trackingArea: NSTrackingArea?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dragMonitor: Any?
    private var keyMonitor: Any?
    private var collapseTimer: Timer?
    private var unloadTimer: Timer?
    private var resizeHandles: [ResizeHandleView] = []
    private var previewWebView: WKWebView?

    private var mouseDownLocation: NSPoint = .zero
    private var isDragging = false
    private var dragStartOrigin: NSPoint = .zero
    private var expandedWidth: CGFloat?
    /// The page's latest unread count, and the count when the bubble was last
    /// opened; the badge shows only once the count rises past what was seen.
    private var unreadCount = 0
    private var seenUnreadCount = 0
    private var hasUnreadReading = false
    private var expandedHeight: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        // When window becomes key, focus the webview
        if isExpanded, let webView = webViewController?.getWebView() {
            makeFirstResponder(webView)
        }
    }

    init(site: PinnedSite) {
        self.site = site

        super.init(
            contentRect: NSRect(origin: .zero, size: BubbleWindow.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Load saved window size
        if let savedWidth = site.windowWidth {
            expandedWidth = savedWidth
        }
        if let savedHeight = site.windowHeight {
            expandedHeight = savedHeight
        }

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        bubbleContentView = BubbleContentView(frame: NSRect(origin: .zero, size: BubbleWindow.collapsedSize))
        contentView = bubbleContentView

        setupTrackingArea()
        loadInitialContent()
        preloadPage()

        // Pages can go stale or log out over sleep; refresh collapsed bubbles
        // on wake so the next hover shows a ready page instead of a spinner
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isExpanded else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !self.isExpanded else { return }
                self.webViewController?.reloadIfIdle()
            }
        }
    }

    /// Loads the site off-screen at launch so the first hover never shows a loading page.
    private func preloadPage() {
        ensureWebViewController()
        webViewController?.loadSite(site)
        parkWebView()
    }

    /// Collapsed pages stay in the window so WebKit doesn't suspend them.
    private func parkWebView() {
        guard !isExpanded, let view = webViewController?.view else { return }
        bubbleContentView.parkWebView(view, size: currentExpandedSize)
    }

    private func ensureWebViewController() {
        guard webViewController == nil else { return }
        let controller = WebViewController()
        controller.onThemeColorDetected = { [weak self] color in
            self?.bubbleContentView.titleBar?.updateBackgroundColor(color)
        }
        controller.onFaviconLoaded = { [weak self] icon in
            guard let self, self.site.customIcon == nil, let icon else { return }
            // The page's own favicon is more reliable than URL guessing
            icon.size = NSSize(width: 32, height: 32)
            self.faviconImage = icon
        }
        controller.onComposeStateChanged = { [weak self] composing in
            self?.setComposing(composing)
        }
        controller.onFilePickerOpened = { [weak self] in
            self?.setComposing(true)
        }
        controller.onUnreadCountChanged = { [weak self] count in
            self?.setUnreadCount(count)
        }
        webViewController = controller
    }

    // MARK: - Unread badge

    private func setUnreadCount(_ count: Int) {
        let previous = unreadCount
        unreadCount = count
        // Read elsewhere (or on the page) — don't wait for it to climb back
        seenUnreadCount = min(seenUnreadCount, count)
        if isExpanded { seenUnreadCount = count }
        badgeLog.notice("\(self.site.name, privacy: .public) unread=\(count) seen=\(self.seenUnreadCount) expanded=\(self.isExpanded)")
        updateBadge()
        // The first reading after launch is old news, not something new
        defer { hasUnreadReading = true }
        if hasUnreadReading, count > previous, !isExpanded, SettingsStore.shared.showUnreadBadges {
            BubbleManager.shared.notifyUnreadRose(site: site, count: count)
        }
    }

    private func updateBadge() {
        let show = SettingsStore.shared.showUnreadBadges && !isExpanded && unreadCount > seenUnreadCount
        bubbleContentView.setBadge(show ? unreadCount : 0)
    }

    // MARK: - Auto-pin

    /// Keeps the bubble open while something is being written or uploaded.
    /// Only releases a pin the app set itself; a pin from the pin button stays.
    func setComposing(_ composing: Bool) {
        composeLog.notice("\(self.site.name, privacy: .public) composing=\(composing) expanded=\(self.isExpanded) pinned=\(self.isPinned) auto=\(self.isAutoPinned)")
        if composing {
            guard isExpanded else { return }
            if isAutoPinned { armIdleUnpin() }
            guard !isPinned else { return }
            isPinned = true
            isAutoPinned = true
            armIdleUnpin()
        } else {
            releaseAutoPin()
            return
        }
        bubbleContentView.titleBar?.isPinned = isPinned
    }

    private func armIdleUnpin() {
        idleUnpinTimer?.invalidate()
        idleUnpinTimer = Timer.scheduledTimer(withTimeInterval: Self.idleUnpinDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            composeLog.notice("\(self.site.name, privacy: .public) idle, releasing auto-pin")
            self.releaseAutoPin()
        }
    }

    /// Drops a pin the app set (never one from the pin button), then collapses
    /// right away if the mouse has already left.
    private func releaseAutoPin() {
        idleUnpinTimer?.invalidate()
        idleUnpinTimer = nil
        guard isAutoPinned else { return }
        isPinned = false
        isAutoPinned = false
        bubbleContentView.titleBar?.isPinned = false
        checkMousePosition()
    }

    /// Opens a compose link (from the composer) in this bubble and keeps it open.
    func openCompose(_ url: URL) {
        orderFront(nil)
        if isExpanded {
            webViewController?.load(url)
            setComposing(true)
            activateAndFocus()
            return
        }
        expand()
        webViewController?.load(url)
        // Pin before the mouse check starts, since the cursor is over the composer
        isPinned = true
        isAutoPinned = true
        armIdleUnpin()
    }

    private func loadInitialContent() {
        // Always fetch favicon (used as fallback and for favicon mode)
        fetchFavicon()

        if SettingsStore.shared.showBubblePreviews {
            // Also load page in hidden webview to capture snapshot
            loadPreviewSnapshot()
        }
    }

    private func loadPreviewSnapshot() {
        guard let url = URL(string: site.url) else { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 650), configuration: config)
        webView.customUserAgent = site.userAgent
        previewWebView = webView

        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    private func fetchFavicon() {
        if let data = site.customIcon, let image = NSImage(data: data) {
            image.size = NSSize(width: 32, height: 32)
            applyFavicon(image)
            return
        }

        guard let url = URL(string: site.url),
              let host = url.host else { return }

        let scheme = url.scheme ?? "https"

        // Try common favicon locations
        let faviconURLs = [
            URL(string: "\(scheme)://\(host)/favicon.ico"),
            URL(string: "\(scheme)://\(host)/apple-touch-icon.png"),
            URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
        ].compactMap { $0 }

        FaviconLoader.fetch(from: faviconURLs, size: 32) { [weak self] image in
            guard let self else { return }
            // Never leave the bubble blank — fall back to the site's initial letter
            self.applyFavicon(image ?? self.letterFallbackIcon())
        }
    }

    private func applyFavicon(_ image: NSImage) {
        faviconImage = image
        if !isExpanded && !SettingsStore.shared.showBubblePreviews {
            bubbleContentView.showFavicon(image)
        }
    }

    private func letterFallbackIcon() -> NSImage {
        let letter = site.name.first.map(String.init)?.uppercased() ?? "?"
        let size = NSSize(width: 32, height: 32)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let string = NSAttributedString(string: letter, attributes: attributes)
            let stringSize = string.size()
            string.draw(at: NSPoint(x: rect.midX - stringSize.width / 2, y: rect.midY - stringSize.height / 2))
            return true
        }
    }

    /// Applies edits made in settings without recreating the window.
    func updateSite(_ newSite: PinnedSite) {
        let needsReload = newSite.url != site.url
            || newSite.useMobileUserAgent != site.useMobileUserAgent
            || newSite.customIcon != site.customIcon
        site = newSite
        guard needsReload else { return }

        snapshotImage = nil
        faviconImage = nil
        fetchFavicon()
        if isExpanded {
            webViewController?.loadSite(site)
        } else {
            webViewController = nil
            preloadPage()
        }
    }

    deinit {
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()
        unloadTimer?.invalidate()
        idleUnpinTimer?.invalidate()
        stopMonitors()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private var currentExpandedSize: NSSize {
        NSSize(
            width: expandedWidth ?? BubbleWindow.expandedSize.width,
            height: expandedHeight ?? BubbleWindow.expandedSize.height
        )
    }

    private func setupResizeHandles() {
        guard resizeHandles.isEmpty else { return }

        let handleSize: CGFloat = 16
        let bounds = bubbleContentView.bounds

        // Corner positions: bottomLeft, bottomRight, topLeft, topRight
        let corners: [(NSRect, NSView.AutoresizingMask, ResizeCorner)] = [
            // Bottom-left
            (NSRect(x: 0, y: 0, width: handleSize, height: handleSize),
             [.maxXMargin, .maxYMargin], .bottomLeft),
            // Bottom-right
            (NSRect(x: bounds.width - handleSize, y: 0, width: handleSize, height: handleSize),
             [.minXMargin, .maxYMargin], .bottomRight),
            // Top-left
            (NSRect(x: 0, y: bounds.height - handleSize, width: handleSize, height: handleSize),
             [.maxXMargin, .minYMargin], .topLeft),
            // Top-right
            (NSRect(x: bounds.width - handleSize, y: bounds.height - handleSize, width: handleSize, height: handleSize),
             [.minXMargin, .minYMargin], .topRight),
        ]

        for (frame, mask, corner) in corners {
            let handle = ResizeHandleView(frame: frame)
            handle.autoresizingMask = mask
            handle.corner = corner
            handle.onResizeWithCorner = { [weak self] deltaX, deltaY, corner in
                self?.handleResizeFromCorner(deltaX: deltaX, deltaY: deltaY, corner: corner)
            }
            handle.getCurrentSize = { [weak self] in
                self?.frame.size ?? BubbleWindow.expandedSize
            }
            bubbleContentView.addSubview(handle, positioned: .above, relativeTo: nil)
            resizeHandles.append(handle)
        }
    }

    private func removeResizeHandles() {
        resizeHandles.forEach { $0.removeFromSuperview() }
        resizeHandles.removeAll()
    }

    private func handleResizeFromCorner(deltaX: CGFloat, deltaY: CGFloat, corner: ResizeCorner) {
        guard isExpanded, let screen = NSScreen.main else { return }

        let minSize = NSSize(width: 320, height: 400)
        let maxSize = NSSize(width: screen.visibleFrame.width * 0.8, height: screen.visibleFrame.height * 0.9)

        let currentWidth = frame.width
        let currentHeight = frame.height
        var newOrigin = frame.origin

        var newWidth = currentWidth
        var newHeight = currentHeight

        // Apply deltas based on which corner - opposite corner stays fixed
        switch corner {
        case .bottomLeft:
            // Top-right stays fixed
            newWidth = currentWidth - deltaX
            newHeight = currentHeight - deltaY
            newOrigin.x = frame.maxX - max(minSize.width, min(maxSize.width, newWidth))
            newOrigin.y = frame.maxY - max(minSize.height, min(maxSize.height, newHeight))
        case .bottomRight:
            // Top-left stays fixed
            newWidth = currentWidth + deltaX
            newHeight = currentHeight - deltaY
            newOrigin.y = frame.maxY - max(minSize.height, min(maxSize.height, newHeight))
        case .topLeft:
            // Bottom-right stays fixed
            newWidth = currentWidth - deltaX
            newHeight = currentHeight + deltaY
            newOrigin.x = frame.maxX - max(minSize.width, min(maxSize.width, newWidth))
        case .topRight:
            // Bottom-left stays fixed (origin stays same)
            newWidth = currentWidth + deltaX
            newHeight = currentHeight + deltaY
        }

        // Clamp to min/max and round to avoid subpixel gaps
        let clampedWidth = round(max(minSize.width, min(maxSize.width, newWidth)))
        let clampedHeight = round(max(minSize.height, min(maxSize.height, newHeight)))

        expandedWidth = clampedWidth
        expandedHeight = clampedHeight

        let newFrame = NSIntegralRect(NSRect(origin: newOrigin, size: NSSize(width: clampedWidth, height: clampedHeight)))
        setFrame(newFrame, display: true)

        bubbleContentView.frame = NSIntegralRect(NSRect(origin: .zero, size: NSSize(width: clampedWidth, height: clampedHeight)))

        // Save size for persistence
        SettingsStore.shared.updateSiteSize(id: site.id, size: NSSize(width: clampedWidth, height: clampedHeight))
    }

    private func setupTrackingArea() {
        if let existing = trackingArea {
            bubbleContentView.removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bubbleContentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        bubbleContentView.addTrackingArea(trackingArea!)
    }

    private func startMonitors() {
        stopMonitors()

        // Global monitor for mouse position check (when app not focused)
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { [weak self] _ in
            self?.checkMousePosition()
        }

        // Local monitor for mouse position check and Option+drag (when app focused)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .mouseMoved {
                self.checkMousePosition()
            } else if event.type == .leftMouseDown && event.modifierFlags.contains(.option) {
                self.mouseDownLocation = NSEvent.mouseLocation
                self.dragStartOrigin = self.frame.origin
                self.isDragging = false
            } else if event.type == .leftMouseDragged && event.modifierFlags.contains(.option) {
                let currentLocation = NSEvent.mouseLocation
                let distance = hypot(currentLocation.x - self.mouseDownLocation.x, currentLocation.y - self.mouseDownLocation.y)
                if !self.isDragging && distance > BubbleWindow.dragThreshold {
                    self.isDragging = true
                }
                if self.isDragging {
                    self.handleDrag()
                    return nil // Consume the event
                }
            } else if event.type == .leftMouseUp && self.isDragging {
                self.finishDrag()
            }

            return event
        }

        // Typing anything in the expanded bubble pins it. This works on every
        // site, including ones whose compose box the page script can't see.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isExpanded else { return event }
            composeLog.debug("key in \(self.site.name, privacy: .public): sameWindow=\(event.window === self) key=\(self.isKeyWindow) appActive=\(NSApp.isActive)")
            guard event.window === self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isEscape = event.keyCode == 53
            let isShortcut = flags.contains(.command) && event.charactersIgnoringModifiers != "v"
            if !isEscape && !isShortcut {
                self.setComposing(true)
            }
            return event
        }
    }

    private func stopMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    private func checkMousePosition() {
        guard isExpanded && !isAnimating && !isDragging && !isPinned else {
            collapseTimer?.invalidate()
            collapseTimer = nil
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let expandedFrame = frame.insetBy(dx: -10, dy: -10)

        if !expandedFrame.contains(mouseLocation) {
            // Start collapse timer if not already running
            if collapseTimer == nil {
                collapseTimer = Timer.scheduledTimer(withTimeInterval: BubbleWindow.hoverDelay, repeats: false) { [weak self] _ in
                    self?.collapseTimer = nil
                    // Double-check mouse is still outside and not pinned
                    guard let self = self, !self.isPinned else { return }
                    let currentMouse = NSEvent.mouseLocation
                    if !self.frame.insetBy(dx: -10, dy: -10).contains(currentMouse) {
                        self.collapse()
                    }
                }
            }
        } else {
            // Mouse is inside, cancel any pending collapse
            collapseTimer?.invalidate()
            collapseTimer = nil
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isExpanded && !isDragging && !isAnimating else { return }
        // Passing over this bubble (say, on the way to a file picker) must not
        // collapse a bubble that's pinned open mid-post
        guard !BubbleManager.shared.hasPinnedBubble(except: self) else { return }

        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: BubbleWindow.hoverDelay, repeats: false) { [weak self] _ in
            guard let self = self, !self.isDragging else { return }
            self.expand()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil

        mouseDownLocation = NSEvent.mouseLocation
        dragStartOrigin = frame.origin

        // Check if Option key is held for dragging expanded window
        let optionHeld = event.modifierFlags.contains(.option)

        // Ensure the window becomes key and the webview can accept typing on click
        if isExpanded && !optionHeld {
            activateAndFocus()
        }

        if !isExpanded || optionHeld {
            isDragging = false // Will be set true on actual drag
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)

        // Collapsed bubbles move with the dock's grip; expanded ones move with Option
        guard isExpanded && optionHeld else { return }

        let currentLocation = NSEvent.mouseLocation
        let distance = hypot(currentLocation.x - mouseDownLocation.x, currentLocation.y - mouseDownLocation.y)

        if !isDragging && distance > BubbleWindow.dragThreshold {
            isDragging = true
        }

        if isDragging {
            handleDrag()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            finishDrag()
        }
    }

    /// Option-drag moves an expanded bubble freely, like its title bar; it
    /// returns to its dock slot when it collapses.
    private func handleDrag() {
        let currentLocation = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + currentLocation.x - mouseDownLocation.x,
            y: dragStartOrigin.y + currentLocation.y - mouseDownLocation.y
        ))
    }

    private func finishDrag() {
        isDragging = false
    }

    func expandFromHotCorner() {
        guard !isExpanded && !isAnimating else { return }
        orderFront(nil)
        expand()
    }

    func expand() {
        guard !isExpanded && !isAnimating else { return }

        unloadTimer?.invalidate()
        unloadTimer = nil

        BubbleManager.shared.willExpandBubble(self)

        seenUnreadCount = unreadCount
        updateBadge()

        ensureWebViewController()
        webViewController?.loadSite(site)

        isExpanded = true
        isAnimating = true
        hasShadow = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = BubbleWindow.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let expandedFrame = calculateExpandedFrame()
            self.animator().setFrame(expandedFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false

            self.bubbleContentView.frame = NSRect(origin: .zero, size: self.currentExpandedSize)

            if let webView = self.webViewController?.view {
                self.bubbleContentView.showWebView(webView)
            }

            self.setupTitleBarCallbacks()
            self.setupResizeHandles()
            self.startMonitors()
            self.activateAndFocus()
        }
    }

    private func setupTitleBarCallbacks() {
        guard let titleBar = bubbleContentView.titleBar else { return }

        titleBar.isPinned = isPinned
        titleBar.isMobileViewOn = site.useMobileUserAgent

        titleBar.onPinToggle = { [weak self] pinned in
            self?.isPinned = pinned
            self?.isAutoPinned = false
            self?.idleUnpinTimer?.invalidate()
        }

        titleBar.onUserAgentToggle = { [weak self] in
            guard let self else { return }
            self.site.useMobileUserAgent.toggle()
            SettingsStore.shared.updateSiteUserAgent(id: self.site.id, useMobile: self.site.useMobileUserAgent)
            self.webViewController?.loadSite(self.site)
            self.bubbleContentView.titleBar?.isMobileViewOn = self.site.useMobileUserAgent
        }

        titleBar.onDrag = { [weak self] deltaX, deltaY in
            guard let self = self else { return }
            var newOrigin = self.frame.origin
            newOrigin.x += deltaX
            newOrigin.y += deltaY
            self.setFrameOrigin(newOrigin)
        }
    }

    private func activateAndFocus() {
        // Activate app and make window key (the app is LSUIElement, so no dock icon appears)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        // Focus webview
        if let webView = webViewController?.getWebView() {
            makeFirstResponder(webView)
            _ = webView.becomeFirstResponder()

            // Use JavaScript to ensure document has focus
            webView.evaluateJavaScript("document.body.focus(); window.focus();", completionHandler: nil)
        }

        // Retry with delays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isExpanded else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            if let webView = self.webViewController?.getWebView() {
                self.makeFirstResponder(webView)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isExpanded else { return }
            if let webView = self.webViewController?.getWebView() {
                self.makeFirstResponder(webView)
                // Try clicking on first input if exists
                webView.evaluateJavaScript("""
                    var input = document.querySelector('input:not([type=hidden]), textarea');
                    if (input) input.focus();
                """, completionHandler: nil)
            }
        }
    }

    func collapse() {
        guard isExpanded && !isAnimating else { return }

        isAnimating = true
        collapseTimer?.invalidate()
        collapseTimer = nil
        stopMonitors()
        removeResizeHandles()

        takeSnapshot { [weak self] in
            self?.performCollapse()
        }
    }

    private func takeSnapshot(completion: @escaping () -> Void) {
        guard let webView = webViewController?.getWebView() else {
            completion()
            return
        }

        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image = image {
                self?.snapshotImage = image
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func performCollapse() {
        isExpanded = false
        isPinned = false
        isAutoPinned = false
        idleUnpinTimer?.invalidate()
        idleUnpinTimer = nil

        // Shrink the content first so the favicon frame is computed against
        // collapsed bounds, not the still-expanded ones
        bubbleContentView.frame = NSRect(origin: .zero, size: BubbleWindow.collapsedSize)
        if SettingsStore.shared.showBubblePreviews {
            bubbleContentView.showSnapshot(snapshotImage)
        } else {
            bubbleContentView.showFavicon(faviconImage ?? letterFallbackIcon())
        }
        parkWebView()
        updateBadge()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = BubbleWindow.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let collapsedFrame = calculateCollapsedFrame()
            self.animator().setFrame(collapsedFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isAnimating = false
            // Docked bubbles sit flat on the dock
            self.hasShadow = self.site.hotCorner != nil
            if self.site.hotCorner != nil {
                self.orderOut(nil)
            }
            self.scheduleUnloadIfNeeded()
            BubbleManager.shared.bubbleDidCollapse(self)
        }
    }

    private func scheduleUnloadIfNeeded() {
        unloadTimer?.invalidate()
        let minutes = SettingsStore.shared.bubbleUnloadMinutes
        // Badges read the loaded page, so it has to stay loaded
        guard minutes > 0, !SettingsStore.shared.showUnreadBadges else { return }
        unloadTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            guard let self, !self.isExpanded else { return }
            self.webViewController?.view.removeFromSuperview()
            self.webViewController = nil
        }
    }

    /// Puts the bubble in its dock slot. An expanded bubble stays where it
    /// is and goes to the new slot when it collapses.
    func dock(in slot: NSRect, edge: BubbleEdge) {
        dockedFrame = slot
        dockEdge = edge
        bubbleContentView.faviconPlacement = .dock
        hasShadow = false
        guard !isExpanded, !isAnimating else { return }
        setFrame(slot, display: true)
        // Keep content in sync when the bubble size setting changes
        bubbleContentView.frame = NSRect(origin: .zero, size: slot.size)
        refreshFaviconLayout()
    }

    /// Hot corner bubbles sit in their corner instead of the dock.
    func placeInCorner() {
        guard let corner = site.hotCorner else { return }
        dockedFrame = nil
        bubbleContentView.faviconPlacement = .corner(corner)
        hasShadow = true
        guard !isExpanded, !isAnimating else { return }
        let newFrame = calculateCollapsedFrame()
        setFrame(newFrame, display: true)
        bubbleContentView.frame = NSRect(origin: .zero, size: newFrame.size)
        refreshFaviconLayout()
    }

    private func refreshFaviconLayout() {
        guard !SettingsStore.shared.showBubblePreviews else { return }
        bubbleContentView.showFavicon(faviconImage ?? letterFallbackIcon())
    }

    private func cornerFrame(size: NSSize, corner: HotCorner, visibleFrame: NSRect) -> NSRect {
        let x = corner == .bottomLeft ? visibleFrame.minX : visibleFrame.maxX - size.width
        return NSIntegralRect(NSRect(x: x, y: visibleFrame.minY, width: size.width, height: size.height))
    }

    private func calculateCollapsedFrame() -> NSRect {
        let size = BubbleWindow.collapsedSize
        if let corner = site.hotCorner, let screen = NSScreen.main {
            return cornerFrame(size: size, corner: corner, visibleFrame: screen.visibleFrame)
        }
        return dockedFrame ?? NSRect(origin: frame.origin, size: size)
    }

    /// Opens flush against the dock's edge, centred on the bubble's slot.
    private func calculateExpandedFrame() -> NSRect {
        let size = currentExpandedSize
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame

        if let corner = site.hotCorner {
            return cornerFrame(size: size, corner: corner, visibleFrame: visible)
        }

        let anchor = dockedFrame ?? frame
        var origin = NSPoint.zero
        switch dockEdge {
        case .right: origin.x = visible.maxX - size.width
        case .left: origin.x = visible.minX
        case .top: origin.y = visible.maxY - size.height
        case .bottom: origin.y = visible.minY
        }
        if dockEdge.isVertical {
            origin.y = max(visible.minY, min(anchor.midY - size.height / 2, visible.maxY - size.height))
        } else {
            origin.x = max(visible.minX, min(anchor.midX - size.width / 2, visible.maxX - size.width))
        }

        return NSIntegralRect(NSRect(origin: origin, size: size))
    }

    func prepareForRemoval() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        unloadTimer?.invalidate()
        unloadTimer = nil
        stopMonitors()
        removeResizeHandles()
        webViewController?.view.removeFromSuperview()
        webViewController = nil
        previewWebView = nil
    }

    func refreshCollapsedContent() {
        guard !isExpanded else { return }
        defer { updateBadge() }
        // Turning badges on brings back a page that was unloaded to save memory
        if SettingsStore.shared.showUnreadBadges, webViewController == nil {
            preloadPage()
        }

        if SettingsStore.shared.showBubblePreviews {
            if let snapshot = snapshotImage {
                bubbleContentView.showSnapshot(snapshot)
            } else {
                // No snapshot yet, load one
                loadPreviewSnapshot()
            }
        } else {
            if let favicon = faviconImage {
                bubbleContentView.showFavicon(favicon)
            } else {
                // No favicon yet, fetch one
                fetchFavicon()
            }
        }
    }
}

// MARK: - WKNavigationDelegate for initial preview capture

extension BubbleWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only handle preview webview loading
        guard webView === previewWebView else { return }

        // Wait a moment for page to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureInitialSnapshot()
        }
    }

    private func captureInitialSnapshot() {
        guard let webView = previewWebView else { return }

        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self = self else { return }

            if let image = image {
                self.snapshotImage = image
                // Update display if not expanded
                if !self.isExpanded && SettingsStore.shared.showBubblePreviews {
                    self.bubbleContentView.showSnapshot(image)
                }
            }

            // Clean up preview webview
            self.previewWebView = nil
        }
    }
}
