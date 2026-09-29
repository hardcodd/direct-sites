import Foundation

@main struct CoreTests {
    static func main() throws {
        assert((try? normalize("https://cp.beget.com/login")) == "cp.beget.com")
        assert((try? normalize(" Example.COM. ")) == "example.com")
        assert((try? normalize("178.248.232.144")) == "178.248.232.144")
        assert((try? normalize("2001:4860:4860::8888")) == "2001:4860:4860::8888")
        for input in ["", "-host", "a; touch /tmp/x", "https://user:pass@example.com", "*.example.com", "file:///tmp/x", "0.0.0.0", "127.0.0.1", "::1", "224.0.0.1", "bad..com", "a\n.com"] {
            do { _ = try normalize(input); fatalError("Accepted invalid input: \(input)") }
            catch { }
        }
        let table = "default link#25 UCSg utun5\ndefault 192.168.0.1 UGScIg en0\ndefault 10.0.0.1 UGScIg en1"
        assert(gateway(from: table)?.interface == "en0")
        assert(gateway(from: "default link#3 UCS utun0") == nil)
        let route = HostRoute(ip: "1.1.1.1", gateway: "192.168.0.1", interface: "en0")
        assert(removals(owned: [route], desired: ["1.1.1.1"]).isEmpty)
        assert(removals(owned: [route], desired: []).count == 1)
        assert(addresses(current: nil, cached: ["1.1.1.1"]) == ["1.1.1.1"])
        assert(addresses(current: ["8.8.8.8"], cached: ["1.1.1.1"]) == ["8.8.8.8"])
        let shared = ["a.example": ["1.1.1.1"], "b.example": ["1.1.1.1"]]
        assert(desiredAddresses(shared) == ["1.1.1.1"])
        assert(removals(owned: [route], desired: desiredAddresses(shared.filter { $0.key != "a.example" })).isEmpty)
        assert(canDelete(owned: route, actual: route))
        assert(!canDelete(owned: route, actual: HostRoute(ip: route.ip, gateway: "10.0.0.1", interface: "en1")))
        assert(!canDelete(owned: route, actual: nil))
        let rootRule = Rule(id: UUID(), host: "beget.com", name: "Beget", includeSubdomains: true)
        for host in ["beget.com", "cp.beget.com", "api-cp.beget.com", "deep.api.beget.com", "CP.BEGET.COM."] {
            assert(matchesRule(host, rule: rootRule))
        }
        for host in ["evilbeget.com", "beget.com.example.org", "127.0.0.1"] { assert(!matchesRule(host, rule: rootRule)) }
        let exactRule = Rule(id: UUID(), host: "cp.beget.com", name: "CP")
        assert(!matchesRule("api.cp.beget.com", rule: exactRule))
        let oldJSON = Data("{\"id\":\"6AF3AE89-B5DE-4596-B04B-F575F3CEDA07\",\"host\":\"cp.beget.com\",\"name\":\"CP\"}".utf8)
        let decoded = try JSONDecoder().decode(Rule.self, from: oldJSON)
        assert(decoded.includeSubdomains == nil)
        assert(validProxyHost("CP.BEGET.COM.") == "cp.beget.com")
        for host in ["https://beget.com", "beget.com/login", "beget.com:443", "user@beget.com", "beget.com\u{0}"] {
            assert(validProxyHost(host) == nil)
        }
        let pageURL = URL(string: "https://example.com/")!
        let html = """
        <link rel="stylesheet" href="/site.css">
        <link href='/assets/icon.png' rel='shortcut icon'>
        <link rel="icon" href="https://cdn.example.com/icon.webp">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="apple-touch-icon" href="//example.com/touch.png">
        <link rel="apple-touch-icon-precomposed" href="/touch-precomposed.png">
        <link rel="icon" href="/assets/icon.png">
        """
        assert(faviconURLs(in: html, pageURL: pageURL).map(\.absoluteString) == [
            "https://example.com/assets/icon.png", "https://cdn.example.com/icon.webp", "https://example.com/touch.png",
            "https://example.com/touch-precomposed.png",
            "https://example.com/favicon.ico"
        ])
        assert(faviconURLs(in: "", pageURL: pageURL) == [URL(string: "https://example.com/favicon.ico")!])
        assert(faviconRetryDelay(after: 1) == 30)
        assert(faviconRetryDelay(after: 2) == 120)
        assert(faviconRetryDelay(after: 3) == 600)
        assert(faviconRetryDelay(after: 4) == 3_600)
        assert(faviconRetryDelay(after: 20) == 3_600)
        let oldRoute: [String: Any] = ["Label": "local.previous.directsites",
            "ProgramArguments": [helperPath, "--reconcile"]]
        let oldBrowser: [String: Any] = ["Label": "local.previous.directsites.browser",
            "ProgramArguments": [helperPath, "--proxy"], "UserName": "nobody", "GroupName": "nobody"]
        assert(legacyDaemonLabel(oldRoute) == "local.previous.directsites")
        assert(legacyDaemonLabel(oldBrowser) == "local.previous.directsites.browser")
        assert(legacyDaemonLabel(["Label": serviceID, "ProgramArguments": [helperPath, "--reconcile"]]) == nil)
        assert(legacyDaemonLabel(["Label": "other.service", "ProgramArguments": [helperPath, "--reconcile"]]) == nil)
        assert(legacyDaemonLabel(["Label": "local.previous.directsites", "ProgramArguments": ["/tmp/other", "--reconcile"]]) == nil)
        assert(legacyDaemonLabel(["Label": "local.previous.directsites.browser",
            "ProgramArguments": [helperPath, "--proxy"], "UserName": "root", "GroupName": "nobody"]) == nil)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DirectSitesTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let extensionSource = scratch.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionSource, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extensionSource.appendingPathComponent("manifest.json"))
        try Data("chrome.proxy.settings.set();".utf8).write(to: extensionSource.appendingPathComponent("background.js"))
        let userSupport = scratch.appendingPathComponent("other-user/Library/Application Support", isDirectory: true)
        let installedExtension = try installChromeExtension(from: extensionSource, in: userSupport)
        assert(installedExtension.path.hasPrefix(userSupport.path + "/"))
        let installedManifest = try String(contentsOf: installedExtension.appendingPathComponent("manifest.json"), encoding: .utf8)
        assert(installedManifest == "{}")
        try Data("keep".utf8).write(to: installedExtension.appendingPathComponent("user-note"))
        _ = try installChromeExtension(from: extensionSource, in: userSupport)
        let preservedNote = try String(contentsOf: installedExtension.appendingPathComponent("user-note"), encoding: .utf8)
        assert(preservedNote == "keep")
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: "ChromeExtension/manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        assert(manifest?["manifest_version"] as? Int == 3)
        assert(manifest?["permissions"] as? [String] == ["proxy"])
        assert((manifest?["background"] as? [String: String])?["service_worker"] == "background.js")
        print("Core contract tests passed")
    }
}
