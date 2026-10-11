import Foundation
import SystemConfiguration

let systemProxyBackupPath = serviceDirectory + "/system-proxy.plist"
let systemProxyModePath = serviceDirectory + "/system-proxy-mode.json"

private struct SystemProxyMode: Codable {
    let enabled: Bool
}

// SystemConfiguration stores heterogeneous property lists; retain their native values losslessly.
private let managedProxyKeys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
    "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable", "ExceptionsList", "ExcludeSimpleHostnames"]

/// Replaces only routing-related proxy settings, retaining unrelated protocol preferences.
func systemProxyConfiguration(from original: [String: Any]) -> [String: Any] {
    var result = original
    for prefix in ["HTTP", "HTTPS"] {
        result[prefix + "Enable"] = 1
        result[prefix + "Proxy"] = "127.0.0.1"
        result[prefix + "Port"] = Int(proxyPort)
    }
    for key in ["SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] { result[key] = 0 }
    result["ExceptionsList"] = ["localhost", "*.localhost", "127.*", "::1"]
    result["ExcludeSimpleHostnames"] = 1
    return result
}

private func sameManagedValues(_ first: [String: Any], _ second: [String: Any]) -> Bool {
    NSDictionary(dictionary: first.filter { managedProxyKeys.contains($0.key) })
        .isEqual(to: second.filter { managedProxyKeys.contains($0.key) })
}

/// Allows reset/partially disabled owned settings, but protects active foreign proxy mechanisms.
/// The saved original is also valid, covering a reset to the pre-install configuration.
func maintainedSystemProxy(current: [String: Any], original: [String: Any]) throws -> [String: Any] {
    if sameManagedValues(current, original) { return systemProxyConfiguration(from: current) }
    for key in ["SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
        guard current[key] == nil || (current[key] as? NSNumber)?.intValue == 0 else {
            throw AppError(message: "systemProxyConflict")
        }
    }
    for prefix in ["HTTP", "HTTPS"] {
        guard let flag = current[prefix + "Enable"] else { continue }
        guard let number = flag as? NSNumber else { throw AppError(message: "systemProxyConflict") }
        if number.intValue == 0 { continue }
        guard number.intValue == 1, current[prefix + "Proxy"] as? String == "127.0.0.1",
              (current[prefix + "Port"] as? NSNumber)?.intValue == Int(proxyPort) else {
            throw AppError(message: "systemProxyConflict")
        }
    }
    return systemProxyConfiguration(from: current)
}

/// Restores owned or reset keys only. An active foreign proxy blocks restoration and keeps the backup.
/// An already restored configuration is accepted, allowing retries after a partially completed operation.
func restoredSystemProxy(current: [String: Any], original: [String: Any]) throws -> [String: Any] {
    if sameManagedValues(current, original) { return current }
    _ = try maintainedSystemProxy(current: current, original: original)
    var result = current
    for key in managedProxyKeys { result[key] = original[key] }
    return result
}

private struct SavedProxyPreferences {
    let configuration: [String: Any]
    let enabled: Bool
}

/// Rejects an external protocol disable when both the original and owned values were enabled.
func restoredProxyProtocolEnabled(current: Bool, original: Bool) throws -> Bool {
    guard current || !original else { throw AppError(message: "systemProxyConflict") }
    return original
}

/// Owns HTTP/HTTPS proxy preferences and a crash-recovery journal.
/// Mutating operations require root and the caller's service lock. VPN transport is never edited.
enum SystemProxy {
    /// Public intent contains no recovery data. Older journals imply an enabled mode until migrated.
    /// Validate root ownership and permissions before trusting a marker used by the privileged monitor.
    static func requestedEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: systemProxyModePath) else {
            return FileManager.default.fileExists(atPath: systemProxyBackupPath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: systemProxyModePath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 4096 else {
            throw AppError(message: "systemProxyBackupInvalid")
        }
        return try readJSON(SystemProxyMode.self, systemProxyModePath).enabled
    }

    private static func saveIntent(_ enabled: Bool) throws {
        if FileManager.default.fileExists(atPath: systemProxyModePath) {
            if try requestedEnabled() == enabled { return }
        }
        try writeJSON(SystemProxyMode(enabled: enabled), systemProxyModePath)
    }

    /// Called under the service lock after listener health is confirmed. Never enables a disabled mode.
    static func maintain() throws {
        guard try requestedEnabled() else { return }
        if status() != "systemProxyOn" { try setEnabled(true, automatic: true) }
    }

    private static func preferences() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "Direct Sites" as CFString, nil) else {
            throw AppError(message: "systemProxyFailed")
        }
        return prefs
    }

    private static func selectedServices(_ prefs: SCPreferences) throws -> [SCNetworkService] {
        let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
        var selected = services.filter {
            guard SCNetworkServiceGetEnabled($0), let interface = SCNetworkServiceGetInterface($0),
                  let name = SCNetworkInterfaceGetBSDName(interface) as String? else { return false }
            return name.hasPrefix("en") && name.dropFirst(2).allSatisfy(\.isNumber)
        }
        if let store = SCDynamicStoreCreate(nil, "Direct Sites" as CFString, nil, nil) {
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
            for id in Set([ipv4?["PrimaryService"] as? String, ipv6?["PrimaryService"] as? String].compactMap { $0 }) {
                guard let service = SCNetworkServiceCopy(prefs, id as CFString) else {
                    throw AppError(message: "systemProxyUnsupportedNetwork")
                }
                if !selected.contains(where: { SCNetworkServiceGetServiceID($0) as String? == id }) { selected.append(service) }
            }
        }
        return selected
    }

    private static func effectiveSettingsMatch() -> Bool {
        guard let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        let expected = systemProxyConfiguration(from: [:])
        let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort"]
        return NSDictionary(dictionary: effective.filter { keys.contains($0.key) })
            .isEqual(to: expected.filter { keys.contains($0.key) })
    }

    private static func configuration(_ service: SCNetworkService) throws -> (SCNetworkProtocol, [String: Any]) {
        guard let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw AppError(message: "systemProxyFailed")
        }
        return (proxy, SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:])
    }

    private static func backup() throws -> [String: SavedProxyPreferences] {
        let attributes = try FileManager.default.attributesOfItem(atPath: systemProxyBackupPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 1_048_576,
              let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: systemProxyBackupPath)), format: nil)
                as? [String: Any] else { throw AppError(message: "systemProxyBackupInvalid") }
        if let version = root["version"] as? Int {
            guard version == 2, let services = root["services"] as? [String: [String: Any]] else {
                throw AppError(message: "systemProxyBackupInvalid")
            }
            return try services.mapValues {
                guard let configuration = $0["configuration"] as? [String: Any], let enabled = $0["enabled"] as? Bool else {
                    throw AppError(message: "systemProxyBackupInvalid")
                }
                return SavedProxyPreferences(configuration: configuration, enabled: enabled)
            }
        }
        // The first system-mode build only journaled enabled physical proxy protocols.
        guard let services = root as? [String: [String: Any]] else { throw AppError(message: "systemProxyBackupInvalid") }
        return services.mapValues { SavedProxyPreferences(configuration: $0, enabled: true) }
    }

    private static func save(_ values: [String: SavedProxyPreferences]) throws {
        let services = values.mapValues { ["configuration": $0.configuration, "enabled": $0.enabled] as [String: Any] }
        let data = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "services": services], format: .binary, options: 0)
        let temporary = serviceDirectory + "/.system-proxy-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        guard FileManager.default.createFile(atPath: temporary, contents: data,
            attributes: [.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0]) else {
            throw AppError(message: "systemProxyFailed")
        }
        // Atomic rename retains restrictive permissions, including while replacing an existing journal.
        guard rename(temporary, systemProxyBackupPath) == 0 else { throw AppError(message: "systemProxyFailed") }
    }

    /// Reports configured ownership, not browser connectivity. Incomplete or external changes are visible.
    static func status() -> String {
        do {
            guard try requestedEnabled() else {
                return FileManager.default.fileExists(atPath: systemProxyBackupPath) ? "systemProxyRestorePending" : "systemProxyOff"
            }
            guard FileManager.default.fileExists(atPath: systemProxyBackupPath) else { return "systemProxyChanged" }
            let prefs = try preferences()
            let services = try selectedServices(prefs)
            guard !services.isEmpty else { return "systemProxyChanged" }
            for service in services {
                let (proxy, values) = try configuration(service)
                guard SCNetworkProtocolGetEnabled(proxy), sameManagedValues(values, systemProxyConfiguration(from: [:])) else {
                    return "systemProxyChanged"
                }
            }
            guard effectiveSettingsMatch() else { return "systemProxyChanged" }
            return "systemProxyOn"
        } catch { return "systemProxyChanged" }
    }

    /// Journals before commit. Failure retains the journal so disable can recover safely.
    static func setEnabled(_ enabled: Bool, automatic: Bool = false) throws {
        // Persist OFF before attempting restoration, so a failed disable cannot be undone by the monitor.
        if !enabled { try saveIntent(false) }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, true) else { throw AppError(message: "systemProxyFailed") }
        defer { SCPreferencesUnlock(prefs) }
        var saved = FileManager.default.fileExists(atPath: systemProxyBackupPath) ? try backup() : [:]
        let services = enabled ? try selectedServices(prefs) : (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? [])
        if enabled && services.isEmpty { throw AppError(message: "systemProxyNoNetwork") }
        var changes: [(String, SCNetworkProtocol, [String: Any], Bool)] = []
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { throw AppError(message: "systemProxyFailed") }
            if !enabled && saved[id] == nil { continue }
            let (proxy, current) = try configuration(service)
            if enabled {
                if let original = saved[id] {
                    _ = try maintainedSystemProxy(current: current, original: original.configuration)
                } else {
                    if automatic { _ = try maintainedSystemProxy(current: current, original: [:]) }
                    saved[id] = SavedProxyPreferences(configuration: current, enabled: SCNetworkProtocolGetEnabled(proxy))
                }
                changes.append((id, proxy, systemProxyConfiguration(from: current), true))
            } else {
                let original = saved[id]!
                let protocolEnabled = try restoredProxyProtocolEnabled(current: SCNetworkProtocolGetEnabled(proxy), original: original.enabled)
                changes.append((id, proxy, try restoredSystemProxy(current: current, original: original.configuration), protocolEnabled))
            }
        }
        if enabled {
            try save(saved)
            try saveIntent(true)
        }
        if changes.isEmpty { return }
        for (_, proxy, value, protocolEnabled) in changes {
            guard SCNetworkProtocolSetConfiguration(proxy, value as CFDictionary), SCNetworkProtocolSetEnabled(proxy, protocolEnabled) else { throw AppError(message: "systemProxyFailed") }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw AppError(message: "systemProxyFailed") }
        SCPreferencesSynchronize(prefs)
        for (id, _, expected, protocolEnabled) in changes {
            guard let service = SCNetworkServiceCopy(prefs, id as CFString),
                  let (proxy, actual) = try? configuration(service), SCNetworkProtocolGetEnabled(proxy) == protocolEnabled,
                  sameManagedValues(actual, expected) else { throw AppError(message: "systemProxyFailed") }
        }
        if enabled {
            for _ in 0..<20 {
                if effectiveSettingsMatch() { return }
                usleep(100_000)
            }
            throw AppError(message: "systemProxyFailed")
        }
        if !enabled && FileManager.default.fileExists(atPath: systemProxyBackupPath) {
            try FileManager.default.removeItem(atPath: systemProxyBackupPath)
        }
    }
}
