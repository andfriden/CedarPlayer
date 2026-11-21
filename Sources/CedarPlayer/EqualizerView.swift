import SwiftUI

/// Окно эквалайзера: крупные подписи полос, контрастная сетка дБ,
/// отдельный предусилитель, пресеты и сохранение настроек.
struct EqualizerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var customPresets: [CustomPreset] = []
    @State private var isNamingPreset = false
    @State private var newPresetName = ""

    struct CustomPreset: Codable, Identifiable, Hashable {
        var id: UUID = UUID()
        var name: String
        var gains: [Double]
        var preamp: Double
    }

    private static let storageKey = "eqCustomPresets"
    private let windowWidth: CGFloat = 760
    private let windowHeight: CGFloat = 540
    private let faderHeight: CGFloat = 318
    private let faderColumn: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            bandsArea
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(Theme.background)
        .onAppear(perform: loadCustomPresets)
        .alert("Название пресета", isPresented: $isNamingPreset) {
            TextField("Например, «Наушники»", text: $newPresetName)
            Button("Сохранить") { saveCustomPreset() }
            Button("Отмена", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Сохранится текущий набор полос и предусилитель.")
        }
    }

    // MARK: Заголовок

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Графический эквалайзер")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("10 полос · 32 Гц – 16 кГц · ±30 дБ")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !engine.isEQEnabled {
                Text("Выключен")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.subtle, in: Capsule())
            }
            Toggle("Эквалайзер", isOn: $engine.isEQEnabled)
                .toggleStyle(.switch)
                .font(Theme.Fonts.artist)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    // MARK: Полосы

    private var bandsArea: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            scaleColumn

            ZStack(alignment: .topLeading) {
                gridLines
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(engine.frequencies.enumerated()), id: \.offset) { index, frequency in
                        bandColumn(index: index, frequency: frequency)
                    }
                }
            }
            .frame(height: faderHeight + 52)

            Divider().overlay(Theme.separator).frame(height: faderHeight + 40)

            preampColumn
        }
        .disabled(!engine.isEQEnabled)
        .opacity(engine.isEQEnabled ? 1 : 0.55)
    }

    private var scaleColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 22)
            GeometryReader { geometry in
                ForEach([30, 15, 0, -15, -30], id: \.self) { value in
                    Text(String(format: "%+d", value))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(value == 0 ? Theme.text : Theme.secondaryText)
                        .frame(width: 34, alignment: .trailing)
                        .position(x: 17,
                                  y: CGFloat((30 - Double(value)) / 60) * geometry.size.height)
                }
            }
            .frame(width: 34, height: faderHeight)
        }
        .frame(width: 34, height: faderHeight + 22)
        .padding(.top, 4)
    }

    private var gridLines: some View {
        Canvas { context, size in
            let top: CGFloat = 22
            let height = faderHeight
            for value in [30.0, 15, 0, -15, -30] {
                let ratio = (30 - value) / 60
                let y = top + height * CGFloat(ratio)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                let strong = value == 0
                context.stroke(line,
                               with: .color(strong ? Color(hex: 0x3E4550) : Theme.separator.opacity(0.7)),
                               lineWidth: strong ? 1.2 : 0.8)
            }
        }
        .allowsHitTesting(false)
    }

    private func bandColumn(index: Int, frequency: Double) -> some View {
        let gain = engine.bands.indices.contains(index) ? engine.bands[index] : 0
        return VStack(spacing: Theme.Space.s) {
            Text(String(format: "%+.1f", gain))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(abs(gain) < 0.05 ? Theme.secondaryText : Theme.accent)
                .frame(height: 18)

            VerticalFader(value: Binding(
                get: { engine.bands.indices.contains(index) ? engine.bands[index] : 0 },
                set: { if engine.bands.indices.contains(index) { engine.bands[index] = $0 } }
            ), range: -30...30)
            .frame(width: 22, height: faderHeight)

            Text(frequencyLabel(frequency))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(height: 18)
        }
        .frame(width: faderColumn)
        .help("\(frequencyLabel(frequency)) · \(String(format: "%+.1f", gain)) дБ · двойной клик сбрасывает")
    }

    private var preampColumn: some View {
        VStack(spacing: Theme.Space.s) {
            Text("PREAMP")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.secondaryText)
                .frame(height: 18)

            VerticalFader(value: $engine.preamp, range: -15...15)
                .frame(width: 26, height: faderHeight)
                .help("Предусилитель: \(String(format: "%+.1f", engine.preamp)) дБ")

            Text(String(format: "%+.1f", engine.preamp))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(abs(engine.preamp) < 0.05 ? Theme.secondaryText : Theme.accent)
                .frame(height: 18)
        }
        .frame(width: 64)
    }

    private func yOffset(for value: Double) -> CGFloat {
        let ratio = (30 - value) / 60
        return faderHeight * CGFloat(ratio) - 8
    }

    // MARK: Низ

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Menu {
                ForEach(PlayerEngine.presets) { preset in
                    Button(preset.name) { engine.apply(preset: preset) }
                }
                if !customPresets.isEmpty {
                    Divider()
                    ForEach(customPresets) { preset in
                        Button(preset.name) { apply(custom: preset) }
                    }
                }
            } label: {
                Label("Пресеты", systemImage: "slider.horizontal.3")
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.separator.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 140)

            Button("Сохранить…") {
                newPresetName = ""
                isNamingPreset = true
            }
            .buttonStyle(EQActionButtonStyle())

            if !customPresets.isEmpty {
                Menu("Удалить") {
                    ForEach(customPresets) { preset in
                        Button(preset.name, role: .destructive) { delete(preset) }
                    }
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.separator.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }

            Button("Сбросить") { engine.resetEQ() }
                .buttonStyle(EQActionButtonStyle())

            Spacer()

            if let rate = engine.currentTrack?.sampleRate, rate > 0 {
                Text(String(format: "%@ кГц", rate.truncatingRemainder(dividingBy: 1000) == 0
                          ? String(format: "%.0f", rate / 1000)
                          : String(format: "%.1f", rate / 1000)))
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.secondaryText)
            }

            Button("Закрыть") { dismiss() }
                .buttonStyle(EQActionButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
        }
        .font(Theme.Fonts.artist)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func frequencyLabel(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.0fK", value / 1000) : String(format: "%.0f", value)
    }

    // MARK: Пресеты

    private func apply(custom preset: CustomPreset) {
        engine.preamp = preset.preamp
        if preset.gains.count == engine.bands.count {
            engine.bands = preset.gains
        }
        if !engine.isEQEnabled { engine.isEQEnabled = true }
    }

    private func loadCustomPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([CustomPreset].self, from: data) else { return }
        customPresets = decoded
    }

    private func saveCustomPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        customPresets.removeAll { $0.name == name }
        customPresets.append(CustomPreset(name: name, gains: engine.bands, preamp: engine.preamp))
        persist()
        newPresetName = ""
    }

    private func delete(_ preset: CustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Кнопки нижней панели: заметный фон и рамка вместо системной малозаметной.
struct EQActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.artist)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.separator.opacity(configuration.isPressed ? 0.9 : 0.6),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
    }
}

/// Вертикальный фейдер: широкий трек, заливка от нуля, белая ручка.
/// Двойной клик сбрасывает значение в ноль.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knobHeight: CGFloat = 18
            let span = range.upperBound - range.lowerBound
            let ratio = (value - range.lowerBound) / span
            let knobY = (1 - CGFloat(ratio)) * (height - knobHeight)
            let zeroRatio = CGFloat((0 - range.lowerBound) / span)
            let zeroY = (1 - zeroRatio) * (height - knobHeight) + knobHeight / 2

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.separator)
                    .frame(width: 8)
                    .frame(maxWidth: .infinity)

                // Заливка от нуля к текущему значению.
                Rectangle()
                    .fill(Theme.accent.opacity(0.55))
                    .frame(width: 8,
                           height: abs(zeroY - (knobY + knobHeight / 2)))
                    .offset(y: min(zeroY, knobY + knobHeight / 2))
                    .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(Theme.secondaryText.opacity(0.5))
                    .frame(width: 16, height: 1)
                    .offset(y: zeroY)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.text)
                    .frame(width: 20, height: knobHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.background.opacity(0.35), lineWidth: 1)
                    }
                    .offset(y: knobY)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let y = min(max(0, gesture.location.y - knobHeight / 2), height - knobHeight)
                        let t = 1 - y / (height - knobHeight)
                        value = range.lowerBound + Double(t) * span
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}
