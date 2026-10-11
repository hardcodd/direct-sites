import Foundation
import Darwin

@main struct ProxyTests {
    static func exchange(_ request: [UInt8], readCount: Int? = nil) throws -> [UInt8] {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw AppError(message: "socketpair failed") }
        let client = pair[0], server = pair[1]
        defer { close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let proxy = BrowserProxy(rulesPath: "/nonexistent/DirectSitesTestRules.json")
        DispatchQueue.global().async {
            defer { close(server) }
            try? proxy.handle(server)
        }
        let sent = request.withUnsafeBytes { send(client, $0.baseAddress, request.count, 0) }
        guard sent == request.count else { throw AppError(message: "test send failed") }
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 32768)
        while readCount == nil || response.count < readCount! {
            let count = recv(client, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw AppError(message: "test response timed out") }
            response += buffer.prefix(count)
        }
        return response
    }

    static func main() throws {
        let response = try exchange(Array("GET /status HTTP/1.1\r\nHost: 127.0.0.1:17879\r\n\r\n".utf8))
        let text = String(decoding: response, as: UTF8.self)
        assert(text.hasPrefix("HTTP/1.1 200 OK"))
        let body = text.components(separatedBy: "\r\n\r\n")[1]
        let health = try JSONDecoder().decode(ProxyHealth.self, from: Data(body.utf8))
        assert(health.version == 2 && health.directConnections == 0)
        let rebinding = try exchange(Array("GET /status HTTP/1.1\r\nHost: external.example\r\n\r\n".utf8))
        assert(rebinding.isEmpty)
        let invalid = try exchange(Array("CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n".utf8))
        assert(String(decoding: invalid, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
        for request in ["CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
                        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"] {
            let failed = try exchange(Array(request.utf8))
            assert(String(decoding: failed, as: UTF8.self).hasPrefix("HTTP/1.1 502"))
        }
        let unsupported = try exchange([5, 1, 2])
        assert(unsupported == [5, 255])
        let host = Array("example.com".utf8)
        let socks = try exchange([5, 1, 0, 5, 1, 0, 3, UInt8(host.count)] + host + [1, 187])
        assert(socks == [5, 0, 5, 1, 0, 1, 0, 0, 0, 0, 0, 0])
        print("Proxy protocol tests passed")
    }
}
