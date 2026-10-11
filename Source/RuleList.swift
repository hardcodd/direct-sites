import Foundation

enum RuleListFilter: String, Codable, CaseIterable { case all, browser, routes, attention }
enum RuleListSort: String, Codable, CaseIterable { case address, name, original }
enum RuleListGrouping: String, Codable, CaseIterable { case mode, domain, none }

/// User-local presentation preferences. The query stays session-local and never changes routing rules.
struct RuleListOptions: Codable, Equatable {
    var query = ""
    var filter: RuleListFilter = .all
    var sort: RuleListSort = .address
    var descending = false
    var grouping: RuleListGrouping = .mode
    var collapsed: Set<String> = []
}

enum RuleListStatus: String {
    case pending, waiting, browserReady, active, externalDirect, attention
    var needsAttention: Bool { [.pending, .waiting, .attention].contains(self) }
}

/// A section title is either a localization key or a canonical configured domain.
struct RuleListSection: Equatable {
    let id: String
    let title: String
    let localized: Bool
    let count: Int
    let collapsed: Bool
}

enum RuleListRow: Equatable {
    case section(RuleListSection)
    case rule(UUID)
    var ruleID: UUID? { if case .rule(let id) = self { return id }; return nil }
    var section: RuleListSection? { if case .section(let section) = self { return section }; return nil }
}

struct RuleListSnapshot: Equatable {
    let rows: [RuleListRow]
    let matchingCount: Int
}

/// Shared badge/filter policy: configuration readiness does not imply website reachability.
func ruleListStatus(for rule: Rule, saved: [Rule], statuses: [String: RuleStatus], stale: Bool,
                    proxyReady: Bool) -> RuleListStatus {
    if !saved.contains(rule) { return .pending }
    if rule.includeSubdomains == true { return proxyReady ? .browserReady : .waiting }
    guard !stale, let status = statuses[rule.host] else { return .waiting }
    if status.messages == ["foreignDirect"] { return .externalDirect }
    return status.messages.isEmpty ? .active : .attention
}

/// Builds a read-only UUID projection. All query tokens must occur across the searchable fields.
/// Related-domain grouping uses configured ancestor hosts, avoiding public-suffix guesses. Searches
/// expose matching collapsed sections without modifying the user's saved collapse choices.
func makeRuleList(rules: [Rule], saved: [Rule], statuses: [String: RuleStatus], stale: Bool,
                  proxyReady: Bool, observedHosts: [String], options: RuleListOptions) -> RuleListSnapshot {
    func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    let tokens = options.query.split(whereSeparator: { $0.isWhitespace }).map { token -> String in
        let value = String(token)
        if value.contains("://"), let host = URLComponents(string: value)?.host { return folded(host) }
        return folded(value)
    }
    let filtered = rules.enumerated().filter { _, rule in
        switch options.filter {
        case .all: break
        case .browser: if rule.includeSubdomains != true { return false }
        case .routes: if rule.includeSubdomains == true { return false }
        case .attention:
            if !ruleListStatus(for: rule, saved: saved, statuses: statuses, stale: stale, proxyReady: proxyReady).needsAttention { return false }
        }
        let unicodeHost = URLComponents(string: "https://" + rule.host)?.host ?? rule.host
        let observed = observedHosts.filter { matchesRule($0, rule: rule) }
        let text = folded(([rule.name, rule.host, unicodeHost] + (statuses[rule.host]?.ips ?? []) + observed).joined(separator: " "))
        return tokens.allSatisfy { text.contains($0) }
    }.sorted { first, second in
        let comparison: ComparisonResult
        switch options.sort {
        case .original: comparison = first.offset < second.offset ? .orderedAscending : .orderedDescending
        case .address: comparison = first.element.host.localizedStandardCompare(second.element.host)
        case .name: comparison = first.element.name.localizedStandardCompare(second.element.name)
        }
        if comparison == .orderedSame { return first.offset < second.offset }
        return comparison == (options.descending ? .orderedDescending : .orderedAscending)
    }.map(\.element)
    guard options.grouping != .none else {
        return RuleListSnapshot(rows: filtered.map { .rule($0.id) }, matchingCount: filtered.count)
    }
    var rows: [RuleListRow] = []
    func appendSection(_ id: String, title: String, localized: Bool = true, members: [Rule]) {
        guard !members.isEmpty else { return }
        let collapsed = tokens.isEmpty && options.collapsed.contains(id)
        rows.append(.section(RuleListSection(id: id, title: title, localized: localized, count: members.count, collapsed: collapsed)))
        if !collapsed { rows.append(contentsOf: members.map { .rule($0.id) }) }
    }
    if options.grouping == .mode {
        appendSection("mode.browser", title: "listBrowserGroup", members: filtered.filter { $0.includeSubdomains == true })
        appendSection("mode.routes", title: "listRoutesGroup", members: filtered.filter { $0.includeSubdomains != true })
    } else {
        let domains = rules.filter { numericAddress($0.host) == nil }
        func rootHost(_ rule: Rule) -> String {
            domains.filter { rule.host == $0.host || rule.host.hasSuffix("." + $0.host) }
                .min { $0.host.count < $1.host.count }?.host ?? rule.host
        }
        let families = Dictionary(grouping: domains, by: rootHost)
        let related = Set(families.filter { $0.value.count > 1 }.keys)
        for host in related.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            appendSection("domain." + host, title: host, localized: false,
                          members: filtered.filter { numericAddress($0.host) == nil && rootHost($0) == host })
        }
        appendSection("domain.other", title: "listOtherGroup",
                      members: filtered.filter { numericAddress($0.host) == nil && !related.contains(rootHost($0)) })
        appendSection("domain.ip", title: "listIPGroup", members: filtered.filter { numericAddress($0.host) != nil })
    }
    return RuleListSnapshot(rows: rows, matchingCount: filtered.count)
}
