import Cocoa
import UserNotifications

class BubbleManager {
    static let shared = BubbleManager()

    private var bubbleWindows: [UUID: BubbleWindow] = [:]
    private weak var expandedBubble: BubbleWindow?
    private var hotCornerGlobalMonitor: Any?
    private var hotCornerLocalMonitor: Any?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pinnedSitesChanged),
            name: .pinnedSitesChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bubbleSettingsChanged),
            name: .bubbleSettingsChanged,
            object: nil
        )
    }

    @objc private func pinnedSitesChanged() {
        showBubblesForSites()
    }

    @objc private func bubbleSettingsChanged() {
        repositionAllBubbles()
        refreshAllBubbleContent()
    }

    private func refreshAllBubbleContent() {
        for (_, window) in bubbleWindows {
            window.refreshCollapsedContent()
        }
    }

    func showBubblesForSites() {
        let sites = SettingsStore.shared.pinnedSites
        let bubbleSites = sites.filter { $0.displayMode == .bubble }

        // Remove bubbles for sites that no longer exist or changed to menuBar mode
        let bubbleSiteIds = Set(bubbleSites.map { $0.id })
        let idsToRemove = bubbleWindows.keys.filter { !bubbleSiteIds.contains($0) }
        for id in idsToRemove {
            if let window = bubbleWindows.removeValue(forKey: id) {
                if expandedBubble === window {
                    expandedBubble = nil
                }
                window.prepareForRemoval()
                window.orderOut(nil)
            }
        }

        // Create or update bubbles for bubble-mode sites
        for site in bubbleSites {
            if let existingWindow = bubbleWindows[site.id] {
                existingWindow.updateSite(site)
                if site.hotCorner == nil {
                    existingWindow.orderFront(nil)
                } else if !existingWindow.isExpanded {
                    existingWindow.orderOut(nil)
                }
            } else {
                // Hot corner bubbles stay hidden until triggered
                let bubble = BubbleWindow(site: site)
                bubbleWindows[site.id] = bubble
                if site.hotCorner == nil {
                    bubble.orderFront(nil)
                }
            }
        }

        layoutDock()
        updateHotCornerMonitor()
    }

    // MARK: - Hot Corners

    private func updateHotCornerMonitor() {
        if let monitor = hotCornerGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hotCornerGlobalMonitor = nil
        }
        if let monitor = hotCornerLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hotCornerLocalMonitor = nil
        }

        guard bubbleWindows.values.contains(where: { $0.site.hotCorner != nil }) else { return }

        hotCornerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.checkHotCorners()
        }
        hotCornerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.checkHotCorners()
            return event
        }
    }

    private func checkHotCorners() {
        // ponytail: main screen only; per-screen corners if anyone asks
        guard let screen = NSScreen.main else { return }

        let location = NSEvent.mouseLocation
        let zoneSize: CGFloat = 8

        for window in bubbleWindows.values {
            guard let corner = window.site.hotCorner, !window.isExpanded else { continue }

            let frame = screen.frame
            let x = corner == .bottomLeft ? frame.minX : frame.maxX - zoneSize
            let zone = NSRect(x: x, y: frame.minY, width: zoneSize, height: zoneSize)

            if zone.contains(location) {
                window.expandFromHotCorner()
            }
        }
    }

    private func repositionAllBubbles() {
        layoutDock()
    }

    // MARK: - Dock

    private lazy var dockWindow: BubbleDockWindow = {
        let dock = BubbleDockWindow()
        dock.onGripDrag = { [weak self] mouse in self?.dragDock(to: mouse) }
        dock.onGripDrop = { [weak self] in self?.dropDock() }
        return dock
    }()
    private var dockEdge = SettingsStore.shared.preferredBubbleEdge
    private var dockPosition = CGFloat(SettingsStore.shared.bubbleDockPosition)

    /// Bubbles in the dock, in settings order (hot corner bubbles live in their corner).
    private var dockedBubbles: [BubbleWindow] {
        SettingsStore.shared.pinnedSites.compactMap { site in
            guard site.hotCorner == nil else { return nil }
            return bubbleWindows[site.id]
        }
    }

    private struct DockMetrics {
        let thickness: CGFloat
        let flare: CGFloat
        let gripLength: CGFloat
        let inset: CGFloat
        let length: CGFloat

        init(count: Int) {
            thickness = BubbleWindow.collapsedSize.width
            flare = round(thickness * 1.2)
            gripLength = round(thickness * 0.6)
            // Bubbles start a little way into the end curves
            inset = round(flare * 0.75)
            length = CGFloat(count) * thickness + gripLength + inset * 2
        }
    }

    private func layoutDock() {
        let edge = SettingsStore.shared.preferredBubbleEdge
        layoutDock(edge: edge, position: CGFloat(SettingsStore.shared.bubbleDockPosition))
    }

    /// Places the dock on `edge`, `position` of the way along it, and puts
    /// each bubble in its slot.
    private func layoutDock(edge: BubbleEdge, position: CGFloat) {
        dockEdge = edge
        dockPosition = position
        for bubble in bubbleWindows.values where bubble.site.hotCorner != nil {
            bubble.placeInCorner()
        }
        let bubbles = dockedBubbles
        guard !bubbles.isEmpty, let screen = NSScreen.main else {
            dockWindow.orderOut(nil)
            return
        }

        let m = DockMetrics(count: bubbles.count)
        let visible = screen.visibleFrame
        let frame: NSRect
        if edge.isVertical {
            let y = visible.minY + max(0, visible.height - m.length) * position
            let x = edge == .right ? visible.maxX - m.thickness : visible.minX
            frame = NSRect(x: x, y: y, width: m.thickness, height: m.length)
        } else {
            let x = visible.minX + max(0, visible.width - m.length) * position
            let y = edge == .top ? visible.maxY - m.thickness : visible.minY
            frame = NSRect(x: x, y: y, width: m.length, height: m.thickness)
        }
        let dockFrame = NSIntegralRect(frame)

        // Top to bottom with the grip last when vertical; left to right when horizontal
        let gripRect: NSRect
        if edge.isVertical {
            gripRect = NSRect(x: 0, y: m.inset, width: m.thickness, height: m.gripLength)
        } else {
            gripRect = NSRect(x: m.inset + CGFloat(bubbles.count) * m.thickness, y: 0, width: m.gripLength, height: m.thickness)
        }
        dockWindow.apply(frame: dockFrame, layout: BubbleDockLayout(
            edge: edge, thickness: m.thickness, flare: m.flare, gripRect: gripRect
        ))
        dockWindow.orderFront(nil)

        for (index, bubble) in bubbles.enumerated() {
            let slot: NSRect
            if edge.isVertical {
                let top = dockFrame.maxY - m.inset - CGFloat(index) * m.thickness
                slot = NSRect(x: dockFrame.minX, y: top - m.thickness, width: m.thickness, height: m.thickness)
            } else {
                let left = dockFrame.minX + m.inset + CGFloat(index) * m.thickness
                slot = NSRect(x: left, y: dockFrame.minY, width: m.thickness, height: m.thickness)
            }
            bubble.dock(in: slot, edge: edge)
        }
    }

    /// Follows the mouse, snapping to whichever edge is nearest and keeping
    /// the grip under the pointer.
    private func dragDock(to mouse: NSPoint) {
        guard let screen = NSScreen.main, !dockedBubbles.isEmpty else { return }
        let visible = screen.visibleFrame
        let distances: [(BubbleEdge, CGFloat)] = [
            (.left, abs(mouse.x - visible.minX)),
            (.right, abs(visible.maxX - mouse.x)),
            (.bottom, abs(mouse.y - visible.minY)),
            (.top, abs(visible.maxY - mouse.y)),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0

        let m = DockMetrics(count: dockedBubbles.count)
        let gripCenter: CGFloat
        let along: CGFloat
        let span: CGFloat
        if edge.isVertical {
            gripCenter = m.inset + m.gripLength / 2
            along = mouse.y - visible.minY
            span = visible.height - m.length
        } else {
            gripCenter = m.length - m.inset - m.gripLength / 2
            along = mouse.x - visible.minX
            span = visible.width - m.length
        }
        let position = span > 0 ? max(0, min(1, (along - gripCenter) / span)) : 0.5
        layoutDock(edge: edge, position: position)
    }

    private func dropDock() {
        SettingsStore.shared.setBubbleDock(edge: dockEdge, position: Double(dockPosition))
    }

    func hasPinnedBubble(except bubble: BubbleWindow) -> Bool {
        guard let expanded = expandedBubble, expanded !== bubble else { return false }
        return expanded.isExpanded && expanded.isPinned
    }

    func willExpandBubble(_ bubble: BubbleWindow) {
        // Collapse currently expanded bubble first
        if let expanded = expandedBubble, expanded !== bubble {
            expanded.collapse()
        }
        expandedBubble = bubble
    }

    func expandBubble(for siteId: UUID) {
        bubbleWindows[siteId]?.expand()
    }

    func collapseBubble(for siteId: UUID) {
        bubbleWindows[siteId]?.collapse()
    }

    /// Returns false when the site has no bubble (menu bar sites).
    @discardableResult
    func openCompose(_ url: URL, for siteId: UUID) -> Bool {
        guard let bubble = bubbleWindows[siteId] else { return false }
        bubble.openCompose(url)
        return true
    }

    func toggleBubble(for siteId: UUID) {
        guard let bubble = bubbleWindows[siteId] else { return }

        if bubble.isExpanded {
            bubble.collapse()
        } else {
            bubble.expand()
        }
    }

    func isBubbleExpanded(for siteId: UUID) -> Bool {
        return bubbleWindows[siteId]?.isExpanded ?? false
    }

    // MARK: - Unread notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            badgeLog.notice("notification permission granted=\(granted) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Posts a macOS notification when a bubble's unread count goes up.
    func notifyUnreadRose(site: PinnedSite, count: Int) {
        guard SettingsStore.shared.notifyOnNewUnread else { return }
        let content = UNMutableNotificationContent()
        content.title = site.name
        content.body = count == 1 ? "1 unread notification" : "\(count) unread notifications"
        content.sound = .default
        // One notification per site, replaced as the count changes
        let request = UNNotificationRequest(identifier: "unread-\(site.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                badgeLog.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func bubbleDidCollapse(_ bubble: BubbleWindow) {
        if expandedBubble === bubble {
            expandedBubble = nil
        }
    }
}
