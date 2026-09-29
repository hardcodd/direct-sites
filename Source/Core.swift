import Foundation
import Darwin

let serviceID = "app.directsites"
let serviceDirectory = "/Library/Application Support/DirectSites"
let helperPath = serviceDirectory + "/DirectSitesHelper"
let configPath = serviceDirectory + "/rules.json"
let statePath = serviceDirectory + "/state.json"
let plistPath = "/Library/LaunchDaemons/" + serviceID + ".plist"

struct Rule: Codable, Equatable, Sendable {
    var id: UUID
    var host: String
    var name: String
    /// True selects browser-only matching of this domain and every descendant.
    var includeSubdomains: Bool? = nil
}
struct HostRoute: Codable, Equatable, Sendable {
    var ip: String
    var gateway: String
    var interface: String
}
struct RuleStatus: Codable, Equatable, Sendable {
    var ips: [String]
    var messages: [String]
}
struct ServiceState: Codable, Sendable {
    var updated = Date.distantPast
    var owned: [HostRoute] = []
    var cache: [String: [String]] = [:]
    var status: [String: RuleStatus] = [:]
    var errors: [String] = []
}
struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Returns a canonical numeric address, rejecting unspecified, local and multicast targets.
func numericAddress(_ value: String) -> String? {
    var v4 = in_addr()
    var v6 = in6_addr()
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    if inet_pton(AF_INET, value, &v4) == 1 {
        let first = UInt32(bigEndian: v4.s_addr) >> 24
        guard first != 0, first != 127, first < 224 else { return nil }
        inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count))
    } else if inet_pton(AF_INET6, value, &v6) == 1 {
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        guard bytes.contains(where: { $0 != 0 }), !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1),
              bytes[0] != 255, !(bytes[0] == 254 && bytes[1] & 192 == 128),
              !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255) else { return nil }
        inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count))
    } else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Extracts a host from HTTP(S) input and rejects credentials, wildcards and shell-like input.
func normalize(_ input: String) throws -> String {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let address = numericAddress(text) { return address }
    guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
          let url = URL(string: text.contains("://") ? text : "https://" + text),
          ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
          var host = url.host else { throw AppError(message: "invalidHost") }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if let address = numericAddress(host) { return address }
    if host.hasSuffix(".") { host.removeLast() }
    guard host.count <= 253, host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
          host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
              !part.isEmpty && part.count <= 63 && part.first != "-" && part.last != "-" &&
              part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
          }) else { throw AppError(message: "invalidHost") }
    return host
}

/// Selects the first physical Ethernet/Wi-Fi default, preserving routing-table preference.
func gateway(from table: String) -> HostRoute? {
    for line in table.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 4, fields[0] == "default", fields[2].contains("G"),
              let interface = fields.dropFirst(3).first(where: { $0.hasPrefix("en") && $0.dropFirst(2).allSatisfy(\.isNumber) }),
              !fields[1].hasPrefix("link#") else { continue }
        return HostRoute(ip: "", gateway: fields[1], interface: interface)
    }
    return nil
}

func addresses(current: [String]?, cached: [String]) -> [String] { current ?? cached }
/// Computes shared addresses once, so deleting one rule cannot remove another rule's route.
func desiredAddresses(_ cache: [String: [String]]) -> Set<String> { Set(cache.values.flatMap { $0 }) }
func removals(owned: [HostRoute], desired: Set<String>) -> [HostRoute] { owned.filter { !desired.contains($0.ip) } }
func canDelete(owned: HostRoute, actual: HostRoute?) -> Bool { owned == actual }

/// Executes fixed system programs directly; arguments are never interpreted by a shell.
func run(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func readJSON<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func writeJSON<T: Encodable>(_ value: T, _ path: String) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}
