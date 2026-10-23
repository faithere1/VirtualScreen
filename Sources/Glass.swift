import AppKit

/// Liquid Glass on macOS 26 (looked up at runtime, so older SDKs still build), blur material before that.
enum Glass {
    /// Returns the glass view to add to the hierarchy and the view to put content into.
    static func make(cornerRadius: CGFloat) -> (glass: NSView, content: NSView) {
        let content = NSView()
        if let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = cls.init(frame: .zero)
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            glass.setValue(content, forKey: "contentView")
            return (glass, content)
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return (blur, content)
    }
}
