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
        print("Core contract tests passed")
    }
}
