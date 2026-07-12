import AppKit
import SwiftUI

enum Severity {
    case normal, warning, critical

    init(percent: Double?) {
        switch percent ?? 0 {
        case 90...: self = .critical
        case 70..<90: self = .warning
        default: self = .normal
        }
    }
}

struct GaugeData: Identifiable {
    let id: String        // "CL" / "CX", also the tag shown in text style
    let percent: Double?
    let severity: Severity
    let tint: Color

    var arcColor: Color {
        switch severity {
        case .normal: return tint
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var percentText: String {
        percent.map { "\(Int($0.rounded()))%" } ?? "–"
    }
}

/// The status item content, rendered in the user's chosen style. Colors carry
/// provider identity and severity; text stays monochrome so the item feels
/// native next to Apple's own menu bar icons.
struct MenuBarView: View {
    let entries: [GaugeData]
    let style: MenuBarStyle

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("AI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            } else {
                switch style {
                case .ringsPercent:
                    HStack(spacing: 9) {
                        ForEach(entries) { RingGauge(entry: $0, showPercent: true) }
                    }
                case .rings:
                    HStack(spacing: 6) {
                        ForEach(entries) { RingGauge(entry: $0, showPercent: false) }
                    }
                case .text:
                    HStack(spacing: 8) {
                        ForEach(entries) { TextGauge(entry: $0) }
                    }
                case .bars:
                    VStack(alignment: .leading, spacing: 3.5) {
                        ForEach(entries) { BarGauge(entry: $0) }
                    }
                }
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
    }
}

private struct RingGauge: View {
    let entry: GaugeData
    let showPercent: Bool

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.16), lineWidth: 2.5)
                if let percent = entry.percent {
                    Circle()
                        .trim(from: 0, to: max(0.03, min(1.0, percent / 100)))
                        .stroke(
                            entry.arcColor.opacity(0.95),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 13, height: 13)

            if showPercent {
                Text(entry.percentText)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(entry.severity == .critical ? Color.red : Color.primary.opacity(0.85))
            }
        }
        .fixedSize()
    }
}

private struct TextGauge: View {
    let entry: GaugeData

    var body: some View {
        Text("\(entry.id) \(entry.percentText)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(entry.severity == .critical ? Color.red : Color.primary.opacity(0.85))
            .fixedSize()
    }
}

private struct BarGauge: View {
    let entry: GaugeData

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.16))
            if let percent = entry.percent {
                Capsule()
                    .fill(entry.arcColor.opacity(0.95))
                    .frame(width: max(3, 26 * min(1.0, percent / 100)))
            }
        }
        .frame(width: 26, height: 3.5)
    }
}

/// NSHostingView swallows clicks by default, which would stop the status
/// button from ever firing its action — pass them through instead.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
