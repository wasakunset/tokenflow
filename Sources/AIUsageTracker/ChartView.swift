import SwiftUI

/// Full usage-history graph for one provider, opened by clicking a card's
/// sparkline. Fixed 0–100% scale, 24h/7d range, hover to inspect a moment.
struct ChartView: View {
    let usage: ProviderUsage
    let tint: Color
    var onBack: () -> Void

    @State private var week = false
    @State private var hoverX: CGFloat?

    private var period: TimeInterval { week ? 7 * 24 * 3600 : 24 * 3600 }

    /// Session first, weekly second — the two lines worth plotting.
    private var plottedWindows: [(window: LimitWindow, dashed: Bool)] {
        var result: [(LimitWindow, Bool)] = []
        if let session = usage.windows.first { result.append((session, false)) }
        if usage.windows.count > 1 { result.append((usage.windows[1], true)) }
        return result
    }

    private func samples(for window: LimitWindow) -> [UsageHistory.Sample] {
        UsageHistory.shared.samples(UsageHistory.key(usage.name, window), last: period)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("\(usage.name) usage")
                    .font(.headline)
                Spacer()
                Picker("", selection: $week) {
                    Text("24h").tag(false)
                    Text("7d").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }

            if let session = usage.windows.first, samples(for: session).count >= 2 {
                chart
                legend
                if let hit = UsageHistory.shared.predictedLimitHit(
                    provider: usage.name, window: session
                ) {
                    Label {
                        Text("on pace to hit 100% ~\(Fmt.reset(hit)) — before the reset")
                    } icon: {
                        Image(systemName: "speedometer")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            } else {
                Text("Not enough history yet — the graph fills in as the app keeps sampling every few minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 24)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Chart body

    private var chart: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let now = Date()
                let start = now.addingTimeInterval(-period)
                let xPos = { (t: Date) -> CGFloat in
                    w * CGFloat(t.timeIntervalSince(start) / period)
                }
                let yPos = { (pct: Double) -> CGFloat in
                    h * CGFloat(1 - min(1, pct / 100))
                }

                ZStack(alignment: .topLeading) {
                    // Grid: 0/25/50/75/100%
                    ForEach([0, 25, 50, 75, 100], id: \.self) { level in
                        Path { p in
                            let y = yPos(Double(level))
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.primary.opacity(level == 100 ? 0.15 : 0.07), lineWidth: 1)
                        Text("\(level)")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .position(x: 8, y: max(6, yPos(Double(level)) - 7))
                    }

                    // One line per window
                    ForEach(Array(plottedWindows.enumerated()), id: \.offset) { _, item in
                        let pts = samples(for: item.window)
                        Path { p in
                            for (i, s) in pts.enumerated() {
                                let point = CGPoint(x: xPos(s.t), y: yPos(s.pct))
                                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                            }
                        }
                        .stroke(
                            item.dashed ? tint.opacity(0.45) : tint,
                            style: StrokeStyle(
                                lineWidth: item.dashed ? 1.5 : 2,
                                lineCap: .round, lineJoin: .round,
                                dash: item.dashed ? [3, 3] : []
                            )
                        )
                    }

                    // Hover crosshair + readout for the session line
                    if let hx = hoverX, let session = usage.windows.first {
                        let pts = samples(for: session)
                        let target = start.addingTimeInterval(Double(hx / w) * period)
                        if let nearest = pts.min(by: {
                            abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target))
                        }) {
                            let nx = xPos(nearest.t)
                            Path { p in
                                p.move(to: CGPoint(x: nx, y: 0))
                                p.addLine(to: CGPoint(x: nx, y: h))
                            }
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                            Circle()
                                .fill(tint)
                                .frame(width: 5, height: 5)
                                .position(x: nx, y: yPos(nearest.pct))
                            Text("\(Fmt.reset(nearest.t)) · \(Int(nearest.pct.rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .position(
                                    x: min(max(nx, 36), w - 36),
                                    y: max(10, yPos(nearest.pct) - 14)
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverX = point.x
                    case .ended: hoverX = nil
                    }
                }
            }
            .frame(height: 130)

            HStack {
                Text(week ? "7 days ago" : "24 hours ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(plottedWindows.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(item.dashed ? tint.opacity(0.45) : tint)
                        .frame(width: 14, height: 2)
                    Text(item.window.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
