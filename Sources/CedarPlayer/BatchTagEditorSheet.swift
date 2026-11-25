import SwiftUI

struct BatchTagRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

/// Applies one set of tag values to several selected tracks.
struct BatchTagEditorSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    let tracks: [Track]

    @State private var setArtist = false
    @State private var setAlbum = false
    @State private var setAlbumArtist = false
    @State private var setGenre = false
    @State private var setYear = false
    @State private var setComposer = false

    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var composer: String

    @State private var errorMessage: String?
    @State private var finished = false

    init(tracks: [Track]) {
        self.tracks = tracks
        let first = tracks.first
        _artist = State(initialValue: first?.artist ?? "")
        _album = State(initialValue: first?.album ?? "")
        _albumArtist = State(initialValue: first?.albumArtist ?? "")
        _genre = State(initialValue: first?.genre ?? "")
        _year = State(initialValue: first?.year ?? "")
        _composer = State(initialValue: first?.composer ?? "")
    }

    private var canApply: Bool {
        setArtist || setAlbum || setAlbumArtist || setGenre || setYear || setComposer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Массовая правка тегов"))
                .font(.system(size: 16, weight: .semibold))
            Text(L10n.format("Выбрано треков: %ld", tracks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.string("Отметьте поля, которые нужно изменить. Названия и номера треков не меняются."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Исполнитель", text: $artist, enabled: $setArtist)
            field("Альбом", text: $album, enabled: $setAlbum)
            field("Исполнитель альбома", text: $albumArtist, enabled: $setAlbumArtist)
            field("Жанр", text: $genre, enabled: $setGenre)
            field("Год", text: $year, enabled: $setYear)
            field("Композитор", text: $composer, enabled: $setComposer)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.40))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if finished {
                    Button(L10n.string("Закрыть")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.string("Отмена")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.string("Применить")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canApply)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }

    private func field(_ caption: String, text: Binding<String>, enabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(caption, isOn: enabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .medium))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(!enabled.wrappedValue)
                .opacity(enabled.wrappedValue ? 1 : 0.45)
        }
    }

    private func apply() {
        guard canApply else { return }
        var updated = 0
        var failures = 0
        var firstFailure: String?

        for track in tracks {
            let edit = TagEdit(
                title: track.title,
                artist: setArtist ? trimmed(artist) : track.artist,
                album: setAlbum ? trimmed(album) : track.album,
                albumArtist: setAlbumArtist ? trimmed(albumArtist) : track.albumArtist,
                trackNumber: track.trackNumber,
                genre: setGenre ? trimmed(genre) : track.genre,
                year: setYear ? trimmed(year) : track.year,
                composer: setComposer ? trimmed(composer) : track.composer
            )
            do {
                if let changed = try library.applyTags(edit, to: track.id) {
                    updated += 1
                    if engine.currentTrack?.id == changed.id {
                        engine.syncCurrentTrack(with: changed)
                    }
                }
            } catch {
                failures += 1
                if firstFailure == nil {
                    firstFailure = "\(track.url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }

        let summary = L10n.format("Обновлено: %ld из %ld", updated, tracks.count)
        library.statusMessage = summary
        if failures == 0 {
            dismiss()
        } else {
            errorMessage = L10n.format("Обновлено: %ld из %ld; ошибок: %ld. %@",
                                       updated, tracks.count, failures, firstFailure ?? "")
            finished = true
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
