import AppKit
import Combine
import SwiftUI

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
        popover.contentSize = NSSize(width: 380, height: PanelView.panelHeight)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: Self.model))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusSubscription = Self.model.$hasHostsBlock.removeDuplicates().sink { [weak self] active in
            self?.updateStatusItem(active: active)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: PanelView.panelHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Still preview"
            window.contentView = NSHostingView(rootView: PanelView(model: Self.model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            previewWindow = window
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

    private func updateStatusItem(active: Bool) {
        let image = NSImage(systemSymbolName: active ? "shield.lefthalf.filled" : "shield", accessibilityDescription: "Still")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = active ? "Still: website blocking active" : "Still: website blocker"
        statusItem?.button?.setAccessibilityLabel(active ? "Still: website blocking active" : "Still: website blocker")
    }
}
