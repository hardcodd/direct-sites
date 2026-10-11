import AppKit
import Foundation

func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor @main final class DirectSitesApp: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: localized("apply"), target: nil, action: nil)
    private let systemProxyButton = NSButton(title: localized("systemProxyEnable"), target: nil, action: nil)
    private let systemProxyLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let filterPicker = NSPopUpButton()
    private let sortPicker = NSPopUpButton()
    private let groupingPicker = NSPopUpButton()
    private let directionButton = NSButton()
    private let resetListButton = NSButton()
    private let editButton = NSButton(title: localized("edit"), target: nil, action: nil)
    private let removeButton = NSButton(title: localized("remove"), target: nil, action: nil)
    private let clearListButton = NSButton(title: localized("clearList"), target: nil, action: nil)
    private let listCount = NSTextField(labelWithString: "")
    private let emptyListLabel = NSTextField(wrappingLabelWithString: "")
    private var listOptions = RuleListOptions()
    private var listSnapshot = RuleListSnapshot(rows: [], matchingCount: 0)
    private var selectedRuleID: UUID?
    private var rebuildingList = false
    private let listPreferencesKey = "ruleListPreferences.v1"
    private var rules: [Rule] = []
    private var saved: [Rule] = []
    private var state: ServiceState?
    private var proxyHealth: ProxyHealth?
    private var timer: Timer?
    private var icons: [String: NSImage] = [:]
    private var loadedCachedIcons: Set<String> = []
    private var finishedIcons: Set<String> = []
    private var activeIcons: Set<String> = []
    private var iconFailures: [String: Int] = [:]
    private var nextIconAttempt: [String: Date] = [:]
    private let directIconSession = DirectSitesApp.makeIconSession(usingProxy: false)
    private let proxyIconSession = DirectSitesApp.makeIconSession(usingProxy: true)
    private static func makeIconSession(usingProxy: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        if usingProxy {
            configuration.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 17879]
        }
        return URLSession(configuration: configuration)
    }
    private let iconCacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Direct Sites/Favicons", isDirectory: true)
    private var dirty: Bool { rules != saved }

    static func main() {
        let app = NSApplication.shared
        let delegate = DirectSitesApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running Dock tile even when Launch Services cached an older bundle icon.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        do {
            if FileManager.default.fileExists(atPath: configPath) { rules = try readJSON([Rule].self, configPath) }
            saved = rules
        } catch { showError(error) }
        if let data = UserDefaults.standard.data(forKey: listPreferencesKey),
           let options = try? JSONDecoder().decode(RuleListOptions.self, from: data) { listOptions = options }
        listOptions.query = ""
        for rule in rules { loadCachedIcon(for: rule.host) }
        makeMenu()
        makeWindow()
        refresh(forceReload: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: localized("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: localized("edit"))
        for (key, action, shortcut) in [("cut", #selector(NSText.cut(_:)), "x"), ("copy", #selector(NSText.copy(_:)), "c"),
                                         ("paste", #selector(NSText.paste(_:)), "v"), ("selectAll", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: localized(key), action: action, keyEquivalent: shortcut)
        }
        let find = NSMenuItem(title: localized("listFind"), action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(find)
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Direct Sites"
        window.minSize = NSSize(width: 880, height: 740)
        window.delegate = self
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor), root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor)])
        let title = NSTextField(labelWithString: localized("heading"))
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let heading = NSStackView()
        heading.spacing = 12
        let appIcon = NSImageView()
        appIcon.image = Bundle.main.image(forResource: "AppIcon")
        appIcon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        heading.addArrangedSubview(appIcon)
        heading.addArrangedSubview(title)
        root.addArrangedSubview(heading)
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        root.addArrangedSubview(summary)
        let browserSetup = NSStackView()
        browserSetup.spacing = 8
        systemProxyButton.target = self
        systemProxyButton.action = #selector(toggleSystemProxy)
        systemProxyButton.bezelStyle = .rounded
        browserSetup.addArrangedSubview(systemProxyButton)
        let browserHelp = NSButton(title: localized("systemBrowserHelp"), target: self, action: #selector(showSystemBrowserHelp))
        browserHelp.bezelStyle = .rounded
        browserSetup.addArrangedSubview(browserHelp)
        root.addArrangedSubview(browserSetup)
        systemProxyLabel.font = .systemFont(ofSize: 12)
        systemProxyLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(systemProxyLabel)
        let legacySetup = NSStackView()
        legacySetup.spacing = 8
        let firefox = NSButton(title: localized("firefoxSetup"), target: self, action: #selector(showFirefoxSetup))
        firefox.bezelStyle = .rounded
        legacySetup.addArrangedSubview(firefox)
        let chrome = NSButton(title: localized("chromeSetup"), target: self, action: #selector(showChromeSetup))
        chrome.bezelStyle = .rounded
        legacySetup.addArrangedSubview(chrome)
        root.addArrangedSubview(legacySetup)
        makeListControls(in: root)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sites"))
        column.title = localized("sites")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 62
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClickedRule)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let listContainer = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scroll)
        emptyListLabel.alignment = .center
        emptyListLabel.textColor = .secondaryLabelColor
        emptyListLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(emptyListLabel)
        root.addArrangedSubview(listContainer)
        NSLayoutConstraint.activate([
            listContainer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyListLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyListLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyListLabel.widthAnchor.constraint(lessThanOrEqualTo: listContainer.widthAnchor, constant: -40)
        ])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let actions = NSStackView()
        actions.spacing = 8
        let addButton = NSButton(title: localized("add"), target: self, action: #selector(addRule))
        for (button, action) in [(addButton, #selector(addRule)), (editButton, #selector(editRule)),
                                 (removeButton, #selector(removeRule)), (clearListButton, #selector(clearList))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            actions.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(spacer)
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "s"
        applyButton.keyEquivalentModifierMask = .command
        actions.addArrangedSubview(applyButton)
        root.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        details.font = .systemFont(ofSize: 12)
        details.textColor = .secondaryLabelColor
        details.maximumNumberOfLines = 4
        root.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        let footer = NSStackView()
        footer.spacing = 16
        let explanation = NSTextField(wrappingLabelWithString: localized("footer"))
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        footer.addArrangedSubview(explanation)
        let uninstall = NSButton(title: localized("uninstall"), target: self, action: #selector(uninstallService))
        uninstall.bezelStyle = .rounded
        footer.addArrangedSubview(uninstall)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
    }

    private func makeListControls(in root: NSStackView) {
        let searchRow = NSStackView()
        searchRow.spacing = 8
        searchField.placeholderString = localized("listSearchPlaceholder")
        searchField.setAccessibilityLabel(localized("listFind"))
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(changeSearch)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchRow.addArrangedSubview(searchField)
        resetListButton.title = localized("listReset")
        resetListButton.bezelStyle = .rounded
        resetListButton.target = self
        resetListButton.action = #selector(resetList)
        resetListButton.toolTip = localized("listResetHint")
        searchRow.addArrangedSubview(resetListButton)
        root.addArrangedSubview(searchRow)
        searchRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        let optionsRow = NSStackView()
        optionsRow.spacing = 8
        for (picker, label) in [(groupingPicker, "listGroupingLabel"), (sortPicker, "listSortLabel"), (filterPicker, "listFilterLabel")] {
            picker.setAccessibilityLabel(localized(label))
            picker.toolTip = localized(label)
            picker.target = self
            picker.action = #selector(changeListOptions)
        }
        groupingPicker.addItems(withTitles: RuleListGrouping.allCases.map { localized("listGroup_" + $0.rawValue) })
        sortPicker.addItems(withTitles: RuleListSort.allCases.map { localized("listSort_" + $0.rawValue) })
        filterPicker.addItems(withTitles: RuleListFilter.allCases.map { localized("listFilter_" + $0.rawValue) })
        groupingPicker.selectItem(at: RuleListGrouping.allCases.firstIndex(of: listOptions.grouping) ?? 0)
        sortPicker.selectItem(at: RuleListSort.allCases.firstIndex(of: listOptions.sort) ?? 0)
        filterPicker.selectItem(at: RuleListFilter.allCases.firstIndex(of: listOptions.filter) ?? 0)
        for picker in [groupingPicker, sortPicker, filterPicker] { optionsRow.addArrangedSubview(picker) }
        directionButton.bezelStyle = .rounded
        directionButton.target = self
        directionButton.action = #selector(reverseList)
        optionsRow.addArrangedSubview(directionButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        optionsRow.addArrangedSubview(spacer)
        listCount.textColor = .secondaryLabelColor
        listCount.font = .systemFont(ofSize: 11)
        optionsRow.addArrangedSubview(listCount)
        root.addArrangedSubview(optionsRow)
        optionsRow.widthAnchor.constraint(equalTo: searchRow.widthAnchor).isActive = true
    }

    /// Rebuilds the display independently of rule storage, preserving identity rather than row index.
    private func rebuildList() {
        rebuildingList = true
        defer { rebuildingList = false }
        listSnapshot = makeRuleList(rules: rules, saved: saved, statuses: state?.status ?? [:], stale: isStale,
                                    proxyReady: proxyHealth != nil, observedHosts: proxyHealth?.matchedHosts ?? [], options: listOptions)
        table.reloadData()
        if let id = selectedRuleID, let row = listSnapshot.rows.firstIndex(where: { $0.ruleID == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectedRuleID = nil
            table.deselectAll(nil)
        }
        listCount.stringValue = String(format: localized("listCount"), listSnapshot.matchingCount, rules.count)
        emptyListLabel.stringValue = localized(rules.isEmpty ? "listEmpty" : "listNoResults")
        emptyListLabel.isHidden = listSnapshot.matchingCount != 0
        resetListButton.isEnabled = !listOptions.query.isEmpty || listOptions.filter != .all
        directionButton.image = NSImage(systemSymbolName: listOptions.descending ? "arrow.down" : "arrow.up", accessibilityDescription: nil)
        directionButton.setAccessibilityLabel(localized(listOptions.descending ? "listDescending" : "listAscending"))
        directionButton.toolTip = localized(listOptions.descending ? "listDescending" : "listAscending")
        updateDetails()
    }

    private func saveListPreferences() {
        var preferences = listOptions
        preferences.query = ""
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: listPreferencesKey) }
    }

    @objc private func focusSearch() { window.makeFirstResponder(searchField); searchField.selectText(nil) }
    @objc private func changeSearch() {
        listOptions.query = searchField.stringValue
        rebuildList()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { changeSearch() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)), !searchField.stringValue.isEmpty else { return false }
        searchField.stringValue = ""
        changeSearch()
        return true
    }
    @objc private func changeListOptions() {
        listOptions.grouping = RuleListGrouping.allCases[groupingPicker.indexOfSelectedItem]
        listOptions.sort = RuleListSort.allCases[sortPicker.indexOfSelectedItem]
        listOptions.filter = RuleListFilter.allCases[filterPicker.indexOfSelectedItem]
        saveListPreferences()
        rebuildList()
    }
    @objc private func reverseList() {
        listOptions.descending.toggle()
        saveListPreferences()
        rebuildList()
    }
    @objc private func resetList() {
        searchField.stringValue = ""
        listOptions.query = ""
        listOptions.filter = .all
        filterPicker.selectItem(at: 0)
        saveListPreferences()
        rebuildList()
    }
    @objc private func toggleListSection(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if !listOptions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if !listOptions.collapsed.insert(id).inserted { listOptions.collapsed.remove(id) }
        saveListPreferences()
        rebuildList()
    }

    /// Adding/editing clears navigation constraints so the resulting rule cannot disappear silently.
    private func revealRule(_ rule: Rule) {
        searchField.stringValue = ""
        listOptions.query = ""
        listOptions.filter = .all
        filterPicker.selectItem(at: 0)
        var expanded = listOptions
        expanded.collapsed = []
        let snapshot = makeRuleList(rules: rules, saved: saved, statuses: state?.status ?? [:], stale: isStale,
                                    proxyReady: proxyHealth != nil, observedHosts: [], options: expanded)
        var sectionID: String?
        for row in snapshot.rows {
            if let section = row.section { sectionID = section.id }
            if row.ruleID == rule.id {
                if let sectionID { listOptions.collapsed.remove(sectionID) }
                break
            }
        }
        selectedRuleID = rule.id
        saveListPreferences()
        rebuildList()
        if let row = listSnapshot.rows.firstIndex(where: { $0.ruleID == rule.id }) { table.scrollRowToVisible(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listSnapshot.rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { listSnapshot.rows[row].section != nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { listSnapshot.rows[row].ruleID != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { listSnapshot.rows[row].section == nil ? 62 : 32 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let section = listSnapshot.rows[row].section {
            let title = section.localized ? localized(section.title) : section.title
            let button = NSButton(title: title + "  ·  " + String(section.count), target: self, action: #selector(toggleListSection(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(section.id)
            button.image = NSImage(systemSymbolName: section.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.isEnabled = listOptions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !button.isEnabled { button.toolTip = localized("listSearchExpanded") }
            button.setAccessibilityLabel(title + ", " + String(section.count) + ", " + localized(section.collapsed ? "listExpand" : "listCollapse"))
            return button
        }
        guard let id = listSnapshot.rows[row].ruleID, let rule = rules.first(where: { $0.id == id }) else { return nil }
        let rowView = NSStackView()
        rowView.spacing = 12
        let icon = NSImageView()
        icon.image = icons[rule.host] ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        rowView.addArrangedSubview(icon)
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let name = NSTextField(labelWithString: rule.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = rule.name
        labels.addArrangedSubview(name)
        let host = NSTextField(labelWithString: rule.host)
        host.textColor = .secondaryLabelColor
        host.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        host.lineBreakMode = .byTruncatingMiddle
        host.toolTip = rule.host
        if rule.includeSubdomains == true { host.stringValue += "  · " + localized("allSubdomains") }
        labels.addArrangedSubview(host)
        rowView.addArrangedSubview(labels)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowView.addArrangedSubview(spacer)
        let key = ruleListStatus(for: rule, saved: saved, statuses: state?.status ?? [:],
                                 stale: isStale, proxyReady: proxyHealth != nil).rawValue
        let badge = NSTextField(labelWithString: localized(key))
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.textColor = ["active", "externalDirect", "browserReady"].contains(key) ? .systemGreen : .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowView.addArrangedSubview(badge)
        requestIcon(for: rule)
        return rowView
    }

    private var isStale: Bool { state == nil || Date().timeIntervalSince(state!.updated) > 120 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuildingList else { return }
        selectedRuleID = listSnapshot.rows.indices.contains(table.selectedRow) ? listSnapshot.rows[table.selectedRow].ruleID : nil
        updateDetails()
    }

    private func refresh(forceReload: Bool = false) {
        let proxyStatus = SystemProxy.status()
        systemProxyLabel.stringValue = localized(proxyStatus)
        systemProxyButton.title = localized(proxyStatus == "systemProxyRestorePending" || (try? SystemProxy.requestedEnabled()) == true
            ? "systemProxyDisable" : "systemProxyEnable")
        let oldStatus = state?.status
        let oldStale = isStale
        state = try? readJSON(ServiceState.self, statePath)
        let installed = FileManager.default.fileExists(atPath: configPath)
        let legacyInstalled = (try? legacyDaemons()).map { !$0.isEmpty } ?? false
        if dirty { summary.stringValue = localized("unsaved") }
        else if !installed { summary.stringValue = localized("notInstalled") }
        else if legacyInstalled { summary.stringValue = localized("migrationAvailable") }
        else if isStale { summary.stringValue = localized("stale") }
        else { summary.stringValue = localized("running") + " · " + state!.updated.formatted(date: .omitted, time: .standard) }
        applyButton.isEnabled = dirty || !installed || legacyInstalled || isStale || (proxyHealth?.version ?? 0) < 2 || proxyStatus == "systemProxyChanged"
        if forceReload || oldStatus != state?.status || oldStale != isStale { rebuildList() }
        updateDetails()
        refreshProxyHealth()
        scheduleIcons()
    }

    private func refreshProxyHealth() {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:17879/status")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let next = data.flatMap { try? JSONDecoder().decode(ProxyHealth.self, from: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = (self.proxyHealth == nil) != (next == nil)
                self.proxyHealth = next
                if changed || !self.listOptions.query.isEmpty { self.rebuildList() }
                self.updateDetails()
            }
        }.resume()
    }

    private func updateDetails() {
        let rule = selectedRuleID.flatMap { id in rules.first { $0.id == id } }
        editButton.isEnabled = rule != nil
        removeButton.isEnabled = rule != nil
        clearListButton.isEnabled = !rules.isEmpty
        guard let rule else { details.stringValue = rules.isEmpty ? localized("empty") : localized("selectHint"); return }
        if rule.includeSubdomains == true {
            details.stringValue = localized(proxyHealth == nil ? "browserOffline" : "browserDetails")
            let observed = proxyHealth?.matchedHosts.filter { matchesRule($0, rule: rule) } ?? []
            if !observed.isEmpty { details.stringValue += "\n" + observed.joined(separator: ", ") }
            return
        }
        guard let status = state?.status[rule.host] else { details.stringValue = localized("pendingDetails"); return }
        let messages = Array(Set(status.messages)).sorted().map(localized)
        details.stringValue = status.ips.joined(separator: ", ") + "\n" + (messages.isEmpty ? localized("routeOK") : messages.joined(separator: " "))
        if let errors = state?.errors, !errors.isEmpty { details.stringValue += "\n" + errors.joined(separator: "; ") }
    }

    @objc private func addRule() { presentEditor(nil) }
    @objc private func editClickedRule() {
        guard listSnapshot.rows.indices.contains(table.clickedRow), let id = listSnapshot.rows[table.clickedRow].ruleID,
              let index = rules.firstIndex(where: { $0.id == id }) else { return }
        presentEditor(index)
    }
    @objc private func editRule() {
        guard let id = selectedRuleID, let index = rules.firstIndex(where: { $0.id == id }) else { return }
        presentEditor(index)
    }

    private func presentEditor(_ index: Int?) {
        let alert = NSAlert()
        alert.messageText = localized(index == nil ? "add" : "edit")
        alert.informativeText = localized("editorHint")
        alert.addButton(withTitle: localized("done"))
        alert.addButton(withTitle: localized("cancel"))
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let address = NSTextField(string: index.map { rules[$0].host } ?? "")
        address.placeholderString = localized("addressPlaceholder")
        let name = NSTextField(string: index.map { rules[$0].name } ?? "")
        name.placeholderString = localized("namePlaceholder")
        for field in [address, name] {
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(field)
        }
        let suffix = NSButton(checkboxWithTitle: localized("includeSubdomains"), target: nil, action: nil)
        suffix.state = (index.map { rules[$0].includeSubdomains == true } ?? true) ? .on : .off
        stack.addArrangedSubview(suffix)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let host = try normalize(address.stringValue)
            guard !rules.enumerated().contains(where: { $0.offset != index && $0.element.host == host }) else { throw AppError(message: "duplicate") }
            let label = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count <= 120, !label.contains(where: { $0.isNewline }), rules.count < 200 || index != nil else { throw AppError(message: "invalidName") }
            let rule = Rule(id: index.map { rules[$0].id } ?? UUID(), host: host, name: label.isEmpty ? host : label,
                            includeSubdomains: suffix.state == .on && numericAddress(host) == nil)
            if let index { rules[index] = rule } else { rules.append(rule) }
            revealRule(rule)
            loadCachedIcon(for: host)
            refresh(forceReload: true)
        } catch { showError(error) }
    }

    @objc private func removeRule() {
        guard let id = selectedRuleID, let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: index)
        selectedRuleID = nil
        refresh(forceReload: true)
    }

    /// Clears every draft rule, including hidden results; Apply remains the persistence boundary.
    @objc private func clearList() {
        guard !rules.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = localized("clearListTitle")
        alert.informativeText = localized("clearListHint")
        alert.addButton(withTitle: localized("cancel"))
        alert.addButton(withTitle: localized("clearListConfirm"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        rules.removeAll()
        selectedRuleID = nil
        refresh(forceReload: true)
    }

    /// Uses the system authorization dialog. The app never receives or stores the administrator password.
    @objc private func apply() {
        do {
            let encoded = try JSONEncoder().encode(rules).base64EncodedString()
            try authorize(arguments: ["--install", encoded])
            saved = rules
            if try SystemProxy.requestedEnabled() {
                try authorize(arguments: ["--system-proxy", "on"])
            }
            refresh(forceReload: true)
        } catch { refresh(forceReload: true); showError(error) }
    }

    private func authorize(arguments: [String]) throws {
        guard let executable = Bundle.main.path(forResource: "DirectSitesHelper", ofType: nil) else { throw AppError(message: "missingHelper") }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ([executable] + arguments).map(quote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"" + escaped + "\" with administrator privileges")
        var error: NSDictionary?
        guard script?.executeAndReturnError(&error) != nil else {
            throw AppError(message: error?[NSAppleScript.errorMessage] as? String ?? localized("authFailed"))
        }
    }

    @objc private func uninstallService() {
        let alert = NSAlert()
        alert.messageText = localized("uninstall")
        alert.informativeText = localized("uninstallHint")
        alert.addButton(withTitle: localized("uninstall"))
        alert.addButton(withTitle: localized("cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try authorize(arguments: ["--uninstall"])
            rules = []; saved = []; state = nil
            refresh(forceReload: true)
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = localized("error")
        alert.informativeText = localized(error.localizedDescription)
        alert.runModal()
    }

    @objc private func showFirefoxSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyConfigurationURL, forType: .string)
        let alert = NSAlert()
        alert.messageText = localized("firefoxSetup")
        alert.informativeText = localized("firefoxInstructions") + "\n\n" + proxyConfigurationURL
        alert.runModal()
    }

    /// Installs current services before enabling system preferences; disabling keeps IP routes running.
    @objc private func toggleSystemProxy() {
        do {
            if !(try SystemProxy.requestedEnabled()) && !FileManager.default.fileExists(atPath: systemProxyBackupPath) {
                let encoded = try JSONEncoder().encode(rules).base64EncodedString()
                try authorize(arguments: ["--install", encoded])
                saved = rules
                try authorize(arguments: ["--system-proxy", "on"])
            } else {
                try authorize(arguments: ["--system-proxy", "off"])
            }
            refresh(forceReload: true)
        } catch {
            refresh(forceReload: true)
            showError(error)
        }
    }

    @objc private func showSystemBrowserHelp() {
        let alert = NSAlert()
        alert.messageText = localized("systemBrowserHelp")
        alert.informativeText = localized("systemBrowserInstructions")
        alert.runModal()
    }

    @objc private func showChromeSetup() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            showError(AppError(message: localized("chromeMissing")))
            return
        }
        do {
            guard let resources = Bundle.main.resourceURL else { throw AppError(message: localized("missingChromeExtension")) }
            let source = resources.appendingPathComponent("ChromeExtension", isDirectory: true)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let extensionDirectory = try installChromeExtension(from: source, in: support)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(extensionDirectory.path, forType: .string)
            let alert = NSAlert()
            alert.messageText = localized("chromeSetup")
            alert.informativeText = localized("chromeInstructions") + "\n\n" + (extensionDirectory.path as NSString).abbreviatingWithTildeInPath
            alert.addButton(withTitle: localized("openChromeExtensions"))
            alert.addButton(withTitle: localized("cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    _ = try await NSWorkspace.shared.open([URL(string: "chrome://extensions/")!], withApplicationAt: chrome,
                                                          configuration: NSWorkspace.OpenConfiguration())
                } catch { showError(error) }
            }
        } catch { showError(error) }
    }

    private func loadCachedIcon(for host: String) {
        guard numericAddress(host) == nil, (try? normalize(host)) == host else { return }
        let url = iconCacheDirectory.appendingPathComponent(host)
        if loadedCachedIcons.insert(host).inserted,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
           let data = try? Data(contentsOf: url),
           let image = NSImage(data: data), image.isValid {
            icons[host] = image
        }
    }

    /// Checks the site once per launch and retries failed checks with increasing delays.
    private func requestIcon(for rule: Rule) {
        let host = rule.host
        guard numericAddress(host) == nil, (try? normalize(host)) == host else { return }
        guard activeIcons.count < 4, !activeIcons.contains(host), !finishedIcons.contains(host),
              nextIconAttempt[host, default: .distantPast] <= Date() else { return }
        activeIcons.insert(host)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let (data, image) = await self.fetchIcon(for: host, usingProxy: rule.includeSubdomains == true) {
                self.icons[host] = image
                self.finishedIcons.insert(host)
                self.iconFailures.removeValue(forKey: host)
                self.nextIconAttempt.removeValue(forKey: host)
                try? FileManager.default.createDirectory(at: self.iconCacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: self.iconCacheDirectory.appendingPathComponent(host), options: .atomic)
                self.rebuildList()
            } else {
                let failures = self.iconFailures[host, default: 0] + 1
                self.iconFailures[host] = failures
                self.nextIconAttempt[host] = Date().addingTimeInterval(faviconRetryDelay(after: failures))
            }
            self.activeIcons.remove(host)
            self.scheduleIcons()
        }
    }

    private func scheduleIcons() {
        for rule in rules { requestIcon(for: rule) }
    }

    /// Tries the icons advertised by the site's home page, then its conventional favicon path.
    private func fetchIcon(for host: String, usingProxy: Bool) async -> (Data, NSImage)? {
        guard let homeURL = URL(string: "https://" + host + "/") else { return nil }
        let session = usingProxy ? proxyIconSession : directIconSession
        var pageURL = homeURL
        var html = ""
        if let (data, response) = try? await session.data(from: homeURL),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let redirectedURL = response.url, redirectedURL.scheme == "https" {
            pageURL = redirectedURL
            html = String(decoding: data.prefix(524_288), as: UTF8.self)
        }
        for url in faviconURLs(in: html, pageURL: pageURL) {
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.scheme == "https",
                  data.count <= 1_048_576, let image = NSImage(data: data), image.isValid else { continue }
            return (data, image)
        }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { canClose() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func canClose() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = localized("unsaved")
        alert.informativeText = localized("closeHint")
        alert.addButton(withTitle: localized("cancel"))
        alert.addButton(withTitle: localized("discard"))
        let discard = alert.runModal() == .alertSecondButtonReturn
        if discard { rules = saved }
        return discard
    }
}
