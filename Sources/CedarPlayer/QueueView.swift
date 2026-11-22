import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Очередь"))
                    .font(.headline)
                Spacer()
                Button(L10n.string("Очистить очередь")) { engine.clearQueue() }
                    .disabled(engine.upNext.isEmpty)
            }
            .padding()
            Divider()
            if engine.upNext.isEmpty {
                Text(L10n.string("В очереди пока нет треков"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.upNext) { track in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.displayTitle).lineLimit(1)
                                    Text(track.displayArtist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    engine.removeFromQueue(track.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.string("Удалить из очереди"))
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}
