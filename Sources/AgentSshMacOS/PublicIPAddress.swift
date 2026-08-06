import Darwin
import Foundation

/// Filters addresses before an optional external geolocation request.
///
/// Only globally routable IP literals are eligible. Hostnames, malformed
/// values, and private, loopback, link-local, multicast, documentation, and
/// otherwise reserved ranges remain on-device.
public enum PublicIPAddress {
    public static func isEligibleForExternalGeolocation(_ address: String) -> Bool {
        if let bytes = ipv4Bytes(address) {
            return isPublicIPv4(bytes)
        }

        var value = in6_addr()
        guard inet_pton(AF_INET6, address, &value) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &value) { Array($0) }

        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isPublicIPv4(Array(bytes[12...15]))
        }

        if bytes.allSatisfy({ $0 == 0 }) || bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
            return false
        }
        if bytes[0] & 0xfe == 0xfc { return false } // Unique local fc00::/7.
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false } // Link-local fe80::/10.
        if bytes[0] == 0xff { return false } // Multicast ff00::/8.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false // Documentation 2001:db8::/32.
        }
        guard bytes[0] & 0xe0 == 0x20 else { return false } // Global unicast 2000::/3.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] <= 0x01 { return false } // IETF special-purpose 2001::/23.
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // Deprecated 6to4 2002::/16.
        if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] & 0xf0 == 0 { return false } // Documentation 3fff::/20.
        return true
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part), String(value) == part || part == "0" else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]

        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192 {
            if second == 0 || second == 168 || (second == 88 && bytes[2] == 99) { return false }
        }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, bytes[2] == 100 { return false }
        if first == 203, second == 0, bytes[2] == 113 { return false }
        return true
    }
}
