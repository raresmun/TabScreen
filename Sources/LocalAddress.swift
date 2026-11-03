import Foundation

/// The Mac's IPv4 address on Wi-Fi/Ethernet, e.g. 192.168.1.23
func lanIPv4() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var fallback: String?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        cursor = entry.pointee.ifa_next
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: entry.pointee.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if ip.hasPrefix("169.254.") { continue }
        if name == "en0" { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}
