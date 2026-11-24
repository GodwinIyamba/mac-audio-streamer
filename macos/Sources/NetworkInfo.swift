import Darwin
import Foundation

struct LANAddress: Identifiable, Hashable {
    let id: String
    let interface: String
    let ip: String
}

enum NetworkInfo {
    static func getLANAddresses() -> [LANAddress] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var preferred: [LANAddress] = []
        var others: [LANAddress] = []
        var seen = Set<String>()

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)

            // Skip link-local 169.254.x.x addresses
            guard !ip.hasPrefix("169.254."), !seen.contains(ip) else { continue }
            seen.insert(ip)

            let entry = LANAddress(id: "\(name):\(ip)", interface: name, ip: ip)
            if name == "en0" || name == "en1" {
                preferred.append(entry)
            } else {
                others.append(entry)
            }
        }

        return preferred + others
    }
}
