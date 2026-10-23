import AppKit
import ScreenCaptureKit

enum Prefs {
    static let fpsChoices = [5, 10, 15, 30]

    static var fps: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "fps")
            return fpsChoices.contains(value) ? value : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: "fps") }
    }
}

struct SavedMini: Codable {
    var bundleID: String
    var title: String
    var crop: CGRect
    var frame: CGRect
}

/// Owns the open mini screens and remembers them across launches.
final class Store {
    private(set) var minis: [MiniScreen] = []
    private var saveWork: DispatchWorkItem?
    private let key = "minis"

    func add(window: SCWindow, crop: CGRect, frame: CGRect? = nil) {
        let mini = MiniScreen(window: window, crop: crop, frame: frame,
                              fps: Prefs.fps, cascade: minis.count)
        mini.onClose = { [weak self] mini in
            self?.minis.removeAll { $0 === mini }
            self?.save()
        }
        mini.onChange = { [weak self] in self?.scheduleSave() }
        minis.append(mini)
        save()
    }

    func closeAll() {
        minis.forEach { $0.close() }
    }

    func setFPS(_ fps: Int) {
        Prefs.fps = fps
        minis.forEach { $0.setFPS(fps) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        let saved = minis.map(\.saved)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Reopens last session's minis, matching each to a window of the same app (same title if possible).
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedMini].self, from: data),
              !saved.isEmpty else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            DispatchQueue.main.async {
                guard let content else { return }
                var used = Set<CGWindowID>()
                for item in saved {
                    let candidates = content.windows.filter {
                        $0.windowLayer == 0 && !used.contains($0.windowID)
                            && $0.owningApplication?.bundleIdentifier == item.bundleID
                            && $0.frame.width >= item.crop.maxX && $0.frame.height >= item.crop.maxY
                    }
                    let match = candidates.first { $0.title == item.title }
                        ?? candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                    guard let window = match else { continue }
                    used.insert(window.windowID)
                    let onScreen = NSScreen.screens.contains { $0.frame.intersects(item.frame) }
                    self.add(window: window, crop: item.crop, frame: onScreen ? item.frame : nil)
                }
            }
        }
    }
}
