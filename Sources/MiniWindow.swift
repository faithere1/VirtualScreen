import AppKit
import ScreenCaptureKit

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One live, always-on-top view of a window region. Closes only with its ✕.
final class MiniScreen: NSObject, NSWindowDelegate {
    let bundleID: String
    let title: String
    let crop: CGRect
    let panel: MiniPanel
    private let view: MiniView
    private let bar: TopBar
    private let capture: CaptureStream
    private var hiddenWork: DispatchWorkItem?

    var onClose: ((MiniScreen) -> Void)?
    var onChange: (() -> Void)?

    var saved: SavedMini {
        SavedMini(bundleID: bundleID, title: title, crop: crop, frame: panel.frame)
    }

    init(window: SCWindow, crop: CGRect, frame: CGRect?, fps: Int, cascade: Int) {
        let app = window.owningApplication
        let pid = app?.processID ?? 0
        let appName = app?.applicationName ?? "Window"
        bundleID = app?.bundleIdentifier ?? ""
        title = window.title ?? ""
        self.crop = crop

        let rect = frame ?? MiniScreen.defaultFrame(for: crop.size, cascade: cascade)
        panel = MiniPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        bar = TopBar(title: title.isEmpty ? appName : "\(appName) — \(title)",
                     icon: NSRunningApplication(processIdentifier: pid)?.icon)
        view = MiniView(frame: CGRect(origin: .zero, size: rect.size), bar: bar)
        capture = CaptureStream(filter: SCContentFilter(desktopIndependentWindow: window), crop: crop,
                                layer: view.videoLayer,
                                pixelSize: MiniScreen.pixelSize(rect.size, scale: panel.backingScaleFactor, crop: crop),
                                fps: fps)
        super.init()

        panel.isFloatingPanel = true  // resets the level, so set it first
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.delegate = self

        view.aspect = crop.width / crop.height
        view.onResized = { [weak self] in self?.sizeChanged() }
        bar.closeButton.target = self
        bar.closeButton.action = #selector(closeClicked)
        capture.onStop = { [weak self] _ in self?.view.showStatus("Source window closed") }

        panel.orderFrontRegardless()
        capture.start()
    }

    func setFPS(_ fps: Int) {
        capture.setFPS(fps)
    }

    func close() {
        hiddenWork?.cancel()
        capture.stop()
        panel.orderOut(nil)
        panel.close()
        onClose?(self)
        onClose = nil
    }

    @objc private func closeClicked() {
        close()
    }

    private func sizeChanged() {
        capture.setPixelSize(MiniScreen.pixelSize(view.bounds.size, scale: panel.backingScaleFactor, crop: crop))
        onChange?()
    }

    func windowDidMove(_ notification: Notification) {
        onChange?()
    }

    /// Stop capturing while the mini can't be seen (screen locked, display asleep, other Space).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        hiddenWork?.cancel()
        if panel.occlusionState.contains(.visible) {
            capture.start()
            return
        }
        // The state flickers briefly when apps switch; only pause once it has stayed hidden.
        let work = DispatchWorkItem { [weak self] in self?.capture.stop() }
        hiddenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Capture at the size shown, never above the source's own resolution.
    private static func pixelSize(_ size: CGSize, scale: CGFloat, crop: CGRect) -> CGSize {
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return CGSize(width: min(size.width * scale, crop.width * maxScale),
                      height: min(size.height * scale, crop.height * maxScale))
    }

    private static func defaultFrame(for cropSize: CGSize, cascade: Int) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let fit = min(1, min(520, visible.width * 0.4) / cropSize.width, visible.height * 0.45 / cropSize.height)
        var size = CGSize(width: cropSize.width * fit, height: cropSize.height * fit)
        if size.width < MiniView.minWidth {
            size = CGSize(width: MiniView.minWidth, height: MiniView.minWidth * cropSize.height / cropSize.width)
        }
        let offset = CGFloat(cascade % 8) * 28
        return CGRect(x: visible.maxX - size.width - 24 - offset, y: visible.maxY - size.height - 24 - offset,
                      width: size.width, height: size.height)
    }
}

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let top = Edges(rawValue: 4)
    static let bottom = Edges(rawValue: 8)
}

/// Draws frames through `videoLayer`; the hit area is the whole view.
private final class VideoView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MiniView: NSView {
    static let minWidth: CGFloat = 120
    private static let edgeMargin: CGFloat = 7

    private let video = VideoView()
    private let bar: TopBar
    private let status = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    private var resizing: Edges = []
    private var resizeStartMouse = NSPoint.zero
    private var resizeStartFrame = NSRect.zero

    var videoLayer: CALayer { video.layer! }
    var aspect: CGFloat = 1
    var onResized: (() -> Void)?

    init(frame: NSRect, bar: TopBar) {
        self.bar = bar
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        video.wantsLayer = true
        video.layer?.contentsGravity = .resize
        video.frame = bounds
        video.autoresizingMask = [.width, .height]
        addSubview(video)

        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .white
        status.alignment = .center
        status.isHidden = true
        addSubview(status)

        bar.alphaValue = 0
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 8, y: bounds.height - 38, width: bounds.width - 16, height: 30)
        status.sizeToFit()
        status.frame.origin = NSPoint(x: (bounds.width - status.frame.width) / 2,
                                      y: (bounds.height - status.frame.height) / 2)
    }

    func showStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = false
        video.alphaValue = 0.35
        needsLayout = true
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        guard resizing.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; bar.animator().alphaValue = 0 }
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        (edges.isEmpty ? NSCursor.arrow : cursor(for: edges)).set()
    }

    // MARK: Mouse (drag anywhere to move, edges to resize)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let edges = edges(at: convert(event.locationInWindow, from: nil))
        if edges.isEmpty {
            window?.performDrag(with: event)
        } else {
            resizing = edges
            resizeStartMouse = NSEvent.mouseLocation
            resizeStartFrame = window?.frame ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !resizing.isEmpty {
            resize()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !resizing.isEmpty {
            resizing = []
            onResized?()
        }
    }

    // MARK: Resize (keeps the crop's aspect ratio)

    private func edges(at p: NSPoint) -> Edges {
        let m = Self.edgeMargin
        var edges: Edges = []
        if p.x < m { edges.insert(.left) }
        if p.x > bounds.width - m { edges.insert(.right) }
        if p.y < m { edges.insert(.bottom) }
        if p.y > bounds.height - m { edges.insert(.top) }
        return edges
    }

    private func resize() {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - resizeStartMouse.x
        let dy = now.y - resizeStartMouse.y
        let start = resizeStartFrame
        var w = start.width, h = start.height
        if resizing.contains(.right) { w += dx }
        if resizing.contains(.left) { w -= dx }
        if resizing.contains(.top) { h += dy }
        if resizing.contains(.bottom) { h -= dy }

        let horizontal = resizing.contains(.left) || resizing.contains(.right)
        let vertical = resizing.contains(.top) || resizing.contains(.bottom)
        if horizontal && (!vertical || abs(dx) >= abs(dy)) {
            h = w / aspect
        } else {
            w = h * aspect
        }
        if w < Self.minWidth {
            w = Self.minWidth
            h = w / aspect
        }

        let x = resizing.contains(.left) ? start.maxX - w : start.minX
        let y = resizing.contains(.top) ? start.minY : start.maxY - h
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        onResized?()
    }

    private func cursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.top, .left]: position = .topLeft
            case [.top, .right]: position = .topRight
            case [.bottom, .left]: position = .bottomLeft
            case [.bottom, .right]: position = .bottomRight
            case .top: position = .top
            case .bottom: position = .bottom
            case .left: position = .left
            default: position = .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return edges.contains(.top) || edges.contains(.bottom) ? .resizeUpDown : .resizeLeftRight
    }
}

/// Floating glass pill shown on hover: drag it to move the mini, ✕ to close.
final class TopBar: NSView {
    let closeButton = TopBar.symbolButton("xmark.circle.fill", tip: "Close")

    init(title: String, icon: NSImage?) {
        super.init(frame: .zero)
        let (glass, content) = Glass.make(cornerRadius: 15)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        let iconView = NSImageView(image: icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, label, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Everything except the buttons acts as the drag handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    private static func symbolButton(_ name: String, tip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!,
                              target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}
