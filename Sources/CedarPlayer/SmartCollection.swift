import SwiftUI

/// User-defined smart collection. All populated conditions must match.
struct SmartCollection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var minimumRating = 0
    var genre = ""
    var year = ""
    var onlyWithArtwork = false
    var addedWithinDays = 0
    var minimumDurationMinutes = 0

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        if minimumRating > 0, track.rating < minimumRating { return false }
        let genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        if !genre.isEmpty, !track.genre.localizedCaseInsensitiveContains(genre) { return false }
        let year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        if !year.isEmpty, track.year != year { return false }
        if onlyWithArtwork, track.artwork == nil { return false }
        if addedWithinDays > 0,
           now.timeIntervalSince(track.addedAt) > Double(addedWithinDays) * 86_400 { return false }
        if minimumDurationMinutes > 0,
           track.duration < Double(minimumDurationMinutes) * 60 { return false }
        return true
    }

    func filter(_ tracks: [Track], now: Date = Date()) -> [Track] {
        tracks.filter { matches($0, now: now) }
    }
}

struct SmartCollectionEditor: View {
    let initial: SmartCollection
    let onSave: (SmartCollection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartCollection

    init(collection: SmartCollection, onSave: @escaping (SmartCollection) -> Void) {
        initial = collection
        self.onSave = onSave
        _draft = State(initialValue: collection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.string("Название")) {
                    TextField(L10n.string("Название подборки"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                Section(L10n.string("Условия")) {
                    Picker(L10n.string("Минимальный рейтинг"), selection: $draft.minimumRating) {
                        Text(L10n.string("Любой")).tag(0)
                        ForEach(1...5, id: \.self) { value in
                            Text(String(repeating: "★", count: value)).tag(value)
                        }
                    }
                    TextField(L10n.string("Жанр"), text: $draft.genre)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.string("Год"), text: $draft.year)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L10n.string("Только с обложкой"), isOn: $draft.onlyWithArtwork)
                    Picker(L10n.string("Добавлены за"), selection: $draft.addedWithinDays) {
                        Text(L10n.string("За всё время")).tag(0)
                        Text(L10n.string("7 дней")).tag(7)
                        Text(L10n.string("30 дней")).tag(30)
                        Text(L10n.string("90 дней")).tag(90)
                        Text(L10n.string("365 дней")).tag(365)
                    }
                    Stepper(value: $draft.minimumDurationMinutes, in: 0...240, step: 5) {
                        Text(L10n.format("Минимальная длительность: %ld мин", draft.minimumDurationMinutes))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L10n.string("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("Сохранить")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
    }

    private func save() {
        var collection = draft
        collection.name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collection.name.isEmpty else { return }
        onSave(collection)
        dismiss()
    }
}
