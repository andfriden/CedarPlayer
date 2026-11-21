import SwiftUI

/// Лист правки тегов выбранного трека.
struct TagEditorSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    let track: Track

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var trackNumber: String
    @State private var genre: String
    @State private var year: String
    @State private var composer: String
    @State private var errorMessage: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _albumArtist = State(initialValue: track.albumArtist)
        _trackNumber = State(initialValue: track.trackNumber > 0 ? String(track.trackNumber) : "")
        _genre = State(initialValue: track.genre)
        _year = State(initialValue: track.year)
        _composer = State(initialValue: track.composer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(track.url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            field("Название", text: $title)
            field("Исполнитель", text: $artist)
            field("Альбом", text: $album)
            field("Исполнитель альбома", text: $albumArtist)
            field("Номер трека", text: $trackNumber)
            field("Жанр", text: $genre)
            field("Год", text: $year)
            field("Композитор", text: $composer)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.40))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.panel)
    }

    private func field(_ caption: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func save() {
        let edit = TagEdit(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                           album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                           albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                           trackNumber: Int(trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                           genre: genre.trimmingCharacters(in: .whitespacesAndNewlines),
                           year: year.trimmingCharacters(in: .whitespacesAndNewlines),
                           composer: composer.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            if let updated = try library.applyTags(edit, to: track.id) {
                engine.syncCurrentTrack(with: updated)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let editTags = Notification.Name("cedar.editTags")
}
