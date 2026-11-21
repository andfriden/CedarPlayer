import Foundation

/// Интернет-станция: имя и адрес потока.
struct RadioStation: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var urlString: String
    var logoURLString: String?
    var logoID: String?

    init(id: UUID = UUID(), name: String, urlString: String,
         logoURLString: String? = nil, logoID: String? = nil) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.logoURLString = logoURLString
        self.logoID = logoID
    }

    var url: URL? {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var host: String { url?.host ?? urlString }
}
