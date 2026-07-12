import SwiftUI

// MARK: - Brand colors

extension Color {
    static let claudeTint = Color(red: 0.851, green: 0.467, blue: 0.341)  // coral
    static let codexTint = Color(red: 0.063, green: 0.639, blue: 0.498)   // teal

    static func severity(_ percent: Double, tint: Color) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return tint
    }
}

// MARK: - Liquid glass card background
// Real Liquid Glass on macOS 26+, translucent material on older systems.

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        // The compiler check keeps the package buildable with pre-macOS-26
        // SDKs (Xcode < 26), where the glassEffect symbols don't exist.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}

// MARK: - Popover root: welcome → usage ⇄ settings

struct RootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @State private var showingSettings = false

    var body: some View {
        if !settings.hasCompletedWelcome {
            WelcomeView(settings: settings) {
                settings.hasCompletedWelcome = true
                store.refresh(force: true)
            }
        } else if showingSettings {
            SettingsView(settings: settings) { showingSettings = false }
        } else {
            UsageView(store: store, settings: settings) { showingSettings = true }
        }
    }
}

// MARK: - First-run welcome

struct WelcomeView: View {
    @ObservedObject var settings: AppSettings
    var onContinue: () -> Void

    @ObservedObject private var oauth = OAuthManager.shared
    private let claudeFound = ClaudeProvider.isConfigured()
    private let codexFound = CodexProvider.isConfigured()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TokenFlow")
                .font(.title3.bold())
            Text("Shows your Claude and Codex rate limits in the menu bar. It reads the logins your CLIs already saved — nothing to sign into, no tokens to paste. Your credentials never leave this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                detectionRow("Claude Code", found: claudeFound)
                detectionRow("Codex", found: codexFound)
            }

            if claudeFound {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("macOS will ask permission to read Claude Code's login — choose “Always Allow” so it only asks once.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    if oauth.busy == "Claude" {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Waiting for browser approval…")
                        }
                    } else {
                        Button("Prefer no password prompt? Connect in browser instead") {
                            oauth.connect("Claude") {
                                settings.preferConnectedClaude = true
                                onContinue()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    if let error = oauth.errors["Claude"] {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            Toggle("Start at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            .font(.callout)

            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func detectionRow(_ name: String, found: Bool) -> some View {
        Label {
            Text(found ? "\(name) — found" : "\(name) — not found (you can hide it later in settings)")
                .font(.callout)
        } icon: {
            Image(systemName: found ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(found ? Color.green : Color.secondary)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onBack: () -> Void

    @ObservedObject private var oauth = OAuthManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Menu bar style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Providers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Claude", isOn: $settings.showClaude)
                Toggle("Show Codex", isOn: $settings.showCodex)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Text("Refresh every")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $settings.refreshMinutes) {
                    Text("2 min").tag(2)
                    Text("3 min").tag(3)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Notify at 70% and 90%", isOn: $settings.notificationsEnabled)
                .font(.callout)

            claudeAccessSection

            Toggle("Start at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder private var claudeAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude access")
                .font(.caption)
                .foregroundStyle(.secondary)
            if AppCredentials.load().claude != nil {
                Toggle("Use browser-connected account (no Keychain prompt)",
                       isOn: $settings.preferConnectedClaude)
                    .font(.callout)
            } else if oauth.busy == "Claude" {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for browser approval…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Connect Claude in browser…") {
                    oauth.connect("Claude") {
                        settings.preferConnectedClaude = true
                    }
                }
                .controlSize(.small)
                Text("Avoids the macOS Keychain prompt by using its own login.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let error = oauth.errors["Claude"] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Main usage panel

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            cards
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private var cards: some View {
        if !settings.showClaude && !settings.showCodex {
            Text("Both providers are hidden — enable one in settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(20)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) { cardContent }
                }
            } else {
                VStack(spacing: 10) { cardContent }
            }
            #else
            VStack(spacing: 10) { cardContent }
            #endif
        }
    }

    @ViewBuilder private var cardContent: some View {
        if settings.showClaude {
            ProviderCard(
                usage: store.claude, tint: .claudeTint,
                onHide: { settings.showClaude = false },
                onRetry: { store.refresh(force: true) }
            )
        }
        if settings.showCodex {
            ProviderCard(
                usage: store.codex, tint: .codexTint,
                onHide: { settings.showCodex = false },
                onRetry: { store.refresh(force: true) }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.refresh(force: true)
            } label: {
                if store.refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")

            if let updated = store.lastUpdated {
                Text("Updated \(Fmt.relative(updated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Updated \(Fmt.timestamp(updated))")
            }

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit TokenFlow")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

// MARK: - Provider card

struct ProviderCard: View {
    let usage: ProviderUsage
    let tint: Color
    var onHide: () -> Void
    var onRetry: () -> Void

    @ObservedObject private var oauth = OAuthManager.shared
    @State private var sparklineWeek = false

    private var isStale: Bool { usage.note != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if usage.error != nil {
                errorState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                        WindowRow(
                            window: window,
                            tint: tint,
                            predictedHit: UsageHistory.shared.predictedLimitHit(
                                provider: usage.name, window: window
                            )
                        )
                    }
                }
                // Dimmed = not live, perceivable without reading the pill.
                .saturation(isStale ? 0.7 : 1)
                .opacity(isStale ? 0.9 : 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(usage.name)
                .font(.system(size: 14, weight: .semibold))

            if let note = usage.note {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text("cached")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .help(note)
            }

            Spacer()

            if let session = usage.windows.first {
                let history = UsageHistory.shared.samples(
                    UsageHistory.key(usage.name, session),
                    last: sparklineWeek ? 7 * 24 * 3600 : 24 * 3600
                )
                if history.count >= 2 {
                    Sparkline(samples: history, tint: tint)
                        .contentShape(Rectangle())
                        .onTapGesture { sparklineWeek.toggle() }
                        .help(sparklineWeek ? "Last 7 days — click for 24h" : "Last 24 hours — click for 7d")
                }
            }

            if let plan = usage.plan {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
    }

    @ViewBuilder private var errorState: some View {
        switch usage.errorKind {
        case .notConfigured:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(usage.name) isn't set up on this Mac. Connect your account in the browser, or install its CLI and log in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if oauth.busy == usage.name {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser approval…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Connect \(usage.name)…") {
                            oauth.connect(usage.name, onSuccess: onRetry)
                        }
                        .disabled(oauth.busy != nil)
                        Button("Hide", action: onHide)
                    }
                    .controlSize(.small)
                }
                if let error = oauth.errors[usage.name] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Keychain access was denied — retry and choose “Always Allow”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
        case .other:
            Label {
                Text(usage.error ?? "unknown error")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Sparkline (last 24h of one window, fixed 0–100 scale)

struct Sparkline: View {
    let samples: [UsageHistory.Sample]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard samples.count >= 2,
                      let first = samples.first, let last = samples.last,
                      last.t > first.t else { return }
                let span = last.t.timeIntervalSince(first.t)
                for (i, s) in samples.enumerated() {
                    let x = geo.size.width * (s.t.timeIntervalSince(first.t) / span)
                    let y = geo.size.height * (1 - min(1, s.pct / 100))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 54, height: 14)
    }
}

// MARK: - One limit window: label + reset inline, percent right, thin bar below

struct WindowRow: View {
    let window: LimitWindow
    let tint: Color
    /// Burn-rate projection: when usage will hit 100% (nil = no risk).
    var predictedHit: Date? = nil

    private var barColor: Color { .severity(window.percent, tint: tint) }

    private var percentColor: Color {
        if window.percent >= 90 { return .red }
        if window.percent >= 70 { return .orange }
        return .primary
    }

    private var resetText: String {
        if let countdown = Fmt.countdown(window.resetsAt) {
            return "· resets in \(countdown)"
        }
        return "· resets \(Fmt.reset(window.resetsAt))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.label)
                    .font(.callout)
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Resets at \(Fmt.reset(window.resetsAt))")
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(percentColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.85), barColor],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, geo.size.width * window.percent / 100))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.4), value: window.percent)

            if let hit = predictedHit {
                Label {
                    Text("on pace to hit 100% ~\(Fmt.reset(hit)) — before the reset")
                } icon: {
                    Image(systemName: "speedometer")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }
}
