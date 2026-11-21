import Foundation

/// Интернет-станция: имя и адрес потока.
struct RadioStation: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var urlString: String

    init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    var url: URL? {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var host: String { url?.host ?? urlString }
}
