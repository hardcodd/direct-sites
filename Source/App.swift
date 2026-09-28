import AppKit
import Foundation

func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor @main final class DirectSitesApp: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: localized("apply"), target: nil, action: nil)
    private var rules: [Rule] = []
    private var saved: [Rule] = []
    private var state: ServiceState?
    private var proxyHealth: ProxyHealth?
    private var timer: Timer?
    private var icons: [String: NSImage] = [:]
    private var requestedIcons: Set<String> = []
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
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Direct Sites"
        window.minSize = NSSize(width: 760, height: 610)
        window.delegate = self
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
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
        let firefox = NSButton(title: localized("firefoxSetup"), target: self, action: #selector(showFirefoxSetup))
        firefox.bezelStyle = .rounded
        root.addArrangedSubview(firefox)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sites"))
        column.title = localized("sites")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 70
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editRule)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let actions = NSStackView()
        actions.spacing = 8
        for (key, action) in [("add", #selector(addRule)), ("edit", #selector(editRule)), ("remove", #selector(removeRule))] {
            let button = NSButton(title: localized(key), target: self, action: action)
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

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]
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
        labels.addArrangedSubview(name)
        let host = NSTextField(labelWithString: rule.host)
        host.textColor = .secondaryLabelColor
        host.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if rule.includeSubdomains == true { host.stringValue += "  · " + localized("allSubdomains") }
        labels.addArrangedSubview(host)
        rowView.addArrangedSubview(labels)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowView.addArrangedSubview(spacer)
        let status = state?.status[rule.host]
        let isPending = !saved.contains(rule)
        let key: String
        if isPending { key = "pending" }
        else if rule.includeSubdomains == true { key = proxyHealth == nil ? "waiting" : "browserReady" }
        else if status == nil || isStale { key = "waiting" }
        else if status!.messages == ["foreignDirect"] { key = "externalDirect" }
        else { key = status!.messages.isEmpty ? "active" : "attention" }
        let badge = NSTextField(labelWithString: localized(key))
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.textColor = ["active", "externalDirect", "browserReady"].contains(key) ? .systemGreen : .secondaryLabelColor
        rowView.addArrangedSubview(badge)
        requestIcon(for: rule.host)
        return rowView
    }

    private var isStale: Bool { state == nil || Date().timeIntervalSince(state!.updated) > 120 }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }

    private func refresh(forceReload: Bool = false) {
        let oldStatus = state?.status
        let oldStale = isStale
        state = try? readJSON(ServiceState.self, statePath)
        let installed = FileManager.default.fileExists(atPath: configPath)
        if dirty { summary.stringValue = localized("unsaved") }
        else if !installed { summary.stringValue = localized("notInstalled") }
        else if isStale { summary.stringValue = localized("stale") }
        else { summary.stringValue = localized("running") + " · " + state!.updated.formatted(date: .omitted, time: .standard) }
        applyButton.isEnabled = dirty || !installed || isStale || proxyHealth == nil
        if forceReload || oldStatus != state?.status || oldStale != isStale { table.reloadData() }
        updateDetails()
        refreshProxyHealth()
    }

    private func refreshProxyHealth() {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:17879/status")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let next = data.flatMap { try? JSONDecoder().decode(ProxyHealth.self, from: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = (self.proxyHealth == nil) != (next == nil)
                self.proxyHealth = next
                if changed { self.table.reloadData() }
                self.updateDetails()
            }
        }.resume()
    }

    private func updateDetails() {
        let selected = table.selectedRow
        guard rules.indices.contains(selected) else { details.stringValue = rules.isEmpty ? localized("empty") : localized("selectHint"); return }
        let rule = rules[selected]
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
    @objc private func editRule() {
        guard rules.indices.contains(table.selectedRow) else { return }
        presentEditor(table.selectedRow)
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
            refresh(forceReload: true)
        } catch { showError(error) }
    }

    @objc private func removeRule() {
        guard rules.indices.contains(table.selectedRow) else { return }
        rules.remove(at: table.selectedRow)
        refresh(forceReload: true)
    }

    /// Uses the system authorization dialog. The app never receives or stores the administrator password.
    @objc private func apply() {
        do {
            let encoded = try JSONEncoder().encode(rules).base64EncodedString()
            try authorize(arguments: ["--install", encoded])
            saved = rules
            refresh(forceReload: true)
        } catch { showError(error) }
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

    /// Fetches icons from the site itself, never from a third-party favicon service.
    private func requestIcon(for host: String) {
        guard numericAddress(host) == nil, requestedIcons.insert(host).inserted,
              let url = URL(string: "https://" + host + "/favicon.ico") else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        session.dataTask(with: url) { [weak self] data, response, _ in
            session.finishTasksAndInvalidate()
            guard let data, data.count <= 1_048_576, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            Task { @MainActor [weak self] in
                guard let image = NSImage(data: data) else { return }
                self?.icons[host] = image
                self?.table.reloadData()
            }
        }.resume()
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
