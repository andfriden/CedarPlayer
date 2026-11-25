import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("keepMiniOnTop") private var keepMiniOnTop = true
    @AppStorage("resumeLastTrack") private var resumeLastTrack = true
    @AppStorage("showFormatColumn") private var showFormatColumn = true
    @AppStorage("autoCoverSearch") private var autoCoverSearch = true
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @State private var showDuplicates = false
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("accentChoice") private var accentChoice = AccentChoice.theme.rawValue
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Picker("Акцент", selection: $accentChoice) {
                    ForEach(AccentChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Язык") {
                Picker("Язык интерфейса", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
            }

            Section("Воспроизведение") {
                Toggle("Запоминать последний трек при запуске", isOn: $resumeLastTrack)
                Picker("Повтор", selection: $engine.repeatMode) {
                    Text("Выключен").tag(RepeatMode.off)
                    Text("Список").tag(RepeatMode.all)
                    Text("Один трек").tag(RepeatMode.one)
                }
                Toggle("Перемешивание", isOn: $engine.isShuffle)
                Picker("Плавные переходы", selection: $engine.transitionFadeSeconds) {
                    Text("Выключены").tag(0.0)
                    Text("0.5 с").tag(0.5)
                    Text("1 с").tag(1.0)
                    Text("2 с").tag(2.0)
                }
                Picker("Кроссфейд", selection: $engine.crossfadeSeconds) {
                    Text("Выключен").tag(0.0)
                    Text("2 с").tag(2.0)
                    Text("4 с").tag(4.0)
                    Text("6 с").tag(6.0)
                }
                Toggle("Выравнивать громкость (ReplayGain)", isOn: $engine.isReplayGainEnabled)
                Text("Громкость подстраивается по тегам REPLAYGAIN_TRACK_GAIN и пику трека; буст ограничен +6 дБ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Вывод звука") {
                Picker("Устройство", selection: Binding(
                    get: { engine.selectedOutputUID ?? "" },
                    set: { engine.selectOutput(uid: $0) }
                )) {
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                HStack {
                    Text("Формат вывода")
                    Spacer()
                    Text(engine.outputFormatDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("Обновить список устройств") {
                    engine.refreshOutputDevices()
                }
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

            Section("Папки наблюдения") {
                ForEach(library.watchFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Убрать", role: .destructive) {
                            library.removeWatchFolder(folder)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Добавить папку…") {
                    library.presentWatchFolderPanel()
                }
                Text("Новые аудиофайлы в этих папках добавляются в библиотеку автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Обновления") {
                Toggle("Проверять обновления при запуске", isOn: $checkForUpdates)
            }

            Section("Окна") {
                Toggle("Мини-плеер поверх остальных окон", isOn: $keepMiniOnTop)
            }

            Section("Библиотека") {
                Toggle("Искать обложки при импорте", isOn: $autoCoverSearch)
                Text("Для треков без обложки запрос идёт в iTunes и Deezer; нужен интернет.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Показывать формат и частоту дискретизации", isOn: $showFormatColumn)
                Button(L10n.string("Найти дубликаты…")) { showDuplicates = true }
                Button(L10n.string("Перепривязать отсутствующие файлы…")) {
                    library.presentBatchRelinkPanel()
                }
                HStack {
                    Text(L10n.format("Треков в библиотеке: %ld", library.tracks.count))
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
        .frame(width: 460, height: 480)
        .padding(.vertical, 8)
        .sheet(isPresented: $showDuplicates) {
            DuplicateFinderView()
                .environmentObject(library)
        }
    }
}
