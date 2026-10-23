import AppKit
import ScreenCaptureKit

private final class SelectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows a still of the chosen window and lets the user drag out the part to keep, like ⌘⇧4.
/// The completion gets the crop in window points (top-left origin), or nil if cancelled.
enum RegionSelector {
    private static var panel: NSPanel?

    static func begin(window: SCWindow, completion: @escaping (CGRect?) -> Void) {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
            DispatchQueue.main.async {
                guard let image else { return completion(nil) }
                show(image: image, windowSize: window.frame.size, completion: completion)
            }
        }
    }

    private static func show(image: CGImage, windowSize: CGSize, completion: @escaping (CGRect?) -> Void) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let panel = SelectorPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Fit the still into the visible area of the screen, in view coordinates.
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 60)
        let fit = min(visible.width / windowSize.width, visible.height / windowSize.height, 1)
        let size = CGSize(width: windowSize.width * fit, height: windowSize.height * fit)
        let imageRect = CGRect(x: visible.midX - size.width / 2 - screen.frame.minX,
                               y: visible.midY - size.height / 2 - screen.frame.minY,
                               width: size.width, height: size.height)

        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                 image: image, imageRect: imageRect, windowSize: windowSize)
        view.onFinish = { selection in
            panel.orderOut(nil)
            Self.panel = nil
            guard let selection else { return completion(nil) }
            let sx = windowSize.width / imageRect.width
            let sy = windowSize.height / imageRect.height
            let crop = CGRect(x: (selection.minX - imageRect.minX) * sx,
                              y: (imageRect.maxY - selection.maxY) * sy,
                              width: selection.width * sx,
                              height: selection.height * sy).integral
            completion(crop.intersection(CGRect(origin: .zero, size: windowSize)))
        }
        panel.contentView = view

        let hint = makeHint()
        hint.frame.origin = CGPoint(x: (view.bounds.width - hint.frame.width) / 2,
                                    y: min(imageRect.maxY + 14, view.bounds.height - hint.frame.height - 30))
        view.addSubview(hint)

        Self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private static func makeHint() -> NSView {
        let label = NSTextField(labelWithString: "Drag to select an area  ·  Click for the whole window  ·  Esc to cancel")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 32, height: 34)
        let (glass, content) = Glass.make(cornerRadius: size.height / 2)
        glass.frame = CGRect(origin: .zero, size: size)
        label.frame.origin = CGPoint(x: 16, y: (size.height - label.frame.height) / 2)
        content.addSubview(label)
        return glass
    }
}

private final class SelectionView: NSView {
    private let image: NSImage
    private let imageRect: CGRect
    private let windowSize: CGSize
    private var start: CGPoint?
    private var selection: CGRect?
    var onFinish: ((CGRect?) -> Void)?

    init(frame: CGRect, image: CGImage, imageRect: CGRect, windowSize: CGSize) {
        self.image = NSImage(cgImage: image, size: imageRect.size)
        self.imageRect = imageRect
        self.windowSize = windowSize
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        image.draw(in: imageRect)

        guard let selection else { return }
        // Dim everything on the still except the selection.
        let dim = NSBezierPath(rect: imageRect)
        dim.append(NSBezierPath(rect: selection).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()

        let w = Int(selection.width * scaleToWindow.width), h = Int(selection.height * scaleToWindow.height)
        let text = "\(w) × \(h)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let tag = CGRect(x: selection.maxX - textSize.width - 12, y: selection.minY - textSize.height - 10,
                         width: textSize.width + 12, height: textSize.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: tag.minX + 6, y: tag.minY + 3), withAttributes: attrs)
    }

    private var scaleToWindow: CGSize {
        CGSize(width: windowSize.width / imageRect.width, height: windowSize.height / imageRect.height)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, imageRect.minX), imageRect.maxX), y: min(max(p.y, imageRect.minY), imageRect.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        start = imageRect.contains(p) ? p : nil
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return finish(nil) }  // clicked outside the still
        if let selection, selection.width >= 8, selection.height >= 8 {
            finish(selection)
        } else {
            finish(imageRect)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish(nil)                       // Esc
        case 36, 76: finish(selection ?? imageRect) // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    private func finish(_ rect: CGRect?) {
        NSCursor.pop()
        onFinish?(rect)
        onFinish = nil
    }
}
