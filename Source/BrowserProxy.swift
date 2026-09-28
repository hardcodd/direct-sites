import Foundation
import Darwin

/// Local SOCKS5 proxy. TLS bytes are relayed unchanged; only destination names are inspected.
final class BrowserProxy: @unchecked Sendable {
    private let rulesPath: String
    private let lock = NSLock()
    private var health = ProxyHealth()
    private var gateways: [Int32: String] = [:]
    private var gatewayTime = Date.distantPast
    private let slots = DispatchSemaphore(value: 128)

    init(rulesPath: String = configPath) { self.rulesPath = rulesPath }

    /// Binds only IPv4 loopback. A occupied port is an error, never an alternate public bind.
    func serve() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AppError(message: "Cannot create proxy socket") }
        defer { close(listener) }
        var yes: Int32 = 1
        _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = proxyPort.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(listener, 128) == 0 else { throw AppError(message: "Proxy port 17879 is already in use or inaccessible") }
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { if errno == EINTR { continue }; throw AppError(message: "Proxy accept failed") }
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { close(client); slots.signal() }
                do { try handle(client) } catch { /* The browser receives a SOCKS error or a closed connection. */ }
            }
        }
    }

    private func handle(_ client: Int32) throws {
        Self.configure(client, seconds: 10)
        let first = try Self.readExactly(client, 1)[0]
        if first == 71 { try serveHTTP(client); return } // Only GET is accepted on the read-only local endpoint.
        guard first == 5 else { return }
        let count = Int(try Self.readExactly(client, 1)[0])
        guard count > 0, try Self.readExactly(client, count).contains(0) else { try Self.sendAll(client, [5, 255]); return }
        try Self.sendAll(client, [5, 0])
        let header = try Self.readExactly(client, 4)
        guard header[0] == 5, header[1] == 1, header[2] == 0 else { try Self.reply(client, code: 7); return }
        let host: String
        switch header[3] {
        case 3:
            let length = Int(try Self.readExactly(client, 1)[0])
            guard length > 0, let value = String(bytes: try Self.readExactly(client, length), encoding: .utf8),
                  let validated = validProxyHost(value) else { try Self.reply(client, code: 8); return }
            host = validated
        case 1:
            host = try Self.readExactly(client, 4).map(String.init).joined(separator: ".")
        case 4:
            let bytes = try Self.readExactly(client, 16)
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let success = bytes.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress!, &buffer, socklen_t(buffer.count)) != nil }
            guard success else { try Self.reply(client, code: 8); return }
            host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        default: try Self.reply(client, code: 8); return
        }
        let portBytes = try Self.readExactly(client, 2)
        let port = Int(portBytes[0]) * 256 + Int(portBytes[1])
        guard port > 0 else { try Self.reply(client, code: 2); return }
        // Missing or malformed config fails closed rather than silently changing the selected path.
        let rules: [Rule]
        do { rules = try readJSON([Rule].self, rulesPath) }
        catch { try Self.reply(client, code: 1); return }
        let direct = rules.contains { matchesRule(host, rule: $0) }
        let remote: Int32
        do { remote = try connect(host, port: port, direct: direct) }
        catch { try Self.reply(client, code: 4); return }
        defer { close(remote) }
        lock.lock()
        if direct {
            health.directConnections += 1
            if !health.matchedHosts.contains(host) { health.matchedHosts = Array((health.matchedHosts + [host]).suffix(100)) }
        } else { health.normalConnections += 1 }
        lock.unlock()
        try Self.reply(client, code: 0)
        Self.configure(client, seconds: 30)
        try Self.relay(client, remote)
    }

    /// Serves only PAC and aggregate health. Host checks prevent DNS-rebinding reads.
    private func serveHTTP(_ client: Int32) throws {
        var bytes: [UInt8] = [71]
        while bytes.count < 8192 && !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
            bytes += try Self.readExactly(client, 1)
        }
        guard bytes.suffix(4).elementsEqual([13, 10, 13, 10]), let request = String(bytes: bytes, encoding: .utf8) else { return }
        let lines = request.components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ")
        let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
        guard path.count == 3, hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(proxyPort)" else { return }
        let body: Data
        let type: String
        switch path[1] {
        case "/proxy.pac": body = Data(proxyPAC.utf8); type = "application/x-ns-proxy-autoconfig"
        case "/status":
            lock.lock(); let snapshot = health; lock.unlock()
            body = try JSONEncoder().encode(snapshot); type = "application/json"
        default: return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        try Self.sendAll(client, Array(header.utf8) + body)
    }

    /// Refreshes physical interface selection without changing routes or DNS settings.
    private func physicalInterface(family: Int32) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(gatewayTime) > 3 {
            var next: [Int32: String] = [:]
            for (family, argument) in [(AF_INET, "inet"), (AF_INET6, "inet6")] {
                if let route = gateway(from: try run("/usr/sbin/netstat", ["-rn", "-f", argument]).1) { next[family] = route.interface }
            }
            gateways = next
            gatewayTime = Date()
        }
        return gateways[family]
    }

    /// Binds matched destinations before connect; errors never fall back to the VPN path.
    private func connect(_ host: String, port: Int, direct: Bool) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { throw AppError(message: "DNS failed") }
        defer { freeaddrinfo(first) }
        var entries: [UnsafeMutablePointer<addrinfo>] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current { entries.append(entry); current = entry.pointee.ai_next }
        entries.sort { $0.pointee.ai_family == AF_INET && $1.pointee.ai_family != AF_INET }
        for entry in entries.prefix(8) {
            let family = entry.pointee.ai_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Do not expose loopback services, link-local IPv6 or multicast through the proxy.
            guard numericAddress(address) != nil else { continue }
            let descriptor = socket(family, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            Self.configure(descriptor, seconds: 30)
            if direct {
                guard let interface = try? physicalInterface(family: family) else { close(descriptor); continue }
                var index = if_nametoindex(interface)
                let level = family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6
                let option = family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF
                guard index != 0, setsockopt(descriptor, level, option, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else {
                    close(descriptor); continue
                }
            }
            let originalFlags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
            let result = Darwin.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen)
            if result == 0 || errno == EINPROGRESS {
                var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                if result == 0 || (poll(&pending, 1, 8000) > 0 && getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0) {
                    _ = fcntl(descriptor, F_SETFL, originalFlags)
                    return descriptor
                }
            }
            close(descriptor)
        }
        throw AppError(message: "No usable connection")
    }

    private static func configure(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func readExactly(_ descriptor: Int32, _ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw AppError(message: "Incomplete request") }
            offset += received
        }
        return buffer
    }

    private static func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { throw AppError(message: "Send failed") }
            offset += sent
        }
    }

    private static func reply(_ client: Int32, code: UInt8) throws { try sendAll(client, [5, code, 0, 1, 0, 0, 0, 0, 0, 0]) }

    /// Relays both directions, preserving TCP half-close and bounding idle connections.
    private static func relay(_ client: Int32, _ remote: Int32) throws {
        var sockets = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: remote, events: Int16(POLLIN), revents: 0)]
        let descriptors = [client, remote]
        var open = [true, true]
        var buffer = [UInt8](repeating: 0, count: 32768)
        while open.contains(true) {
            let result = poll(&sockets, 2, 300000)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return }
            for index in 0..<2 where open[index] {
                guard sockets[index].revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else { continue }
                let count = recv(descriptors[index], &buffer, buffer.count, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                    open[index] = false
                    sockets[index].fd = -1
                    shutdown(descriptors[1 - index], SHUT_WR)
                } else { try sendAll(descriptors[1 - index], Array(buffer.prefix(count))) }
            }
        }
    }
}
