import Foundation

struct ProxyHTTPRequest {
    let host: String
    let port: Int
    let isTunnel: Bool
    let header: String
}

/// Parses one bounded HTTP proxy header. Rejects ambiguous framing and target/Host disagreement.
/// CONNECT passes TLS unchanged; plain HTTP uses one origin request per connection.
func parseProxyHTTPRequest(_ text: String) throws -> ProxyHTTPRequest {
    func invalid() -> AppError { AppError(message: "Invalid HTTP proxy request") }
    guard text.utf8.count <= 32768, text.hasSuffix("\r\n\r\n"),
          !text.utf8.contains(where: { $0 < 32 && ![9, 10, 13].contains($0) || $0 == 127 }) else { throw invalid() }
    let lines = text.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(first[2]),
          !first[0].isEmpty, first[0].utf8.allSatisfy({ (65...90).contains($0) }) else { throw invalid() }
    var headers: [(String, String, String)] = []
    for line in lines.dropFirst().dropLast(2) {
        guard let colon = line.firstIndex(of: ":") else { throw invalid() }
        let name = String(line[..<colon])
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !value.contains("\r"), !value.contains("\n") else { throw invalid() }
        headers.append((name.lowercased(), value, name))
    }
    let hosts = headers.filter { $0.0 == "host" }
    guard hosts.count <= 1, !hosts.isEmpty || first[2] == "HTTP/1.0" && first[0] == "CONNECT" else { throw invalid() }
    let tunnel = first[0] == "CONNECT"
    let target = String(first[1])
    guard let url = URLComponents(string: tunnel ? "http://" + target : target),
          url.scheme == "http", url.user == nil, url.password == nil, url.fragment == nil,
          let rawHost = url.host, let host = validProxyHost(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else { throw invalid() }
    if let hostHeader = hosts.first {
        guard let authority = URLComponents(string: "http://" + hostHeader.1),
          authority.user == nil, authority.password == nil, authority.path.isEmpty,
          authority.query == nil, authority.fragment == nil,
          authority.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
          (authority.port ?? (tunnel ? url.port ?? 80 : 80)) == (url.port ?? 80) else { throw invalid() }
    }
    let port = url.port ?? 80
    guard (1...65535).contains(port), !tunnel || (url.port != nil && url.path.isEmpty && url.query == nil) else { throw invalid() }
    let lengths = headers.filter { $0.0 == "content-length" }
    let encodings = headers.filter { $0.0 == "transfer-encoding" }
    guard lengths.count <= 1, encodings.count <= 1, lengths.isEmpty || encodings.isEmpty,
          lengths.allSatisfy({ !$0.1.isEmpty && $0.1.utf8.allSatisfy({ (48...57).contains($0) }) && UInt64($0.1) != nil }),
          encodings.allSatisfy({ $0.1.lowercased() == "chunked" }) else { throw invalid() }
    let connectionNames = Set(headers.filter { $0.0 == "connection" }.flatMap {
        $0.1.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    })
    let upgrades = headers.filter { $0.0 == "upgrade" }
    let websocket = upgrades.count == 1 && upgrades[0].1.lowercased() == "websocket" && connectionNames.contains("upgrade")
    guard connectionNames.isDisjoint(with: ["host", "content-length", "transfer-encoding"]),
          upgrades.isEmpty || (websocket && first[0] == "GET" && !tunnel) else { throw invalid() }
    let removed: Set<String> = ["proxy-authorization", "proxy-authenticate", "proxy-connection", "connection", "keep-alive", "te", "trailer"]
    let forwarded = headers.filter { !removed.contains($0.0) && (!connectionNames.contains($0.0) || (websocket && $0.0 == "upgrade")) }
        .map { "\($0.2): \($0.1)\r\n" }.joined()
    let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
    let connection = websocket ? "Upgrade" : "close"
    return ProxyHTTPRequest(host: host, port: port, isTunnel: tunnel,
        header: "\(first[0]) \(path) \(first[2])\r\n" + forwarded + "Connection: \(connection)\r\n\r\n")
}
