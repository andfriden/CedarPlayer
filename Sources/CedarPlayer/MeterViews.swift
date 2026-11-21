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
    var spectrumPeaks: [Float] = []
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
        let dotCount = 42
        let dot: CGFloat = 5
        let step = (size.width - dot) / CGFloat(dotCount - 1)

        for (row, pair) in [(0, (levelLeft, peakLeft)), (1, (levelRight, peakRight))] {
            let y = CGFloat(row) * (barHeight + 3) + (barHeight - dot) / 2
            let level = CGFloat(min(1, max(0, pair.0)))
            let lit = Int((level * CGFloat(dotCount)).rounded())

            for index in 0..<dotCount {
                let rect = CGRect(x: CGFloat(index) * step, y: y, width: dot, height: dot)
                if index < lit {
                    let colorIndex = index * segments / dotCount
                    context.fill(Path(ellipseIn: rect), with: .color(zoneColor(index: colorIndex)))
                } else {
                    context.fill(Path(ellipseIn: rect), with: .color(unlitColor))
                }
            }

            let peak = CGFloat(min(1, max(0, pair.1)))
            if peak > 0.02 {
                let peakIndex = Int((peak * CGFloat(dotCount - 1)).rounded())
                let rect = CGRect(x: CGFloat(peakIndex) * step, y: y, width: dot, height: dot)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
            }
        }
    }

    // MARK: Спектр

    private func drawSpectrum(context: GraphicsContext, size: CGSize) {
        guard !bands.isEmpty else { return }
        let gap: CGFloat = 1.4
        let width = max(1, (size.width - gap * CGFloat(bands.count - 1)) / CGFloat(bands.count))

        let gradient = Gradient(colors: [
            Color(red: 0.32, green: 0.86, blue: 0.46),
            Color(red: 0.98, green: 0.74, blue: 0.22),
            Color(red: 0.98, green: 0.30, blue: 0.26)
        ])

        for (index, value) in bands.enumerated() {
            let level = CGFloat(min(1, max(0, value)))
            guard level > 0.004 else { continue }
            let height = max(1.5, size.height * level)
            let rect = CGRect(x: CGFloat(index) * (width + gap),
                              y: size.height - height,
                              width: width, height: height)
            // Градиент по высоте, как у спектральных визуализаторов плееров.
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2.6),
                         with: .linearGradient(gradient,
                                               startPoint: CGPoint(x: 0, y: size.height),
                                               endPoint: CGPoint(x: 0, y: 0)))
        }

        // Пики: отдельные штрихи над столбиками, медленно сползают вниз.
        guard spectrumPeaks.count == bands.count else { return }
        for (index, value) in spectrumPeaks.enumerated() {
            let peak = CGFloat(min(1, max(0, value)))
            guard peak > 0.015 else { continue }
            let y = size.height - size.height * peak
            let rect = CGRect(x: CGFloat(index) * (width + gap),
                              y: max(0, y - 2),
                              width: width, height: 2)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)))
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
        monochrome ? Theme.separator.opacity(0.9) : Theme.separator.opacity(0.75)
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

/// Уровни для отрисовки прибора: сырые (0…1) и пики.
struct VULevels {
    var left: Float
    var right: Float
    var peakLeft: Float
    var peakRight: Float
}

/// Окно аналогового VU-метра: два калиброванных прибора L/R.
/// 0 VU = −20 dBFS, шкала −20…+3 VU, баллистика 300 мс. Громкости здесь нет.
struct AnalogVUMeterView: View {
    @EnvironmentObject private var engine: PlayerEngine
    var preview: VULevels?

    @State private var needleL: Double
    @State private var needleR: Double
    @State private var lastTick: Date?
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(preview: VULevels? = nil) {
        self.preview = preview
        // Для офскрин-рендера и тестов сразу ставим стрелки по переданным уровням.
        _needleL = State(initialValue: VUCalibration.position(forLevel: Double(preview?.left ?? 0)))
        _needleR = State(initialValue: VUCalibration.position(forLevel: Double(preview?.right ?? 0)))
    }

    private var levels: VULevels {
        preview ?? VULevels(left: engine.rawLevelL,
                            right: engine.rawLevelR,
                            peakLeft: engine.peakL,
                            peakRight: engine.peakR)
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                dial(needle: needleL, peak: levels.peakLeft, title: "L")
                dial(needle: needleR, peak: levels.peakRight, title: "R")
            }

            Text("0 VU = \(String(format: "%.0f", VUCalibration.zeroVUdBFS)) dBFS · интеграция 300 мс")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.opacity(0.8))
                .frame(height: 16)
        }
        .padding(Theme.Space.s)
        .frame(width: 520, height: 300)
        .background(Theme.panel)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.separator, lineWidth: 1)
                .padding(1)
        }
        .onReceive(tick) { now in
            let dt = now.timeIntervalSince(lastTick ?? now)
            lastTick = now
            guard dt > 0 else { return }
            // Стандартная баллистика VU: 300 мс.
            let alpha = 1 - exp(-dt / 0.3)
            // На паузе стрелки возвращаются к левому краю, а не висят на последнем уровне.
            let active = preview != nil || engine.isPlaying
            let targetL = active ? VUCalibration.position(forLevel: Double(levels.left)) : 0
            let targetR = active ? VUCalibration.position(forLevel: Double(levels.right)) : 0
            needleL += (targetL - needleL) * alpha
            needleR += (targetR - needleR) * alpha
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "VU-метр: левый %+.1f, правый %+.1f",
                                   VUCalibration.vu(fromPosition: needleL),
                                   VUCalibration.vu(fromPosition: needleR)))
    }

    private func dial(needle: Double, peak: Float, title: String) -> some View {
        Canvas { context, size in
            drawDial(context: context, size: size, needle: needle, peak: peak, title: title)
        }
        .frame(width: 244, height: 250)
        .accessibilityHidden(true)
    }

    private func drawDial(context: GraphicsContext, size: CGSize, needle: Double, peak: Float, title: String) {
        let pivot = CGPoint(x: size.width / 2, y: size.height - 42)
        let radius = min(size.width * 0.5, size.height * 0.62)

        var arc = Path()
        arc.addArc(center: pivot, radius: radius,
                   startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)
        context.stroke(arc, with: .color(Theme.separator),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Красная зона начинается ровно с риски 0 VU.
        let redStart = 225 + 90 * Double(VUCalibration.marks.count - 2) / Double(VUCalibration.marks.count - 1)
        var redZone = Path()
        redZone.addArc(center: pivot, radius: radius,
                       startAngle: .degrees(redStart), endAngle: .degrees(315), clockwise: false)
        context.stroke(redZone, with: .color(Color(hex: 0xE06C75)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        for (index, mark) in VUCalibration.marks.enumerated() {
            let t = Double(index) / Double(VUCalibration.marks.count - 1)
            let angle = 225 + 90 * t
            let isZero = mark.vu == 0
            let isHot = mark.vu > 0
            let inner = point(pivot, radius - (isZero ? 10 : 7), angle)
            let outer = point(pivot, radius + (isHot ? 4 : 0), angle)

            var tick = Path()
            tick.move(to: inner)
            tick.addLine(to: outer)
            context.stroke(tick,
                           with: .color(isZero ? Theme.text : (isHot ? Color(hex: 0xE06C75) : Theme.secondaryText)),
                           lineWidth: isZero ? 1.4 : 0.8)

            let labelPoint = point(pivot, radius + 18, angle)
            let label = Text(mark.label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(isZero ? Theme.text : (isHot ? Color(hex: 0xE06C75) : Theme.secondaryText))
            context.draw(context.resolve(label), at: labelPoint, anchor: .center)
        }

        let angle = 225 + 90 * min(max(needle, 0), 1)
        let tip = point(pivot, radius - 6, angle)
        var line = Path()
        line.move(to: pivot)
        line.addLine(to: tip)
        context.stroke(line, with: .color(Theme.accent),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        var dot = Path()
        dot.addEllipse(in: CGRect(x: pivot.x - 3.5, y: pivot.y - 3.5, width: 7, height: 7))
        context.fill(dot, with: .color(Theme.text))

        let vu = Text("VU")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.secondaryText.opacity(0.6))
        context.draw(context.resolve(vu), at: CGPoint(x: size.width / 2, y: 30), anchor: .center)

        // LED загорается вместе со стрелкой в красной зоне, без рассинхрона по пику.
        let peakLit = needle >= VUCalibration.position(forVU: 0)
        let led = CGRect(x: size.width - 22, y: 18, width: 8, height: 8)
        context.fill(Path(ellipseIn: led),
                     with: .color(peakLit ? Color(hex: 0xE06C75) : Theme.separator))

        let channel = Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.text)
        context.draw(context.resolve(channel), at: CGPoint(x: 18, y: size.height - 18), anchor: .leading)

        let reading = Text(String(format: "%+.1f VU", VUCalibration.vu(fromPosition: needle)))
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(Theme.secondaryText)
        context.draw(context.resolve(reading), at: CGPoint(x: size.width - 18, y: size.height - 18), anchor: .trailing)
    }

    private func point(_ pivot: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: pivot.x + CGFloat(cos(radians)) * radius,
                       y: pivot.y + CGFloat(sin(radians)) * radius)
    }
}
