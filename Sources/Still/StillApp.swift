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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?
    private var statusTimer: Timer?
    private var presentation: StatusPresentation?
    private var wakeSubscription: AnyCancellable?
    private let navigation = PanelNavigation()
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.viciousbuilders.still")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !Self.model.isDemo && !otherInstances.isEmpty {
            NSApplication.shared.terminate(nil)
            return
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 400, height: PanelView.panelHeight)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusSubscription = Publishers.CombineLatest(Self.model.$hasHostsBlock.removeDuplicates(), Self.model.focus.$session).sink { [weak self] active, session in
            self?.updateStatusItem(active: active, session: session, now: Date())
        }
        wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                Self.model.refresh()
                self?.updateStatusItem(active: Self.model.active, session: Self.model.focus.session, now: Date())
            }

        if Self.model.isDemo {
            showPreview()
        }
    }

    private func showPreview() {
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
        window.contentView = NSHostingView(rootView: PanelView(model: Self.model, navigation: navigation))
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

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.model.refresh()
        if Self.model.showSettings { Self.model.refreshLoginStatus() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
    }

    func popoverDidClose(_ notification: Notification) {
        // Removing the hosting controller also removes hidden SwiftUI observers
        // and timelines. Navigation and in-progress website input live outside it.
        popover.contentViewController = nil
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
        Self.model.refresh()
        if popover.contentViewController == nil {
            let controller = NSHostingController(rootView: PanelView(model: Self.model, navigation: navigation))
            controller.view.appearance = popover.appearance
            popover.contentViewController = controller
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem(active: Bool, session: FocusSession?, now: Date) {
        let next = StatusPresentation(active: active, session: session, now: now)
        if next.countingDown && statusTimer == nil {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateStatusItem(active: Self.model.active, session: Self.model.focus.session, now: Date())
                }
            }
            statusTimer?.tolerance = 0.1
        } else if !next.countingDown {
            statusTimer?.invalidate(); statusTimer = nil
        }
        guard next != presentation else { return }
        if next.symbol != presentation?.symbol {
            let image = NSImage(systemSymbolName: next.symbol, accessibilityDescription: "Still")
            image?.isTemplate = true
            statusItem?.button?.image = image
        }
        if next.countingDown != presentation?.countingDown {
            statusItem?.length = next.countingDown ? NSStatusItem.variableLength : NSStatusItem.squareLength
            if next.countingDown { statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
        }
        if next.title != presentation?.title { statusItem?.button?.title = next.title }
        if next.detail != presentation?.detail {
            statusItem?.button?.toolTip = next.detail
            statusItem?.button?.setAccessibilityLabel(next.detail)
        }
        presentation = next
    }
}
