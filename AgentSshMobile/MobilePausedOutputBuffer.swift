import Foundation

/// Holds PTY bytes that arrive while a session's presentation is paused
/// (privacy cover, scene inactive, background).
///
/// Bytes are never dropped. Discarding output desyncs the terminal's
/// escape-sequence state, and a split escape sequence can corrupt rendering
/// for the rest of the session. The buffer is bounded instead: when the bound
/// is exceeded, `append` hands the whole accumulation back so the caller can
/// deliver it immediately. Delivering under the privacy cover is harmless
/// because the cover is opaque; what matters is that the emulator sees every
/// byte, in order.
struct MobilePausedOutputBuffer: Equatable {
    let limit: Int
    private(set) var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var isEmpty: Bool { data.isEmpty }
    var count: Int { data.count }

    /// Appends `chunk`. Returns `nil` while under the bound. When the bound is
    /// exceeded, returns everything held so far (including `chunk`) and
    /// leaves the buffer empty.
    mutating func append(_ chunk: Data) -> Data? {
        data.append(chunk)
        guard data.count > limit else { return nil }
        return drain()
    }

    /// Returns everything held and leaves the buffer empty.
    mutating func drain() -> Data {
        let held = data
        data = Data()
        return held
    }
}
