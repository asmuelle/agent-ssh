import Foundation

enum SecurityPatchMonitorCache {
    static let staleAfter: TimeInterval = 24 * 60 * 60

    static func isStale(scannedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(scannedAt) > staleAfter
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
