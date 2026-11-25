import SwiftUI
import AppKit

extension Library {
    struct DuplicateGroup: Identifiable {
        let id: String
        let tracks: [Track]
    }

    /// Groups tracks with the same title, artist, album and rounded duration.
    func duplicateGroups() -> [DuplicateGroup] {
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let key = [
                track.displayTitle,
                track.displayArtist,
                track.displayAlbum,
                String(Int(track.duration.rounded()))
            ].joined(separator: "|").lowercased()
            groups[key, default: []].append(track)
        }
        return groups
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: $0.key, tracks: $0.value) }
            .sorted { $0.tracks[0].displayTitle.localizedStandardCompare($1.tracks[0].displayTitle) == .orderedAscending }
    }

    func removeDuplicates(in group: DuplicateGroup, keeping track: Track) {
        let ids = Set(group.tracks.map(\.id)).subtracting([track.id])
        guard !ids.isEmpty else { return }
        remove(ids)
    }

    func presentBatchRelinkPanel() {
        let missing = tracks.filter(\.isMissing)
        guard !missing.isEmpty else {
            statusMessage = L10n.string("Нет отсутствующих файлов")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("Выберите папки с отсутствующими файлами")
        panel.prompt = L10n.string("Привязать")
        guard panel.runModal() == .OK else { return }
        let linked = relinkMissingFiles(in: panel.urls)
        statusMessage = L10n.format("Привязано файлов: %ld из %ld", linked, missing.count)
    }

    @discardableResult
    func relinkMissingFiles(in folders: [URL]) -> Int {
        let missing = tracks.filter(\.isMissing)
        guard !missing.isEmpty, !folders.isEmpty else { return 0 }

        var candidates: [String: [URL]] = [:]
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where Track.isSupported(url) {
                candidates[url.lastPathComponent.lowercased(), default: []].append(url)
            }
        }

        var used = Set<String>()
        var linked = 0
        for track in missing {
            let name = track.url.lastPathComponent.lowercased()
            guard let urls = candidates[name],
                  let url = urls.first(where: { !used.contains($0.path) }) else { continue }
            replaceFile(for: track.id, with: url)
            used.insert(url.path)
            linked += 1
        }
        return linked
    }
}

struct DuplicateFinderView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    private var groups: [Library.DuplicateGroup] { library.duplicateGroups() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Дубликаты"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(L10n.string("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(L10n.string("Дубликатов не найдено"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.tracks[0].displayTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(group.tracks[0].displayArtist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(group.tracks) { track in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.url.lastPathComponent)
                                                .font(.system(size: 11))
                                                .lineLimit(1)
                                            Text(track.url.deletingLastPathComponent().path)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(track.formatText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Button(L10n.string("Оставить этот")) {
                                            library.removeDuplicates(in: group, keeping: track)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([track.url])
                                        } label: {
                                            Image(systemName: "folder")
                                        }
                                        .buttonStyle(.borderless)
                                        .help(L10n.string("Показать в Finder"))
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                            .padding(10)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}
