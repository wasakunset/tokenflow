import AppKit
import SwiftUI

// MARK: - CLI mode: `AIUsageTracker --print` prints usage and exits.

if CommandLine.arguments.contains("--print") {
    for usage in [ClaudeProvider().fetch(), CodexProvider().fetch(), GeminiProvider().fetch()] {
        print("\(usage.name)\(usage.plan.map { " (\($0))" } ?? "")")
        if let err = usage.error { print("  error: \(err)") }
        for w in usage.windows {
            print("  \(w.label): \(Int(w.percent))%  resets \(Fmt.reset(w.resetsAt))")
        }
        if let note = usage.note { print("  note: \(note)") }
    }
    exit(0)
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var menuBarHosting: ClickThroughHostingView<MenuBarView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(
            rootView: RootView(store: store, settings: settings)
        )
        // Let the popover track the SwiftUI content's intrinsic size. Without
        // this the popover mis-measures when the content height changes
        // (switching to Settings/Chart, a third card appearing), which showed
        // up as the panel opening at the wrong height/position.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            // Empty rings act as the loading state until the first fetch lands.
            let hosting = ClickThroughHostingView(rootView: makeMenuBarView())
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            ])
            menuBarHosting = hosting
        }

        store.onUpdate = { [weak self] in self?.updateStatusItem() }
        settings.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.scheduleTimer()
            self?.store.refresh()
        }

        store.refresh()
        scheduleTimer()

        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NotificationManager.shared.sendTest()
            }
        }

        // First run: nothing visible happens on launch, so open the welcome
        // popover once rather than leaving the user hunting for the rings.
        if !settings.hasCompletedWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, !self.popover.isShown else { return }
                self.togglePopover()
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Double(settings.refreshMinutes * 60), repeats: true
        ) { [weak self] _ in
            self?.store.refresh()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Accessory apps need to activate for the transient popover to
            // take key focus and dismiss on outside clicks.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        menuBarHosting?.rootView = makeMenuBarView()
    }

    private func makeMenuBarView() -> MenuBarView {
        var entries: [GaugeData] = []
        if settings.showClaude {
            entries.append(GaugeData(
                id: "CL",
                percent: store.claude.primaryPercent,
                // Severity reflects the worst window — weekly can be critical
                // while the session is low.
                severity: Severity(percent: store.claude.windows.map(\.percent).max()),
                tint: .claudeTint
            ))
        }
        if settings.showCodex {
            entries.append(GaugeData(
                id: "CX",
                percent: store.codex.primaryPercent,
                severity: Severity(percent: store.codex.windows.map(\.percent).max()),
                tint: .codexTint
            ))
        }
        if settings.showGemini {
            entries.append(GaugeData(
                id: "GM",
                percent: store.gemini.primaryPercent,
                severity: Severity(percent: store.gemini.windows.map(\.percent).max()),
                tint: .geminiTint
            ))
        }
        return MenuBarView(entries: entries, style: settings.menuBarStyle)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
