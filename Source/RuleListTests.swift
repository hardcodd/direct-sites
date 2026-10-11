import Foundation

/// List navigation must never mutate rules or turn a displayed row into an unrelated edit target.
func runRuleListTests() throws {
    let beget = Rule(id: UUID(), host: "beget.com", name: "Beget", includeSubdomains: true)
    let panel = Rule(id: UUID(), host: "cp.beget.com", name: "Panel", includeSubdomains: true)
    let legacy = Rule(id: UUID(), host: "legacy.example.com", name: "Legacy", includeSubdomains: false)
    let ip = Rule(id: UUID(), host: "203.0.113.10", name: "Server")
    let unicode = Rule(id: UUID(), host: try normalize("пример.рф"), name: "Example", includeSubdomains: true)
    let rules = [panel, ip, unicode, beget, legacy]
    let statuses = [legacy.host: RuleStatus(ips: ["1.2.3.4"], messages: ["foreignConflict"]),
                    ip.host: RuleStatus(ips: [ip.host], messages: [])]
    var options = RuleListOptions()
    func snapshot(_ value: RuleListOptions) -> RuleListSnapshot {
        makeRuleList(rules: rules, saved: rules, statuses: statuses, stale: false, proxyReady: true,
                     observedHosts: ["deep.api.beget.com"], options: value)
    }
    func ids(_ value: RuleListOptions) -> [UUID] { snapshot(value).rows.compactMap(\.ruleID) }
    options.grouping = .none
    options.query = "BEGET panel"
    assert(ids(options) == [panel.id])
    options.query = " https://cp.beget.com/cart.php?a=checkout "
    assert(ids(options) == [panel.id])
    options.query = "1.2.3.4"
    assert(ids(options) == [legacy.id])
    options.query = "deep.api.beget.com"
    assert(ids(options) == [beget.id])
    options.query = "ПРИМЕР.РФ"
    assert(ids(options) == [unicode.id])
    options.query = "no-such-site"
    assert(snapshot(options).matchingCount == 0 && snapshot(options).rows.isEmpty)
    options.query = ""
    options.filter = .routes
    assert(Set(ids(options)) == [ip.id, legacy.id])
    options.filter = .browser
    assert(Set(ids(options)) == [beget.id, panel.id, unicode.id])
    options.filter = .attention
    assert(ids(options) == [legacy.id])
    assert(ruleListStatus(for: panel, saved: [], statuses: statuses, stale: false, proxyReady: true) == .pending)
    assert(ruleListStatus(for: panel, saved: rules, statuses: statuses, stale: false, proxyReady: false) == .waiting)
    options.filter = .all
    options.sort = .original
    assert(ids(options) == rules.map(\.id))
    options.descending = true
    assert(ids(options) == rules.reversed().map(\.id))
    options.descending = false
    options.sort = .name
    assert(ids(options) == [beget.id, unicode.id, legacy.id, panel.id, ip.id])
    options.sort = .address
    assert(ids(options).first == ip.id)
    options.grouping = .mode
    options.collapsed = ["mode.browser"]
    assert(snapshot(options).matchingCount == rules.count)
    assert(Set(ids(options)) == [ip.id, legacy.id])
    options.query = "beget"
    assert(Set(ids(options)) == [beget.id, panel.id])
    assert(options.collapsed == ["mode.browser"])
    options.query = ""
    options.collapsed = []
    options.grouping = .domain
    let grouped = snapshot(options)
    let sections = grouped.rows.compactMap(\.section)
    assert(sections.contains { $0.id == "domain.beget.com" && $0.count == 2 })
    assert(sections.contains { $0.id == "domain.other" && $0.count == 2 })
    assert(sections.contains { $0.id == "domain.ip" && $0.count == 1 })
    let siblingRules = [Rule(id: UUID(), host: "a.co.uk", name: "A"), Rule(id: UUID(), host: "b.co.uk", name: "B")]
    let siblings = makeRuleList(rules: siblingRules, saved: siblingRules, statuses: [:], stale: false,
                               proxyReady: true, observedHosts: [], options: options)
    assert(siblings.rows.compactMap(\.section).map(\.id) == ["domain.other"])
    let encoded = try JSONEncoder().encode(options)
    let decodedOptions = try JSONDecoder().decode(RuleListOptions.self, from: encoded)
    assert(decodedOptions == options)
    assert(rules.map(\.id) == [panel.id, ip.id, unicode.id, beget.id, legacy.id])
    print("Rule-list contract tests passed")
}
