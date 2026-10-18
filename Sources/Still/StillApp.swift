import AppKit
import Combine
import SwiftUI
import BlockerCore

@main
@MainActor
enum StillApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.mainMenu = NativeMenus.makeMainMenu()
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.viciousbuilders.still")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !Self.model.isDemo && !otherInstances.isEmpty {
            NSApplication.shared.terminate(nil)
            return
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: PanelView.panelHeight)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: Self.model))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusSubscription = Publishers.CombineLatest3(Self.model.$hasHostsBlock, Self.model.focus.$session, Self.model.$now).sink { [weak self] active, session, now in
            self?.updateStatusItem(active: active, session: session, now: now)
        }

        if Self.model.isDemo {
            NSApplication.shared.setActivationPolicy(.regular)
            let appearance: NSAppearance?
            if CommandLine.arguments.contains("--light") { appearance = NSAppearance(named: .aqua) }
            else if CommandLine.arguments.contains("--dark") { appearance = NSAppearance(named: .darkAqua) }
            else { appearance = nil }
            NSApplication.shared.appearance = appearance
            // A status-item popover otherwise inherits the system menu bar's
            // appearance, which can differ from our preview override.
            popover.appearance = appearance
            popover.contentViewController?.view.appearance = appearance
            if CommandLine.arguments.contains("--menu-preview") {
                // Exercise the actual status-item popover without network changes.
                DispatchQueue.main.async { [weak self] in self?.showPopover() }
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: PanelView.panelHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Still preview"
            window.contentView = NSHostingView(rootView: PanelView(model: Self.model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            previewWindow = window
            if let index = CommandLine.arguments.firstIndex(of: "--export-preview"),
               CommandLine.arguments.indices.contains(index + 1) {
                let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let view = window.contentView else { return }
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    do {
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
                        try png.write(to: destination, options: .atomic)
                    } catch {
                        fputs("Could not export preview: \(error)\n", stderr)
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem(active: Bool, session: FocusSession?, now: Date) {
        let image = NSImage(systemSymbolName: session != nil ? "timer" : active ? "shield.lefthalf.filled" : "shield", accessibilityDescription: "Still")
        image?.isTemplate = true
        statusItem?.button?.image = image
        var detail = active ? "Still: website blocking active" : "Still: website blocker"
        if let phase = session?.phase(at: now) {
            let seconds = max(0, Int(ceil(phase.endsAt.timeIntervalSince(now))))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            statusItem?.length = NSStatusItem.variableLength
            statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            statusItem?.button?.title = " \(time)"
            detail = "Still: \(phase.kind == .focus ? "Focus" : "Break") · \(time) remaining"
        } else {
            statusItem?.button?.title = ""
            statusItem?.length = NSStatusItem.squareLength
        }
        statusItem?.button?.toolTip = detail
        statusItem?.button?.setAccessibilityLabel(detail)
    }
}
