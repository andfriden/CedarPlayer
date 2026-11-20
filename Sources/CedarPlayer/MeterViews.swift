import SwiftUI

/// Стили индикатора уровня и отдельное окно аналогового VU-метра.
enum MeterStyle: String, CaseIterable, Identifiable {
    case segments
    case bar
    case dots
    case spectrum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .segments: return "Сегменты"
        case .bar: return "Сплошная шкала"
        case .dots: return "Точка с пиком"
        case .spectrum: return "Спектр"
        }
    }
}

/// Индикатор уровня 250×44: L/R, пики, разметка в дБ.
struct LevelMeterStrip: View {
    var style: MeterStyle = .segments
    var levelLeft: Float
    var levelRight: Float
    var peakLeft: Float
    var peakRight: Float
    var bands: [Float] = []
    var isPlaying: Bool
    var showsScale: Bool = true
    var monochrome: Bool = false

    private let segments = 56
    private let scaleMarks: [(Float, String)] = [
        (0.00, "-60"), (0.33, "-40"), (0.67, "-20"), (0.80, "-12"), (0.90, "-6"), (1.00, "0")
    ]

    var body: some View {
        Canvas { context, size in
            switch style {
            case .segments: drawSegments(context: context, size: size)
            case .bar: drawBars(context: context, size: size)
            case .dots: drawDots(context: context, size: size)
            case .spectrum: drawSpectrum(context: context, size: size)
            }
            if showsScale {
                drawScale(context: context, size: size)
            }
        }
        .opacity(isPlaying ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    // MARK: Сегменты

    private func drawSegments(context: GraphicsContext, size: CGSize) {
        let gap: CGFloat = 1.6
        let barHeight = rowHeight(size)
        let segmentWidth = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)

        drawSegmentRow(context: context, size: size, y: 0, height: barHeight,
                       value: levelLeft, peak: peakLeft, width: segmentWidth, gap: gap)
        drawSegmentRow(context: context, size: size, y: barHeight + 3, height: barHeight,
                       value: levelRight, peak: peakRight, width: segmentWidth, gap: gap)
    }

    private func drawSegmentRow(context: GraphicsContext, size: CGSize, y: CGFloat, height: CGFloat,
                                value: Float, peak: Float, width: CGFloat, gap: CGFloat) {
        let lit = Int((CGFloat(min(1, max(0, value))) * CGFloat(segments)).rounded())
        let peakSegment = Int((CGFloat(min(1, max(0, peak))) * CGFloat(segments - 1)).rounded())

        for index in 0..<segments {
            let rect = CGRect(x: CGFloat(index) * (width + gap), y: y, width: width, height: height)
            let path = Path(roundedRect: rect, cornerRadius: 0.6)
            if index < lit {
                context.fill(path, with: .color(zoneColor(index: index)))
            } else {
                context.fill(path, with: .color(unlitColor))
            }
            if index == peakSegment && peak > 0.02 {
                context.fill(path, with: .color(.white.opacity(0.85)))
            }
        }
        _ = size
    }

    // MARK: Сплошные шкалы

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let barHeight = rowHeight(size)
        for (row, pair) in [(0, (levelLeft, peakLeft)), (1, (levelRight, peakRight))] {
            let y = CGFloat(row) * (barHeight + 3)
            let rect = CGRect(x: 0, y: y, width: size.width, height: barHeight)
            let background = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(background, with: .color(unlitColor))

            let level = CGFloat(min(1, max(0, pair.0)))
            let fillRect = CGRect(x: 0, y: y, width: size.width * level, height: barHeight)
            let fill = Path(roundedRect: fillRect, cornerRadius: 3)
            if monochrome {
                context.fill(fill, with: .color(Theme.accent.opacity(0.9)))
            } else {
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.32, green: 0.86, blue: 0.46),
                                      Color(red: 0.98, green: 0.74, blue: 0.22),
                                      Color(red: 0.98, green: 0.30, blue: 0.26)]),
                    startPoint: CGPoint(x: 0, y: y),
                    endPoint: CGPoint(x: size.width, y: y)
                ))
            }

            let peak = CGFloat(min(1, max(0, pair.1)))
            if peak > 0.02 {
                var marker = Path()
                let x = size.width * peak
                marker.move(to: CGPoint(x: x, y: y))
                marker.addLine(to: CGPoint(x: x, y: y + barHeight))
                context.stroke(marker, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }
    }

    // MARK: Точка с пиком

    private func drawDots(context: GraphicsContext, size: CGSize) {
        let barHeight = rowHeight(size)
        let dot: CGFloat = 6
        for (row, pair) in [(0, (levelLeft, peakLeft)), (1, (levelRight, peakRight))] {
            let y = CGFloat(row) * (barHeight + 3) + (barHeight - dot) / 2
            let track = CGRect(x: 0, y: y + dot / 2 - 0.5, width: size.width, height: 1)
            context.fill(Path(track), with: .color(unlitColor))

            let level = CGFloat(min(1, max(0, pair.0)))
            let x = size.width * level - dot / 2
            let circle = Path(ellipseIn: CGRect(x: max(-dot / 2, x), y: y, width: dot, height: dot))
            context.fill(circle, with: .color(zoneColor(index: Int(level * CGFloat(segments - 1)))))

            let peak = CGFloat(min(1, max(0, pair.1)))
            if peak > 0.02 {
                let peakX = size.width * peak - 0.75
                var line = Path()
                line.move(to: CGPoint(x: peakX, y: y))
                line.addLine(to: CGPoint(x: peakX, y: y + dot))
                context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
    }

    // MARK: Спектр

    private func drawSpectrum(context: GraphicsContext, size: CGSize) {
        guard !bands.isEmpty else { return }
        let gap: CGFloat = 1.4
        let width = max(1, (size.width - gap * CGFloat(bands.count - 1)) / CGFloat(bands.count))
        for (index, value) in bands.enumerated() {
            let level = CGFloat(min(1, max(0, value)))
            let height = max(1, size.height * level)
            let rect = CGRect(x: CGFloat(index) * (width + gap),
                              y: size.height - height,
                              width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2.6),
                         with: .color(zoneColor(index: Int(level * CGFloat(segments - 1))).opacity(0.9)))
        }
    }

    // MARK: Шкала

    private func drawScale(context: GraphicsContext, size: CGSize) {
        let scaleY = 36.0
        for (position, label) in scaleMarks {
            let x = size.width * CGFloat(position)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: scaleY))
            tick.addLine(to: CGPoint(x: x, y: scaleY + 3))
            context.stroke(tick, with: .color(.white.opacity(0.28)), lineWidth: 0.5)
            let text = Text(label)
                .font(.system(size: 6.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.32))
            context.draw(context.resolve(text), at: CGPoint(x: x, y: scaleY + 7), anchor: .center)
        }
    }

    private func rowHeight(_ size: CGSize) -> CGFloat {
        showsScale ? 15 : max(4, (size.height - 3) / 2)
    }

    private var unlitColor: Color {
        monochrome ? Theme.separator.opacity(0.9) : .white.opacity(0.055)
    }

    private func zoneColor(index: Int) -> Color {
        let ratio = Double(index) / Double(segments - 1)
        if monochrome {
            return Theme.accent.opacity(0.55 + 0.45 * ratio)
        }
        if ratio > 0.90 { return Color(red: 0.98, green: 0.30, blue: 0.26) }
        if ratio > 0.78 { return Color(red: 0.98, green: 0.74, blue: 0.22) }
        return Color(red: 0.32, green: 0.86, blue: 0.46)
    }
}

/// Окно аналогового VU-метра: стрелки L/R, шкала −20…+3 дБ, индикация перегруза.
struct AnalogVUMeterView: View {
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                drawFace(context: context, size: size, level: engine.levelL, mirrored: false)
                drawFace(context: context, size: size, level: engine.levelR, mirrored: true)
            }
            .frame(width: 440, height: 210)

            HStack(spacing: 18) {
                Text("L").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: $engine.volume, in: 0...1).frame(width: 160).controlSize(.mini)
                Text("R").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 472, height: 276)
        .tint(Theme.accent)
        .background(
            LinearGradient(colors: [Theme.background, Theme.background],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func drawFace(context: GraphicsContext, size: CGSize, level: Float, mirrored: Bool) {
        let width = size.width / 2
        let originX = mirrored ? width * 1.5 : width * 0.5
        let pivot = CGPoint(x: originX, y: size.height - 18)
        let radius = min(width * 0.42, 78)

        // Шкала: дуга от -45° до +45°
        var arc = Path()
        arc.addArc(center: pivot, radius: radius,
                   startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)
        context.stroke(arc, with: .color(.white.opacity(0.25)), lineWidth: 1)

        // Риски −20…+3 дБ
        let marks: [Double] = [-20, -10, -7, -5, -3, -1, 0, 3]
        for (index, db) in marks.enumerated() {
            let t = Double(index) / Double(marks.count - 1)
            let angle = Angle.degrees(225 + 90 * t)
            let inner = point(from: pivot, radius: radius - 6, angle: angle)
            let outer = point(from: pivot, radius: radius + (db >= 0 ? 5 : 0), angle: angle)
            var tick = Path()
            tick.move(to: inner)
            tick.addLine(to: outer)
            context.stroke(tick, with: .color(db >= 0 ? Color.red.opacity(0.8) : .white.opacity(0.45)),
                           lineWidth: db >= 0 ? 1.2 : 0.7)

            let label = Text(String(format: "%+.0f", db))
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            let labelPoint = point(from: pivot, radius: radius + 13, angle: angle)
            context.draw(context.resolve(label), at: labelPoint, anchor: .center)
        }

        // Стрелка
        let levelValue = Double(min(1, max(0, level)))
        let needleAngle = Angle.degrees(225 + 90 * levelValue)
        var needle = Path()
        needle.move(to: pivot)
        needle.addLine(to: point(from: pivot, radius: radius - 4, angle: needleAngle))
        context.stroke(needle, with: .color(.white.opacity(0.92)), lineWidth: 1.6)
        context.fill(Path(ellipseIn: CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6)),
                     with: .color(.white.opacity(0.85)))

        if level > 0.94 {
            var lamp = Path()
            lamp.addEllipse(in: CGRect(x: originX - 5, y: 6, width: 10, height: 10))
            context.fill(lamp, with: .color(.red.opacity(0.9)))
        }
    }

    private func point(from center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle.radians),
                y: center.y + radius * sin(angle.radians))
    }
}
