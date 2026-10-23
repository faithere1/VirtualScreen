import AppKit
import ScreenCaptureKit
import SwiftUI

final class PickerModel: ObservableObject {
    struct Item: Identifiable {
        let id: CGWindowID
        let window: SCWindow
        let appName: String
        let title: String
        let icon: NSImage?
    }

    @Published var items: [Item] = []
    @Published var fps = Prefs.fps
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()

    private static let ignoredBundles: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui",
    ]

    func reload() {
        hasScreenAccess = CGPreflightScreenCaptureAccess()
        // Asking ScreenCaptureKit without access re-triggers the system prompt, and a fresh grant only
        // takes effect after a relaunch, so stop here until then.
        guard hasScreenAccess else {
            items = []
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            let windows = (content?.windows ?? []).filter { window in
                guard let app = window.owningApplication else { return false }
                return window.windowLayer == 0 && window.isOnScreen
                    && window.frame.width >= 80 && window.frame.height >= 60
                    && app.processID != ownPID
                    && !Self.ignoredBundles.contains(app.bundleIdentifier)
            }
            DispatchQueue.main.async {
                self.items = windows.map { window in
                    let app = window.owningApplication!
                    return Item(id: window.windowID, window: window, appName: app.applicationName,
                                title: window.title ?? "",
                                icon: NSRunningApplication(processIdentifier: app.processID)?.icon)
                }
                .sorted { ($0.appName.lowercased(), $0.title) < ($1.appName.lowercased(), $1.title) }
            }
        }
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    var onPick: (SCWindow) -> Void
    var onFPS: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Mini Screen").font(.headline)
                Spacer()
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh window list")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if !model.hasScreenAccess {
                PermissionRow(symbol: "rectangle.dashed.badge.record", text: "Screen Recording is off",
                              pane: "Privacy_ScreenCapture")
            }

            if model.items.isEmpty {
                Spacer()
                if model.hasScreenAccess {
                    Text("No windows found").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        Text("Turn on VirtualScreen under Screen & System Audio Recording, then relaunch.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Relaunch VirtualScreen") { relaunch() }
                            .controlSize(.large)
                    }
                    .padding(24)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in
                            WindowRow(item: item).onTapGesture { onPick(item.window) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Divider()
            HStack {
                Text("Refresh rate").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.fps) {
                    ForEach(Prefs.fpsChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Text("fps").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 340, height: 440)
        .onChange(of: model.fps) { _, fps in onFPS(fps) }
    }
}

/// Screen Recording grants only apply to a fresh process.
private func relaunch() {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

private struct WindowRow: View {
    let item: PickerModel.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: "macwindow").frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.appName).fontWeight(.medium).lineLimit(1)
                if !item.title.isEmpty {
                    Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "viewfinder").foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let text: String
    let pane: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
