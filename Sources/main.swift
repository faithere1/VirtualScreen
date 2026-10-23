import AppKit
import ScreenCaptureKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let picker = PickerModel()
    private let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "VirtualScreen")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: PickerView(
                model: picker,
                onPick: { [weak self] window in self?.pick(window) },
                onFPS: { [weak self] fps in self?.store.setFPS(fps) }
            )
        )

        requestPermissions()
        if CGPreflightScreenCaptureAccess() {
            store.restore()
        }
    }

    private func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        togglePicker()
    }

    @objc private func togglePicker() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        picker.reload()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func pick(_ window: SCWindow) {
        popover.performClose(nil)
        RegionSelector.begin(window: window) { [weak self] crop in
            guard let self, let crop else { return }
            self.store.add(window: window, crop: crop)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let new = NSMenuItem(title: "New Mini Screen…", action: #selector(togglePicker), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        let closeAll = NSMenuItem(title: "Close All Mini Screens", action: #selector(closeAll), keyEquivalent: "")
        closeAll.target = self
        closeAll.isEnabled = !store.minis.isEmpty
        menu.addItem(closeAll)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VirtualScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func closeAll() {
        store.closeAll()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
