import Foundation

/// Installs the bundled extension into the current user's support directory without touching other files.
func installChromeExtension(from source: URL, in userSupportDirectory: URL) throws -> URL {
    let destination = userSupportDirectory.appendingPathComponent("Direct Sites/Chrome Extension", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for name in ["manifest.json", "background.js"] {
        let data = try Data(contentsOf: source.appendingPathComponent(name))
        try data.write(to: destination.appendingPathComponent(name), options: .atomic)
    }
    return destination
}
