import SwiftUI

/// Окно эквалайзера: вертикальные фейдеры, сетка дБ, отдельный Preamp,
/// пресеты и сохранение настроек.
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
    private let scaleValues: [Double] = [30, 20, 10, 0, -10, -20, -30]
    private let faderTop: CGFloat = 82
    private let faderHeight: CGFloat = 240
    private let faderStep: CGFloat = 26
    private let firstFaderX: CGFloat = 100
    private let faderWidth: CGFloat = 15

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            title

            preampFader
                .disabled(!engine.isEQEnabled)
                .opacity(engine.isEQEnabled ? 1 : 0.45)

            dbGrid
                .opacity(engine.isEQEnabled ? 1 : 0.45)

            bandFaders
                .disabled(!engine.isEQEnabled)
                .opacity(engine.isEQEnabled ? 1 : 0.45)

            bottomPanel
        }
        .frame(width: 700, height: 480)
        .onAppear(perform: loadCustomPresets)
        .alert("Название пресета", isPresented: $isNamingPreset) {
            TextField("Например, «Наушники»", text: $newPresetName)
            Button("Сохранить") { saveCustomPreset() }
            Button("Отмена", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Сохранится текущий набор полос и предусилитель.")
        }
    }

    // MARK: Фон

    private var background: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: Заголовок

    private var title: some View {
        HStack {
            Text("Графический эквалайзер")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 300, alignment: .center)
            Spacer()
            Toggle("Эквалайзер", isOn: $engine.isEQEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 90)
        .padding(.top, 12)
        .frame(width: 700, alignment: .top)
    }

    // MARK: Предусилитель

    private var preampFader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Preamp")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(String(format: "%+.1f", engine.preamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(height: faderHeight)

            VerticalFader(value: $engine.preamp, range: -15...15)
                .frame(width: faderWidth, height: faderHeight)
                .help("Предусилитель: \(String(format: "%+.1f", engine.preamp)) дБ")
        }
        .frame(width: 80, height: faderHeight, alignment: .leading)
        .position(x: 40, y: faderTop + faderHeight / 2)
    }

    // MARK: Сетка дБ

    private var gridWidth: CGFloat {
        CGFloat(max(0, engine.frequencies.count - 1)) * faderStep + faderWidth
    }

    private var dbGrid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scaleValues, id: \.self) { value in
                let ratio = (30 - value) / 60
                let y = faderTop + faderHeight * CGFloat(ratio)
                HStack(spacing: 6) {
                    Text(String(format: "%+.0f", value))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 22, alignment: .trailing)
                    Rectangle()
                        .fill(.white.opacity(value == 0 ? 0.22 : 0.10))
                        .frame(width: gridWidth, height: value == 0 ? 1.2 : 0.7)
                }
                .offset(x: 72, y: y)
            }
        }
    }

    // MARK: Полосы

    private var bandFaders: some View {
        ForEach(Array(engine.frequencies.enumerated()), id: \.offset) { index, frequency in
            let x = firstFaderX + CGFloat(index) * faderStep
            VStack(spacing: 6) {
                Text(frequencyLabel(frequency))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 34)
                VerticalFader(value: Binding(
                    get: { engine.bands[index] },
                    set: { engine.bands[index] = $0 }
                ), range: -30...30)
                .frame(width: faderWidth, height: faderHeight)
                Text(String(format: "%+.0f", engine.bands[index]))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .position(x: x + faderWidth / 2, y: faderTop + faderHeight / 2 - 6)
            .help("\(frequencyLabel(frequency)): \(String(format: "%+.1f", engine.bands[index])) дБ")
        }
    }

    // MARK: Низ

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
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
                    Text("Пресеты")
                        .frame(width: 130)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 140)

                Button("Сохранить…") {
                    newPresetName = ""
                    isNamingPreset = true
                }

                if !customPresets.isEmpty {
                    Menu("Удалить") {
                        ForEach(customPresets) { preset in
                            Button(preset.name, role: .destructive) { delete(preset) }
                        }
                    }
                    .frame(width: 90)
                }

                Button("Сбросить") { engine.resetEQ() }

                Spacer()

                if let rate = engine.currentTrack?.sampleRate, rate > 0 {
                    Text(String(format: "%@ кГц", rate.truncatingRemainder(dividingBy: 1000) == 0
                              ? String(format: "%.0f", rate / 1000)
                              : String(format: "%.1f", rate / 1000)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 700, height: 100, alignment: .bottom)
        .position(x: 350, y: 480 - 50)
    }

    private func frequencyLabel(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fK", value / 1000) : String(format: "%.0f", value)
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

/// Вертикальный фейдер 19 px: свой трек, ручка, сброс двойным щелчком.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knobHeight: CGFloat = 12
            let span = range.upperBound - range.lowerBound
            let ratio = (value - range.lowerBound) / span
            let knobY = (1 - CGFloat(ratio)) * (height - knobHeight)
            let zeroY = (1 - CGFloat((0 - range.lowerBound) / span)) * (height - knobHeight) + knobHeight / 2

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.08))
                    .frame(width: 7)
                    .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 13, height: 1)
                    .offset(y: zeroY)

                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.65)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 15, height: knobHeight)
                    .offset(y: knobY)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
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
