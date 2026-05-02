import AppKit
import CrawlBarCore

@main
@MainActor
enum CrawlBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = CrawlBarAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class CrawlBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private let settingsWindowController = CrawlBarSettingsWindowController()
    private let model = CrawlBarMenuModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.settingsWindowController.onClose = { [weak self] in
            self?.hideFromApplicationSwitcher()
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = CrawlBarIconFactory.menuBarImage()
        statusItem.button?.imagePosition = .imageLeading
        self.statusItem = statusItem
        self.reloadMenu()
        self.model.refreshAll { [weak self] in
            self?.reloadMenu()
        }
        self.scheduleRefreshTimer()
    }

    private func reloadMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = self.model.isRefreshing ? "Refreshing..." : "Refresh All"
        menu.addItem(NSMenuItem(title: title, action: #selector(Self.refreshAll(_:)), keyEquivalent: "r", target: self))
        menu.addItem(.separator())

        for installation in self.model.visibleInstallations {
            menu.addItem(self.appMenuItem(for: installation))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(Self.openLogs(_:)), keyEquivalent: "l", target: self))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(Self.showSettings(_:)), keyEquivalent: ",", target: self))
        menu.addItem(NSMenuItem(title: "Quit CrawlBar", action: #selector(Self.quit(_:)), keyEquivalent: "q", target: self))
        self.statusItem?.menu = menu
    }

    private func appMenuItem(for installation: CrawlAppInstallation) -> NSMenuItem {
        let config = self.model.appConfig(for: installation.id)
        let status = self.model.statuses[installation.id]
        let state = self.effectiveState(for: installation, status: status)
        let title = CrawlBarCrawlerTitle.text(for: installation.id, manifest: installation.manifest)
        let item = NSMenuItem(title: "\(title)  \(self.shortStateLabel(for: state))", action: nil, keyEquivalent: "")
        item.image = CrawlBarIconFactory.image(for: installation.id, manifest: installation.manifest, size: 18)
        item.toolTip = status?.summary ?? installation.manifest.description

        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        submenu.addItem(self.disabledItem(self.longStateLabel(for: state)))
        submenu.addItem(self.disabledItem(self.menuSummary(status?.summary ?? installation.manifest.description)))
        if let lastSyncAt = status?.lastSyncAt {
            submenu.addItem(self.disabledItem("Last sync: \(CrawlBarDateText.relative(lastSyncAt))"))
        }
        if let databaseCount = status?.databases.count, databaseCount > 0 {
            let noun = databaseCount == 1 ? "database" : "databases"
            submenu.addItem(self.disabledItem("Databases: \(databaseCount) \(noun)"))
        }
        submenu.addItem(.separator())

        if installation.enabled, installation.binaryPath != nil {
            let refreshAction = config?.preferredRefreshAction ?? "refresh"
            if self.commandAvailable(refreshAction, installation: installation) {
                submenu.addItem(self.actionItem("Sync Now", appID: installation.id, action: refreshAction))
            }
            if self.commandAvailable("doctor", installation: installation) {
                submenu.addItem(self.actionItem("Doctor", appID: installation.id, action: "doctor"))
            }
            if config?.shareEnabled == true {
                submenu.addItem(.separator())
                let publishAction = config?.preferredShareAction ?? "publish"
                let updateAction = config?.preferredUpdateAction ?? "update"
                if self.commandAvailable(publishAction, installation: installation) {
                    submenu.addItem(self.actionItem("Publish Snapshot", appID: installation.id, action: publishAction))
                }
                if self.commandAvailable(updateAction, installation: installation) {
                    submenu.addItem(self.actionItem("Pull Updates", appID: installation.id, action: updateAction))
                }
            }
        } else {
            let setupText = installation.manifest.availability == .comingSoon
                ? "Coming soon"
                : (installation.enabled ? "Missing command-line tool" : "Disabled in CrawlBar")
            submenu.addItem(self.disabledItem(setupText))
        }

        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(title: "Open Settings...", action: #selector(Self.showSettings(_:)), keyEquivalent: "", target: self))
        item.submenu = submenu
        return item
    }

    private func commandAvailable(_ action: String, installation: CrawlAppInstallation) -> Bool {
        installation.manifest.commands[action] != nil
    }

    private func actionItem(_ title: String, appID: CrawlAppID, action: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Self.runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CrawlMenuCommand(appID: appID, action: action)
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func effectiveState(for installation: CrawlAppInstallation, status: CrawlAppStatus?) -> CrawlAppState {
        if installation.manifest.availability == .comingSoon { return .disabled }
        if !installation.enabled { return .disabled }
        if installation.binaryPath == nil { return .needsConfig }
        return status?.state ?? .unknown
    }

    private func shortStateLabel(for state: CrawlAppState) -> String {
        switch state {
        case .current:
            "Current"
        case .stale:
            "Stale"
        case .syncing:
            "Syncing"
        case .needsConfig:
            "Setup"
        case .needsAuth:
            "Auth"
        case .error:
            "Error"
        case .disabled:
            "Off"
        case .unknown:
            "Unknown"
        }
    }

    private func longStateLabel(for state: CrawlAppState) -> String {
        switch state {
        case .current:
            "Status: current"
        case .stale:
            "Status: stale"
        case .syncing:
            "Status: syncing"
        case .needsConfig:
            "Status: needs setup"
        case .needsAuth:
            "Status: needs auth"
        case .error:
            "Status: error"
        case .disabled:
            "Status: disabled"
        case .unknown:
            "Status: unknown"
        }
    }

    private func menuSummary(_ summary: String) -> String {
        if summary.count <= 58 {
            return summary
        }
        return String(summary.prefix(55)) + "..."
    }

    private func scheduleRefreshTimer() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.runDueAutoSync {
                    self?.reloadMenu()
                }
            }
        }
    }

    @objc private func refreshAll(_ sender: Any?) {
        self.model.refreshAll { [weak self] in
            self?.reloadMenu()
        }
        self.reloadMenu()
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? CrawlMenuCommand else { return }
        self.model.run(command: command) { [weak self] in
            self?.reloadMenu()
        }
        self.reloadMenu()
    }

    @objc private func showSettings(_ sender: Any?) {
        self.showInApplicationSwitcher()
        self.settingsWindowController.show()
        self.model.reloadInstallations()
        self.scheduleRefreshTimer()
        self.reloadMenu()
    }

    private func showInApplicationSwitcher() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func hideFromApplicationSwitcher() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    @objc private func openLogs(_ sender: Any?) {
        NSWorkspace.shared.open(CrawlActionLogStore.defaultDirectory())
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}

final class CrawlMenuCommand: NSObject {
    let appID: CrawlAppID
    let action: String

    init(appID: CrawlAppID, action: String) {
        self.appID = appID
        self.action = action
    }
}

@MainActor
final class CrawlBarMenuModel {
    private let registry = CrawlAppRegistry()
    private let runner: CrawlCommandRunner
    private let statusService: CrawlStatusService
    private let logStore = CrawlActionLogStore()

    var installations: [CrawlAppInstallation] = []
    var statuses: [CrawlAppID: CrawlAppStatus] = [:]
    var isRefreshing = false
    var refreshFrequency: RefreshFrequency = .fifteenMinutes
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var appConfigs: [CrawlAppID: CrawlBarAppConfig] = [:]
    private var lastAutoSyncByAppID: [CrawlAppID: Date] = [:]

    init() {
        let runner = CrawlCommandRunner()
        self.runner = runner
        self.statusService = CrawlStatusService(runner: runner)
        self.reloadInstallations()
    }

    var visibleInstallations: [CrawlAppInstallation] {
        self.installations.filter { installation in
            guard installation.manifest.availability == .available else { return false }
            return self.appConfigs[installation.id]?.showInMenuBar ?? true
        }
    }

    func appConfig(for id: CrawlAppID) -> CrawlBarAppConfig? {
        self.appConfigs[id]
    }

    func reloadInstallations() {
        if let config = try? self.registry.loadConfig() {
            self.refreshFrequency = config.refreshFrequency
            self.appConfigs = Dictionary(uniqueKeysWithValues: config.apps.map { ($0.id, $0) })
        }
        self.installations = (try? self.registry.installations(includeDisabled: true)) ?? []
    }

    func refreshAll(onComplete: @escaping @MainActor () -> Void) {
        self.refreshTask?.cancel()
        let generation = UUID()
        self.refreshGeneration = generation
        self.isRefreshing = true
        let registry = self.registry
        let statusService = self.statusService
        self.refreshTask = Task.detached {
            let installations = (try? registry.installations(includeDisabled: true)) ?? []
            await MainActor.run {
                guard self.refreshGeneration == generation else { return }
                self.installations = installations
                onComplete()
            }
            await withTaskGroup(of: CrawlAppStatus.self) { group in
                for installation in installations {
                    group.addTask {
                        guard !Task.isCancelled else {
                            return CrawlAppStatus(appID: installation.id, state: .unknown, summary: "Refresh cancelled")
                        }
                        return statusService.status(for: installation, timeoutSeconds: 5)
                    }
                }
                for await status in group {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        guard self.refreshGeneration == generation else { return }
                        self.statuses[status.appID] = status
                        onComplete()
                    }
                }
            }
            await MainActor.run {
                guard self.refreshGeneration == generation else { return }
                self.isRefreshing = false
                self.refreshTask = nil
                onComplete()
            }
        }
    }

    func run(command: CrawlMenuCommand, onComplete: @escaping @MainActor () -> Void) {
        self.isRefreshing = true
        let appID = command.appID
        let action = command.action
        let registry = self.registry
        let runner = self.runner
        let statusService = self.statusService
        let logStore = self.logStore
        Task.detached {
            let installation = try? registry.installation(for: appID)
            var actionError: CrawlAppStatus?
            if let installation {
                do {
                    let result = try runner.run(installation: installation, action: action, timeoutSeconds: 600)
                    _ = try? logStore.save(result)
                    if !result.succeeded {
                        actionError = Self.actionFailureStatus(result)
                    }
                } catch {
                    actionError = Self.actionFailureStatus(appID: appID, action: action, message: error.localizedDescription)
                }
            }
            let refreshed = installation.map { statusService.status(for: $0, timeoutSeconds: 5) }
            await MainActor.run {
                if let actionError {
                    self.statuses[actionError.appID] = actionError
                } else if let refreshed {
                    self.statuses[refreshed.appID] = refreshed
                }
                self.isRefreshing = false
                onComplete()
            }
        }
    }

    func runDueAutoSync(onComplete: @escaping @MainActor () -> Void) {
        guard !self.isRefreshing else { return }
        self.reloadInstallations()
        let now = Date()
        let dueInstallations = self.installations.filter { installation in
            guard let config = self.appConfigs[installation.id], config.enabled, config.autoRefreshEnabled else { return false }
            guard installation.enabled, installation.binaryPath != nil else { return false }
            guard let seconds = (config.refreshFrequency ?? self.refreshFrequency).seconds else { return false }
            let last = self.lastAutoSyncByAppID[installation.id] ?? .distantPast
            return now.timeIntervalSince(last) >= seconds
        }
        guard !dueInstallations.isEmpty else { return }

        self.isRefreshing = true
        let configs = self.appConfigs
        let runner = self.runner
        let statusService = self.statusService
        let logStore = self.logStore
        Task.detached {
            let statuses = dueInstallations.map { installation -> CrawlAppStatus in
                if let config = configs[installation.id] {
                    let refreshAction = config.preferredRefreshAction ?? "refresh"
                    do {
                        let result = try runner.run(installation: installation, action: refreshAction, timeoutSeconds: 600)
                        _ = try? logStore.save(result)
                        if !result.succeeded {
                            return Self.actionFailureStatus(result)
                        }
                    } catch {
                        return Self.actionFailureStatus(
                            appID: installation.id,
                            action: refreshAction,
                            message: error.localizedDescription)
                    }
                    if config.shareEnabled, config.shareAfterRefresh {
                        let shareAction = config.preferredShareAction ?? "publish"
                        do {
                            let result = try runner.run(installation: installation, action: shareAction, timeoutSeconds: 600)
                            _ = try? logStore.save(result)
                            if !result.succeeded {
                                return Self.actionFailureStatus(result)
                            }
                        } catch {
                            return Self.actionFailureStatus(
                                appID: installation.id,
                                action: shareAction,
                                message: error.localizedDescription)
                        }
                    }
                }
                return statusService.status(for: installation, timeoutSeconds: 5)
            }
            await MainActor.run {
                for status in statuses {
                    self.statuses[status.appID] = status
                    if status.state != .error {
                        self.lastAutoSyncByAppID[status.appID] = now
                    }
                }
                self.isRefreshing = false
                onComplete()
            }
        }
    }

    nonisolated private static func actionFailureStatus(_ result: CrawlCommandResult) -> CrawlAppStatus {
        let fallback = "\(result.action) failed with exit \(result.exitCode)"
        let summary = result.stderr.nilIfBlank ?? result.stdout.nilIfBlank ?? fallback
        return Self.actionFailureStatus(appID: result.appID, action: result.action, message: summary)
    }

    nonisolated private static func actionFailureStatus(appID: CrawlAppID, action: String, message: String) -> CrawlAppStatus {
        CrawlAppStatus(
            appID: appID,
            state: .error,
            summary: "\(action): \(message)",
            errors: [message])
    }

}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
