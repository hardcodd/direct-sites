import Foundation
import Darwin

/// Privileged, noninteractive helper. Only validated rules cross the GUI privilege boundary.
@main struct Helper {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 2 else { throw AppError(message: "Missing operation") }
            if args[1] == "--proxy", args.count == 2 {
                guard geteuid() != 0 else { throw AppError(message: "Browser proxy must run without root privileges") }
                try BrowserProxy().serve()
                return
            }
            guard geteuid() == 0 else { throw AppError(message: "Administrator privileges required") }
            switch args[1] {
            case "--install":
                guard args.count == 3, let data = Data(base64Encoded: args[2]), data.count <= 131072 else {
                    throw AppError(message: "Invalid configuration")
                }
                let rules = try JSONDecoder().decode([Rule].self, from: data)
                try validate(rules)
                try prepareDirectory()
                let previousJobs = try legacyDaemons()
                try withLock {
                    let source = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
                    let target = URL(fileURLWithPath: helperPath)
                    if source.path != target.path {
                        try Data(contentsOf: source).write(to: target, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: helperPath)
                    }
                    try writeJSON(rules, configPath)
                    let plist: [String: Any] = ["Label": serviceID, "ProgramArguments": [helperPath, "--reconcile"],
                        "RunAtLoad": true, "StartInterval": 30, "ProcessType": "Background", "Umask": 0o022]
                    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                        .write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: plistPath)
                    let proxyPlist: [String: Any] = ["Label": proxyServiceID, "ProgramArguments": [helperPath, "--proxy"],
                        "UserName": "nobody", "GroupName": "nobody", "RunAtLoad": true, "KeepAlive": true,
                        "ThrottleInterval": 10, "ProcessType": "Background", "Umask": 0o077]
                    try PropertyListSerialization.data(fromPropertyList: proxyPlist, format: .xml, options: 0)
                        .write(to: URL(fileURLWithPath: proxyPlistPath), options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: proxyPlistPath)
                }
                try activateServices(migrating: previousJobs)
            case "--reconcile":
                try prepareDirectory()
                try withLock { try reconcile() }
            case "--uninstall":
                let previousJobs = try legacyDaemons()
                for job in previousJobs where try serviceIsLoaded(job.label) {
                    try checkedLaunchctl(["bootout", "system/" + job.label])
                }
                _ = try run("/bin/launchctl", ["bootout", "system/" + proxyServiceID])
                _ = try run("/bin/launchctl", ["bootout", "system/" + serviceID])
                try prepareDirectory()
                try withLock {
                    try writeJSON([Rule](), configPath)
                    try reconcile()
                    let state = try readJSON(ServiceState.self, statePath)
                    guard state.owned.isEmpty else { throw AppError(message: "Route cleanup failed; retry removal") }
                    for path in previousJobs.map(\.url.path) + [proxyPlistPath, plistPath, helperPath, configPath, statePath]
                        where FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.removeItem(atPath: path)
                    }
                }
            default: throw AppError(message: "Unknown operation")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func serviceIsLoaded(_ label: String) throws -> Bool {
        try run("/bin/launchctl", ["print", "system/" + label]).0 == 0
    }

    private static func checkedLaunchctl(_ arguments: [String]) throws {
        let result = try run("/bin/launchctl", arguments)
        guard result.0 == 0 else { throw AppError(message: result.1) }
    }

    /// Replaces validated older jobs only after the new job definitions are ready.
    private static func activateServices(migrating previousJobs: [LegacyDaemon]) throws {
        let routeWasLoaded = try serviceIsLoaded(serviceID)
        let proxyWasLoaded = try serviceIsLoaded(proxyServiceID)
        var stopped: [LegacyDaemon] = []
        do {
            for job in previousJobs where try serviceIsLoaded(job.label) {
                try checkedLaunchctl(["bootout", "system/" + job.label])
                stopped.append(job)
            }
            if routeWasLoaded {
                try checkedLaunchctl(["kickstart", "system/" + serviceID])
            } else {
                try checkedLaunchctl(["bootstrap", "system", plistPath])
                try checkedLaunchctl(["kickstart", "system/" + serviceID])
            }
            if proxyWasLoaded {
                // Applying a new helper must reconnect sockets using the current binary.
                try checkedLaunchctl(["kickstart", "-k", "system/" + proxyServiceID])
            } else {
                try checkedLaunchctl(["bootstrap", "system", proxyPlistPath])
            }
            for job in previousJobs { try FileManager.default.removeItem(at: job.url) }
        } catch {
            let original = error
            if !proxyWasLoaded, (try? serviceIsLoaded(proxyServiceID)) == true {
                _ = try? run("/bin/launchctl", ["bootout", "system/" + proxyServiceID])
            }
            if !routeWasLoaded, (try? serviceIsLoaded(serviceID)) == true {
                _ = try? run("/bin/launchctl", ["bootout", "system/" + serviceID])
            }
            for job in previousJobs where !FileManager.default.fileExists(atPath: job.url.path) {
                try? job.plist.write(to: job.url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                                       ofItemAtPath: job.url.path)
            }
            for job in stopped where (try? serviceIsLoaded(job.label)) == false {
                _ = try? run("/bin/launchctl", ["bootstrap", "system", job.url.path])
            }
            throw original
        }
    }

    static func validate(_ rules: [Rule]) throws {
        guard rules.count <= 200, Set(rules.map(\.id)).count == rules.count,
              Set(rules.map(\.host)).count == rules.count else { throw AppError(message: "Duplicate or excessive rules") }
        for rule in rules {
            guard try normalize(rule.host) == rule.host, !rule.name.isEmpty, rule.name.count <= 120,
                  !rule.name.contains(where: { $0.isNewline }) else { throw AppError(message: "Invalid rule") }
            guard rule.includeSubdomains != true || numericAddress(rule.host) == nil else { throw AppError(message: "IP addresses cannot include subdomains") }
        }
    }

    /// Rejects symlinked or user-writable service storage before any privileged writes.
    static func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: serviceDirectory) {
            try fm.createDirectory(atPath: serviceDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        }
        let attributes = try fm.attributesOfItem(atPath: serviceDirectory)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
            throw AppError(message: "Unsafe service directory")
        }
    }

    static func withLock(_ body: () throws -> Void) throws {
        let descriptor = open(serviceDirectory + "/lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AppError(message: "Cannot open lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AppError(message: "Cannot acquire lock") }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    /// Uses bounded DNS queries. A partial lookup failure preserves both previous address families.
    static func resolve(_ host: String) throws -> [String]? {
        if let address = numericAddress(host) { return [address] }
        var results: Set<String> = []
        for family in ["A", "AAAA"] {
            let output = try run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", host, family])
            guard output.0 == 0 else { return nil }
            for line in output.1.split(separator: "\n") {
                if let address = numericAddress(String(line)) { results.insert(address) }
            }
        }
        return results.isEmpty ? nil : results.sorted()
    }

    /// Reads only an exact unscoped host route; default/network routes are never owned.
    static func actualRoute(_ ip: String) throws -> HostRoute? {
        let result = try run("/sbin/route", ["-n", "get", ip.contains(":") ? "-inet6" : "-inet", "-host", ip])
        guard result.0 == 0 else { return nil }
        var fields: [String: String] = [:]
        for line in result.1.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard fields["flags"]?.contains("HOST") == true,
              fields["flags"]?.contains("IFSCOPE") != true,
              fields["destination"] == ip, let gateway = fields["gateway"], let interface = fields["interface"] else { return nil }
        return HostRoute(ip: ip, gateway: gateway, interface: interface)
    }

    static func change(_ operation: String, _ route: HostRoute) throws -> String? {
        let result = try run("/sbin/route", ["-n", operation, route.ip.contains(":") ? "-inet6" : "-inet", "-host", route.ip, route.gateway])
        return result.0 == 0 ? nil : result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reconciles the union of all rules, journaling each owned route before changing the kernel.
    static func reconcile() throws {
        let rules = try readJSON([Rule].self, configPath)
        try validate(rules)
        var state = FileManager.default.fileExists(atPath: statePath) ? try readJSON(ServiceState.self, statePath) : ServiceState()
        state.errors = []
        state.status = [:]
        var cache: [String: [String]] = [:]
        for rule in rules {
            if rule.includeSubdomains == true {
                state.status[rule.host] = RuleStatus(ips: [], messages: ["browserRule"])
                continue
            }
            let fresh = try resolve(rule.host)
            let ips = addresses(current: fresh, cached: state.cache[rule.host] ?? [])
            cache[rule.host] = ips
            state.status[rule.host] = RuleStatus(ips: ips, messages: fresh == nil ? ["dnsFailed"] : [])
        }
        state.cache = cache
        let wanted = desiredAddresses(cache)
        let ipv4 = gateway(from: try run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).1)
        let ipv6 = gateway(from: try run("/usr/sbin/netstat", ["-rn", "-f", "inet6"]).1)
        for route in state.owned {
            let selected = route.ip.contains(":") ? ipv6 : ipv4
            let obsolete = !wanted.contains(route.ip) || (selected != nil && (selected?.gateway != route.gateway || selected?.interface != route.interface))
            guard obsolete else { continue }
            if canDelete(owned: route, actual: try actualRoute(route.ip)), let error = try change("delete", route) {
                state.errors.append(error)
            } else {
                state.owned.removeAll { $0 == route }
                try writeJSON(state, statePath)
            }
        }
        var messages: [String: String] = [:]
        for ip in wanted.sorted() {
            guard var target = ip.contains(":") ? ipv6 : ipv4 else { messages[ip] = "noGateway"; continue }
            target.ip = ip
            let actual = try actualRoute(ip)
            let owned = state.owned.first { $0.ip == ip }
            if let actual {
                if actual == target && owned == actual { continue }
                messages[ip] = actual == target ? "foreignDirect" : "foreignConflict"
                if owned != nil && actual != owned {
                    state.owned.removeAll { $0.ip == ip }
                    try writeJSON(state, statePath)
                }
                continue
            }
            state.owned.removeAll { $0.ip == ip }
            state.owned.append(target)
            try writeJSON(state, statePath)
            if let error = try change("add", target) {
                state.owned.removeAll { $0 == target }
                messages[ip] = "routeFailed"
                state.errors.append(error)
            } else if try actualRoute(ip) != target {
                messages[ip] = "routeUnverified"
            }
            try writeJSON(state, statePath)
        }
        for rule in rules {
            for ip in state.status[rule.host]?.ips ?? [] {
                if let message = messages[ip] { state.status[rule.host]?.messages.append(message) }
            }
        }
        state.updated = Date()
        try writeJSON(state, statePath)
    }
}
