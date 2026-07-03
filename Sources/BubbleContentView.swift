import Cocoa

class BubbleTitleBar: NSView {
    static let height: CGFloat = 28

    private let pinButton: NSButton
    private let mobileButton: NSButton
    var isPinned: Bool = false {
        didSet {
            updatePinButton()
        }
    }
    var isMobileViewOn: Bool = false {
        didSet {
            updateMobileButton()
        }
    }
    var onPinToggle: ((Bool) -> Void)?
    var onUserAgentToggle: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?

    private var isDragging = false
    private var dragStartLocation: NSPoint = .zero
    private var currentBackgroundColor: NSColor = .windowBackgroundColor

    override init(frame: NSRect) {
        pinButton = NSButton(frame: .zero)
        mobileButton = NSButton(frame: .zero)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // Top corners only

        setupPinButton()
        setupMobileButton()
    }

    func updateBackgroundColor(_ color: NSColor) {
        currentBackgroundColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.95).cgColor

        // Adjust button colors for contrast
        let brightness = color.brightnessComponent
        pinButton.contentTintColor = isPinned ? .controlAccentColor : (brightness > 0.5 ? .darkGray : .lightGray)
        mobileButton.contentTintColor = isMobileViewOn ? .controlAccentColor : (brightness > 0.5 ? .darkGray : .lightGray)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupPinButton() {
        pinButton.bezelStyle = .accessoryBarAction
        pinButton.isBordered = false
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pinButton)

        NSLayoutConstraint.activate([
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        updatePinButton()
    }

    private func updatePinButton() {
        let symbolName = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pin")
        let brightness = currentBackgroundColor.brightnessComponent
        pinButton.contentTintColor = isPinned ? .controlAccentColor : (brightness > 0.5 ? .darkGray : .lightGray)
    }

    private func setupMobileButton() {
        mobileButton.bezelStyle = .accessoryBarAction
        mobileButton.isBordered = false
        mobileButton.imagePosition = .imageOnly
        mobileButton.target = self
        mobileButton.action = #selector(mobileTapped)
        mobileButton.toolTip = "Toggle mobile view"
        mobileButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mobileButton)

        NSLayoutConstraint.activate([
            mobileButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -4),
            mobileButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            mobileButton.widthAnchor.constraint(equalToConstant: 24),
            mobileButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        updateMobileButton()
    }

    private func updateMobileButton() {
        mobileButton.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Toggle mobile view")
        let brightness = currentBackgroundColor.brightnessComponent
        mobileButton.contentTintColor = isMobileViewOn ? .controlAccentColor : (brightness > 0.5 ? .darkGray : .lightGray)
    }

    @objc private func pinTapped() {
        isPinned.toggle()
        onPinToggle?(isPinned)
    }

    @objc private func mobileTapped() {
        onUserAgentToggle?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = NSEvent.mouseLocation
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - dragStartLocation.x
        let deltaY = currentLocation.y - dragStartLocation.y
        dragStartLocation = currentLocation
        onDrag?(deltaX, deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

/// Red count badge, like an app icon's, for a collapsed bubble.
class UnreadBadgeView: NSView {
    static let height: CGFloat = 16

    var count = 0 {
        didSet { needsDisplay = true }
    }

    var text: String { count > 99 ? "99+" : "\(count)" }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
    }

    var fittingWidth: CGFloat {
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        return max(Self.height, ceil(textWidth) + 8)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.systemRed.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()

        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

enum FaviconPlacement {
    /// Centred in its dock slot, on the dock's own background.
    case dock
    case corner(HotCorner)
}

class BubbleContentView: NSView {
    private let snapshotImageView: NSImageView
    private let faviconImageView: NSImageView
    private let webViewContainer: NSView
    private(set) var titleBar: BubbleTitleBar?
    private let badgeView = UnreadBadgeView(frame: .zero)
    /// Holds the page while collapsed: in the window and not hidden, so WebKit
    /// keeps it running (badge counts, live updates), but outside the bubble's
    /// bounds so it never draws or takes clicks.
    private let parkingView = NSView(frame: .zero)
    private var badgeCount = 0

    /// Where the icon sits when the bubble background is hidden.
    var faviconPlacement: FaviconPlacement = .dock

    override init(frame: NSRect) {
        snapshotImageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        snapshotImageView.imageScaling = .scaleProportionallyUpOrDown
        snapshotImageView.autoresizingMask = [.width, .height]

        // Favicon is centered and fixed size
        let faviconSize: CGFloat = 32
        faviconImageView = NSImageView(frame: NSRect(
            x: (frame.width - faviconSize) / 2,
            y: (frame.height - faviconSize) / 2,
            width: faviconSize,
            height: faviconSize
        ))
        faviconImageView.imageScaling = .scaleProportionallyUpOrDown
        faviconImageView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        faviconImageView.wantsLayer = true
        faviconImageView.layer?.cornerRadius = faviconSize * 0.25
        faviconImageView.layer?.masksToBounds = true

        webViewContainer = NSView(frame: NSRect(origin: .zero, size: frame.size))
        webViewContainer.autoresizingMask = [.width, .height]

        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addSubview(parkingView)
        addSubview(snapshotImageView)
        addSubview(faviconImageView)
        addSubview(webViewContainer)
        addSubview(badgeView)

        badgeView.isHidden = true
        snapshotImageView.isHidden = true
        faviconImageView.isHidden = true
        webViewContainer.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // When collapsed (webViewContainer hidden), return self to handle mouse events
        // This prevents image views from intercepting clicks
        if webViewContainer.isHidden {
            return bounds.contains(point) ? self : nil
        }
        return super.hitTest(point)
    }

    func showSnapshot(_ image: NSImage?) {
        snapshotImageView.image = image
        snapshotImageView.isHidden = false
        faviconImageView.isHidden = true
        webViewContainer.isHidden = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hideTitleBar()
        layoutBadge()
    }

    func showFavicon(_ image: NSImage?) {
        faviconImageView.image = image
        faviconImageView.frame = faviconFrame()
        faviconImageView.isHidden = false
        snapshotImageView.isHidden = true
        webViewContainer.isHidden = true
        if case .corner = faviconPlacement, SettingsStore.shared.showBubbleBackground {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            // Visually transparent, but not alpha 0 — the window server treats
            // fully transparent pixels as click-through
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01).cgColor
        }
        hideTitleBar()
        layoutBadge()
    }

    /// Shows a count badge while collapsed; 0 hides it.
    func setBadge(_ count: Int) {
        badgeCount = count
        layoutBadge()
    }

    private func layoutBadge() {
        guard badgeCount > 0, webViewContainer.isHidden else {
            badgeView.isHidden = true
            return
        }
        badgeView.count = badgeCount
        let size = NSSize(width: badgeView.fittingWidth, height: UnreadBadgeView.height)

        // Overlap the icon's top-right corner, inset enough that the
        // bubble's rounded-corner clip doesn't cut the badge
        let inset: CGFloat = 2
        let anchor = faviconImageView.isHidden ? bounds : faviconImageView.frame
        let x = min(bounds.maxX - size.width - inset, anchor.maxX - size.width * 0.75)
        let y = min(bounds.maxY - size.height - inset, anchor.maxY - size.height * 0.75)
        badgeView.frame = NSIntegralRect(NSRect(origin: NSPoint(x: max(0, x), y: max(0, y)), size: size))
        badgeView.isHidden = false
        badgeView.needsDisplay = true
        addSubview(badgeView, positioned: .above, relativeTo: nil)
    }

    private func faviconFrame() -> NSRect {
        // The icon fills most of its slot, as in the dock
        let side = round(min(bounds.width, bounds.height) * 0.6)
        let size = NSSize(width: side, height: side)
        faviconImageView.layer?.cornerRadius = side * 0.22
        var origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)

        // With no visible background, sit flush against the screen edge
        if !SettingsStore.shared.showBubbleBackground {
            switch faviconPlacement {
            case .dock:
                break
            case .corner(.bottomLeft):
                origin = .zero
            case .corner(.bottomRight):
                origin = NSPoint(x: bounds.width - size.width, y: 0)
            }
        }

        return NSRect(origin: origin, size: size)
    }

    func showWebView(_ webView: NSView) {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        showTitleBar()

        // Update container to leave room for title bar (use integral rect to avoid subpixel gaps)
        let titleHeight = BubbleTitleBar.height
        webViewContainer.frame = NSIntegralRect(NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - titleHeight
        ))

        webView.frame = webViewContainer.bounds
        webView.autoresizingMask = [.width, .height]

        webViewContainer.subviews.forEach { $0.removeFromSuperview() }
        webViewContainer.addSubview(webView)

        snapshotImageView.isHidden = true
        faviconImageView.isHidden = true
        webViewContainer.isHidden = false
        badgeView.isHidden = true
    }

    private func showTitleBar() {
        if titleBar == nil {
            let titleHeight = BubbleTitleBar.height
            let bar = BubbleTitleBar(frame: NSRect(
                x: 0,
                y: bounds.height - titleHeight,
                width: bounds.width,
                height: titleHeight
            ))
            bar.autoresizingMask = [.width, .minYMargin]
            addSubview(bar)
            titleBar = bar
        }
        titleBar?.isHidden = false
    }

    private func hideTitleBar() {
        titleBar?.isHidden = true
    }

    /// Keeps a collapsed bubble's page alive; see `parkingView`.
    func parkWebView(_ webView: NSView, size: NSSize) {
        parkingView.frame = NSRect(x: bounds.maxX + 10, y: 0, width: size.width, height: size.height)
        webView.frame = parkingView.bounds
        webView.autoresizingMask = [.width, .height]
        parkingView.subviews.filter { $0 !== webView }.forEach { $0.removeFromSuperview() }
        if webView.superview !== parkingView {
            parkingView.addSubview(webView)
        }
    }

    func getWebViewContainer() -> NSView {
        return webViewContainer
    }
}
