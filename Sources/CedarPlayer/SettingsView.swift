import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("keepMiniOnTop") private var keepMiniOnTop = true
    @AppStorage("resumeLastTrack") private var resumeLastTrack = true
    @AppStorage("showFormatColumn") private var showFormatColumn = true
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        Form {
            Section("Воспроизведение") {
                Toggle("Запоминать последний трек при запуске", isOn: $resumeLastTrack)
                Picker("Повтор", selection: $engine.repeatMode) {
                    Text("Выключен").tag(RepeatMode.off)
                    Text("Список").tag(RepeatMode.all)
                    Text("Один трек").tag(RepeatMode.one)
                }
                Toggle("Перемешивание", isOn: $engine.isShuffle)
            }

            Section("Индикатор") {
                Picker("Стиль", selection: Binding(
                    get: { MeterStyle(rawValue: UserDefaults.standard.string(forKey: "meterStyle") ?? "") ?? .segments },
                    set: { UserDefaults.standard.set($0.rawValue, forKey: "meterStyle") }
                )) {
                    ForEach(MeterStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }

            Section("Окна") {
                Toggle("Мини-плеер поверх остальных окон", isOn: $keepMiniOnTop)
            }

            Section("Библиотека") {
                Toggle("Показывать формат и частоту дискретизации", isOn: $showFormatColumn)
                HStack {
                    Text("Треков в библиотеке: \(library.tracks.count)")
                    Spacer()
                    Button("Показать папку данных") {
                        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("CedarPlayer")
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("О звуке") {
                Text("Эквалайзер построен на AVAudioUnitEQ (10 полос, ±12 дБ) и работает в реальном времени. Форматы с нативной поддержкой Core Audio: MP3, AAC/M4A, ALAC, WAV, AIFF, FLAC, CAF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
        .padding(.vertical, 8)
    }
}
