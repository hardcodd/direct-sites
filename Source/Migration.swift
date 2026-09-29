import Foundation

struct LegacyDaemon {
    let label: String
    let url: URL
    let plist: Data
}

/// Accepts only an older Direct Sites job pointing to this installation's helper.
func legacyDaemonLabel(_ propertyList: [String: Any]) -> String? {
    guard let label = propertyList["Label"] as? String,
          label != serviceID, label != proxyServiceID,
          let arguments = propertyList["ProgramArguments"] as? [String], arguments.count == 2,
          arguments[0] == helperPath else { return nil }
    switch arguments[1] {
    case "--reconcile" where label.hasSuffix(".directsites"):
        return label
    case "--proxy" where label.hasSuffix(".directsites.browser"):
        guard propertyList["UserName"] as? String == "nobody",
              propertyList["GroupName"] as? String == "nobody" else { return nil }
        return label
    default:
        return nil
    }
}

/// Finds legacy launchd jobs without embedding a particular macOS user's name or old label.
func legacyDaemons() throws -> [LegacyDaemon] {
    let directory = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    let fileManager = FileManager.default
    let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                   options: [.skipsHiddenFiles])
    var jobs: [LegacyDaemon] = []
    for url in urls where url.pathExtension == "plist" {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { continue }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
              size <= 65_536, let data = try? Data(contentsOf: url) else { continue }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = legacyDaemonLabel(plist), url.deletingPathExtension().lastPathComponent == label else { continue }
        jobs.append(LegacyDaemon(label: label, url: url, plist: data))
    }
    return jobs.sorted { $0.label < $1.label }
}
