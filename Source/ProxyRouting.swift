import Foundation

let proxyServiceID = serviceID + ".browser"
let proxyPlistPath = "/Library/LaunchDaemons/" + proxyServiceID + ".plist"
let proxyPort: UInt16 = 17879
let proxyConfigurationURL = "http://127.0.0.1:17879/proxy.pac"
let proxyPAC = """
function FindProxyForURL(url, host) {
    host = host.toLowerCase().replace(/\\.$/, '');
    if (host === 'localhost' || host === '::1' || host === '[::1]' ||
        host.substring(0, 4) === '127.' || dnsDomainIs(host, '.localhost')) return 'DIRECT';
    return 'SOCKS5 127.0.0.1:17879';
}

"""

struct ProxyHealth: Codable, Sendable {
    var version = 1
    var directConnections: Int = 0
    var normalConnections: Int = 0
    var matchedHosts: [String] = []
}

/// Requires a label boundary; a rule for example.com never matches evilexample.com.
func matchesRule(_ host: String, rule: Rule) -> Bool {
    let canonical = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return canonical == rule.host || (rule.includeSubdomains == true && numericAddress(rule.host) == nil && canonical.hasSuffix("." + rule.host))
}

/// SOCKS domain names must be plain hosts, without credentials, URL paths or ports.
func validProxyHost(_ value: String) -> String? {
    let lower = value.lowercased()
    let canonical = lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    guard let normalized = try? normalize(canonical), normalized == canonical else { return nil }
    return normalized
}
