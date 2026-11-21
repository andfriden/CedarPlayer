import SwiftUI
import AppKit

/// Поиск и выбор обложки из внешних баз (iTunes, Cover Art Archive).
struct CoverPickerSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    let track: Track

    @State private var candidates: [CoverCandidate] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedID: UUID?
    @State private var applyToAlbum = true
    @State private var embedInFile = true

    private var canEmbed: Bool {
        ["flac", "mp3"].contains(track.url.pathExtension.lowercased())
    }

    private var queryTitle: String {
        if !track.album.isEmpty { return track.album }
        return track.displayTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Обложка для «\(queryTitle)»")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text([track.displayArtist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            content

            Toggle("Применить ко всему альбому", isOn: $applyToAlbum)
                .font(Theme.Fonts.artist)
                .disabled(track.album.isEmpty)

            Toggle("Встроить обложку в файл (FLAC, MP3)", isOn: $embedInFile)
                .font(Theme.Fonts.artist)
                .disabled(!canEmbed)

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Применить") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480, height: 440)
        .background(Theme.panel)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: Theme.Space.s) {
                ProgressView()
                Text("Ищу обложку в базах…")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.secondaryText)
                Text(errorMessage)
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: Theme.Space.m)],
                          spacing: Theme.Space.m) {
                    ForEach(candidates) { candidate in
                        Button {
                            selectedID = candidate.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        if let image = NSImage(data: candidate.imageData) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                                            .strokeBorder(selectedID == candidate.id ? Theme.accent : Theme.separator,
                                                          lineWidth: selectedID == candidate.id ? 2 : 1)
                                    }
                                Text(candidate.album)
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(candidate.artist)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        guard !track.album.isEmpty else {
            errorMessage = "У трека нет названия альбома — базу не найти. Впишите альбом в тегах и повторите."
            return
        }
        do {
            candidates = try await CoverArtService.shared.search(artist: artist, album: track.album)
            if candidates.isEmpty { errorMessage = "Обложка не найдена" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply() {
        guard let candidate = candidates.first(where: { $0.id == selectedID }) else { return }
        var ids: Set<UUID> = [track.id]
        if applyToAlbum, !track.album.isEmpty {
            ids.formUnion(library.albumTrackIDs(for: track))
        }
        library.setArtwork(candidate.imageData, for: ids)

        var failures = 0
        if embedInFile {
            for id in ids {
                guard let target = library.track(with: id),
                      ["flac", "mp3"].contains(target.url.pathExtension.lowercased()) else { continue }
                do {
                    try TagWriter.embedArtwork(candidate.imageData, in: target.url)
                } catch {
                    failures += 1
                }
            }
        }

        if let updated = library.track(with: track.id) {
            engine.syncCurrentTrack(with: updated)
        }
        NowPlayingService.shared.refreshNow()

        if !embedInFile {
            library.statusMessage = "Обложка добавлена в библиотеку"
        } else if failures > 0 {
            library.statusMessage = "Обложка в библиотеке; в файл не записалось: \(failures)"
        } else {
            library.statusMessage = "Обложка сохранена в файл"
        }
        dismiss()
    }
}
