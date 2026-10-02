import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves a host name to its numeric addresses with the system resolver,
/// for display (e.g. the dashboard's IP column). Never used to connect.
public enum HostAddressLookup {
    public static func systemAddresses(for host: String, port: UInt16) -> [String] {
        #if canImport(Darwin)
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let address = String(decoding: bytes, as: UTF8.self)
                if !addresses.contains(address) {
                    addresses.append(address)
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
        #else
        return []
        #endif
    }
}
