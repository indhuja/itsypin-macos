import Cocoa

/// The grey tab that holds the docked bubbles against a screen edge, with a
/// grip at the end that drags the whole dock to any edge.
///
/// The bubbles are their own windows sitting on top; this window only draws
/// the tab and handles the grip.
class BubbleDockWindow: NSPanel {
    private let dockView = BubbleDockView(frame: .zero)

    /// Called with the mouse location while the grip is dragged, and once more on release.
    var onGripDrag: ((NSPoint) -> Void)?
    var onGripDrop: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One step under the bubbles, so clicking the dock never covers them
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        contentView = dockView

        dockView.grip.onDrag = { [weak self] in self?.onGripDrag?(NSEvent.mouseLocation) }
        dockView.grip.onDrop = { [weak self] in self?.onGripDrop?() }
    }

    override var canBecomeKey: Bool { false }

    func apply(frame: NSRect, layout: BubbleDockLayout) {
        setFrame(frame, display: false)
        dockView.frame = NSRect(origin: .zero, size: frame.size)
        dockView.layout = layout
    }
}

/// Dock geometry, in the dock's own coordinates.
struct BubbleDockLayout {
    var edge: BubbleEdge
    /// Thickness across the edge.
    var thickness: CGFloat
    /// Length of each end's curve, from the screen edge to the straight inner side.
    var flare: CGFloat
    var gripRect: NSRect
}

private class BubbleDockView: NSView {
    let grip = BubbleDockGripView(frame: .zero)

    var layout: BubbleDockLayout? {
        didSet {
            grip.frame = layout?.gripRect ?? .zero
            grip.isVertical = layout?.edge.isVertical ?? true
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(grip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Clicks outside the tab's curves fall through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return grip.frame.contains(local) ? grip : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        NSColor.windowBackgroundColor.setFill()
        tabPath(layout, closed: true).fill()

        // Border on the curves and inner side, not along the screen edge
        let border = tabPath(layout, closed: false)
        border.lineWidth = 1
        NSColor.separatorColor.setStroke()
        border.stroke()
    }

    /// An S-curve leaves the screen edge at each end and turns into the
    /// straight inner side, so the tab looks like it grows out of the edge.
    private func tabPath(_ layout: BubbleDockLayout, closed: Bool) -> NSBezierPath {
        // Half a point in, so the border's inner side isn't clipped by the window
        let t = layout.thickness - 0.5
        let f = layout.flare
        let length = layout.edge.isVertical ? bounds.height : bounds.width

        // u: distance in from the screen edge; v: distance along the edge
        func point(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
            switch layout.edge {
            case .right: return NSPoint(x: bounds.width - u, y: v)
            case .left: return NSPoint(x: u, y: v)
            case .top: return NSPoint(x: v, y: bounds.height - u)
            case .bottom: return NSPoint(x: v, y: u)
            }
        }

        let path = NSBezierPath()
        path.move(to: point(0, 0))
        path.curve(to: point(t, f), controlPoint1: point(0, f * 0.55), controlPoint2: point(t, f * 0.45))
        path.line(to: point(t, length - f))
        path.curve(to: point(0, length), controlPoint1: point(t, length - f * 0.45), controlPoint2: point(0, length - f * 0.55))
        if closed {
            path.close()
        }
        return path
    }
}

/// Six dots, three across the dock and two along it.
private class BubbleDockGripView: NSView {
    var onDrag: (() -> Void)?
    var onDrop: (() -> Void)?
    var isVertical = true {
        didSet { needsDisplay = true }
    }
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to move to any screen edge"
        // Tracking area rather than cursor rects: those only work while the
        // app is active, and Itsypin usually isn't
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseEntered(with event: NSEvent) {
        if !isDragging { NSCursor.openHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { NSCursor.arrow.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let thickness = isVertical ? bounds.width : bounds.height
        let dot = max(3, round(thickness * 0.08))
        // 2pt tighter per gap, so the three-dot side is 4pt shorter
        let pitch = max(dot + 1, round(thickness * 0.18) - 2)

        // Three columns across the dock, two rows along it
        let cols = isVertical ? 3 : 2
        let rows = isVertical ? 2 : 3
        let gridWidth = CGFloat(cols - 1) * pitch
        let gridHeight = CGFloat(rows - 1) * pitch
        let startX = bounds.midX - gridWidth / 2
        let startY = bounds.midY - gridHeight / 2

        NSColor.labelColor.setFill()
        for c in 0..<cols {
            for r in 0..<rows {
                let center = NSPoint(x: startX + CGFloat(c) * pitch, y: startY + CGFloat(r) * pitch)
                NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        // Set on every move: the dock and bubbles slide under the pointer and
        // would otherwise reset it
        NSCursor.closedHand.set()
        onDrag?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let overGrip = bounds.contains(convert(event.locationInWindow, from: nil))
        (overGrip ? NSCursor.openHand : NSCursor.arrow).set()
        onDrop?()
    }
}
