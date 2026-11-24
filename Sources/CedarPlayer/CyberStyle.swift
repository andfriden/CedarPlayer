import SwiftUI

/// Inset graphite surface with a thin top highlight and orange edge glow.
struct CyberPanel: ViewModifier {
    var radius: CGFloat = Theme.Radius.medium
    var active = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.Cyber.panel)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.045), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: active
                                       ? [Theme.Cyber.accent.opacity(0.95), Theme.Cyber.accent.opacity(0.25)]
                                       : [Color.white.opacity(0.10), Theme.Cyber.separator.opacity(0.55)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

extension View {
    func cyberPanel(radius: CGFloat = Theme.Radius.medium, active: Bool = false) -> some View {
        modifier(CyberPanel(radius: radius, active: active))
    }
}

/// Compact icon button used in the toolbar and transport.
struct CyberIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.Cyber.accentBright : (hovered ? Theme.Cyber.text : Theme.Cyber.secondaryText))
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Theme.Cyber.hover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Horizontal amber progress track with a glowing thumb.
struct CyberProgressBar: View {
    let value: Double
    var height: CGFloat = 18
    var thumbSize: CGFloat = 10
    var showsThumb = true
    var onLiveChange: ((Double) -> Void)? = nil
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, dragFraction ?? value))
            let width = geometry.size.width
            let thumb: CGFloat = showsThumb ? thumbSize : 0

            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let radius = size.height / 2
                    let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
                    context.fill(track, with: .color(Theme.Cyber.track))
                    context.stroke(track, with: .color(.white.opacity(0.06)), lineWidth: 1)

                    let fillWidth = max(0, size.width * fraction)
                    if fillWidth > 0.5 {
                        let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: size.height)
                        let fill = Path(roundedRect: fillRect, cornerRadius: radius)
                        context.fill(fill, with: .linearGradient(
                            Gradient(colors: [Theme.Cyber.accent.opacity(0.75), Theme.Cyber.accentBright]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: 0)))
                    }
                }

                if showsThumb {
                    Circle()
                        .fill(Theme.Cyber.accentBright)
                        .frame(width: thumb, height: thumb)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.7))
                        .shadow(color: Theme.Cyber.accent.opacity(0.85), radius: 6)
                        .offset(x: max(0, min(width - thumb, width * fraction - thumb / 2)))
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                // Seek once on release; dragging only moves the thumb.
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let next = min(1, max(0, gesture.location.x / max(1, width)))
                        dragFraction = next
                        onLiveChange?(next)
                    }
                    .onEnded { gesture in
                        onSeek(min(1, max(0, gesture.location.x / max(1, width))))
                        dragFraction = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Позиция")
            .accessibilityValue("\(Int(fraction * 100))%")
        }
        .frame(height: height)
    }
}

/// Fixed-step spectrum with a gentle live shimmer, peak caps and glow.
struct CyberSpectrum: View {
    let bands: [Float]
    var peaks: [Float] = []
    var isPlaying = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let time = isPlaying ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let barWidth: CGFloat = 3
                let gap: CGFloat = 2
                let count = max(1, Int((size.width + gap) / (barWidth + gap)))
                let step = size.width / CGFloat(count)
                let lit = Theme.Cyber.accent
                let bright = Theme.Cyber.accentBright

                var path = Path()
                for index in 0..<count {
                    let position = count > 1 ? Double(index) / Double(count - 1) : 0
                    let source = position * Double(max(0, bands.count - 1))
                    let low = min(bands.count - 1, Int(source))
                    let high = min(bands.count - 1, low + 1)
                    let blend = Float(source - Double(low))
                    let sampled = bands.isEmpty ? 0 : bands[low] * (1 - blend) + bands[high] * blend
                    let shimmer = isPlaying
                        ? Float(0.015 + 0.012 * sin(time * 4.2 + Double(index) * 0.37))
                        : 0
                    let value = min(1, max(0, sampled + shimmer))
                    let height = max(1, size.height * CGFloat(value))
                    let rect = CGRect(x: CGFloat(index) * step,
                                      y: size.height - height,
                                      width: barWidth,
                                      height: height)
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                }

                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: lit.opacity(0.35), radius: 3))
                    layer.fill(path, with: .linearGradient(
                        Gradient(colors: [lit.opacity(0.55), lit, bright]),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: CGPoint(x: 0, y: 0)))
                }

                guard peaks.count == bands.count else { return }
                for (index, rawPeak) in peaks.enumerated() {
                    let peak = min(1, max(0, rawPeak))
                    guard peak > 0.04 else { continue }
                    let position = count > 1 ? Double(index) / Double(peaks.count - 1) : 0
                    let x = CGFloat(position) * size.width
                    let y = max(0, size.height - size.height * CGFloat(peak) - 2)
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: barWidth, height: 2),
                                      cornerRadius: 1),
                                 with: .color(bright.opacity(0.9)))
                }
            }
        }
    }
}

/// One-line text that gently scrolls when it does not fit.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var height: CGFloat = 26

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                    }
                }
                .offset(x: offset)
                .onAppear { containerWidth = geometry.size.width; animateIfNeeded() }
                .onChange(of: geometry.size.width) { newWidth in
                    containerWidth = newWidth
                    animateIfNeeded()
                }
                .onPreferenceChange(TextWidthKey.self) { width in
                    textWidth = width
                    animateIfNeeded()
                }
        }
        .clipped()
        .frame(height: height)
        .onHover { inside in
            if !inside { reset() }
        }
        .help(text)
    }

    private func animateIfNeeded() {
        guard textWidth > containerWidth + 2, containerWidth > 0 else {
            reset()
            return
        }
        offset = 0
        let distance = textWidth - containerWidth
        withAnimation(.linear(duration: max(4, Double(distance / 24))).repeatForever(autoreverses: true)) {
            offset = -distance
        }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
