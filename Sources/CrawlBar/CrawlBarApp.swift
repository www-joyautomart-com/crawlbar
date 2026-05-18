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
    private var refreshAnimationTimer: Timer?
    private var refreshAnimationFrame = 0
    private let settingsWindowController = CrawlBarSettingsWindowController()
    private let model = CrawlBarMenuModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrawlBarLog.app.notice("CrawlBar launched")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(Self.statusesDidChange(_:)),
            name: .crawlBarStatusesDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(Self.configDidChange(_:)),
            name: .crawlBarConfigDidChange,
            object: nil)
        self.settingsWindowController.onClose = { [weak self] in
            self?.hideFromApplicationSwitcher()
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        self.statusItem = statusItem
        self.updateStatusButtonImage()
        self.reloadMenu()
        self.model.refreshAll { [weak self] in
            self?.reloadMenu()
        }
        self.scheduleRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrawlBarLog.app.notice("CrawlBar terminated")
        NotificationCenter.default.removeObserver(self)
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
        self.syncRefreshAnimation()
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
            if self.commandAvailable("unlock", installation: installation) {
                submenu.addItem(self.actionItem("Unlock", appID: installation.id, action: "unlock"))
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

    private func syncRefreshAnimation() {
        self.updateStatusButtonImage()
        if self.model.isRefreshing {
            guard self.refreshAnimationTimer == nil else { return }
            self.refreshAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.advanceRefreshAnimation()
                }
            }
        } else {
            self.refreshAnimationTimer?.invalidate()
            self.refreshAnimationTimer = nil
            self.refreshAnimationFrame = 0
            self.updateStatusButtonImage()
        }
    }

    private func advanceRefreshAnimation() {
        guard self.model.isRefreshing else {
            self.syncRefreshAnimation()
            return
        }
        self.refreshAnimationFrame = (self.refreshAnimationFrame + 1) % 8
        self.updateStatusButtonImage()
    }

    private func updateStatusButtonImage() {
        let rotation = self.model.isRefreshing ? CGFloat(self.refreshAnimationFrame) * 45 : 0
        self.statusItem?.button?.image = CrawlBarIconFactory.menuBarImage(rotationDegrees: rotation)
        self.statusItem?.button?.toolTip = self.model.isRefreshing ? "CrawlBar is refreshing crawler status" : "CrawlBar"
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
        CrawlBarLog.app.debug("Opening settings")
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
        CrawlBarLog.app.debug("Opening action logs folder")
        NSWorkspace.shared.open(CrawlActionLogStore.defaultDirectory())
    }

    @objc private func quit(_ sender: Any?) {
        CrawlBarLog.app.notice("Quit requested")
        NSApplication.shared.terminate(nil)
    }

    @objc private func statusesDidChange(_ notification: Notification) {
        self.reloadMenu()
    }

    @objc private func configDidChange(_ notification: Notification) {
        self.model.reloadInstallations()
        self.scheduleRefreshTimer()
        self.reloadMenu()
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

private struct CrawlActionStatusUpdate: Sendable {
    let status: CrawlAppStatus
    let actionFailure: CrawlAppStatus?
}

@MainActor
final class CrawlBarMenuModel: NSObject {
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

    override init() {
        let runner = CrawlCommandRunner()
        self.runner = runner
        self.statusService = CrawlStatusService(runner: runner)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(Self.statusesDidChange(_:)),
            name: .crawlBarStatusesDidChange,
            object: nil)
        self.reloadInstallations()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        } else {
            CrawlBarLog.config.error("Failed to load CrawlBar config")
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
            let installations = (try? registry.installationsForStatus(includeDisabled: true)) ?? []
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
                        CrawlBarStateBroadcast.statusesDidChange([status.appID: status])
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
            let installation = try? registry.installation(for: appID, includeSecrets: true)
            var actionError: CrawlAppStatus?
            if let installation {
                do {
                    CrawlBarLog.actions.notice("Running \(action, privacy: .public) for \(appID.rawValue, privacy: .public)")
                    let result = try runner.run(installation: installation, action: action, timeoutSeconds: 600)
                    _ = try? logStore.save(result)
                    if !result.succeeded {
                        CrawlBarLog.actions.error(
                            "\(action, privacy: .public) for \(appID.rawValue, privacy: .public) failed with exit \(result.exitCode)")
                        actionError = Self.actionFailureStatus(result)
                    }
                } catch {
                    CrawlBarLog.actions.error(
                        "\(action, privacy: .public) for \(appID.rawValue, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
                    actionError = Self.actionFailureStatus(appID: appID, action: action, message: error.localizedDescription)
                }
            }
            let refreshed = installation.map { statusService.status(for: $0, timeoutSeconds: 5) }
            await MainActor.run {
                var changedStatuses: [CrawlAppID: CrawlAppStatus] = [:]
                if let actionError {
                    let status = Self.actionFailureStatus(
                        actionError,
                        refreshedStatus: refreshed,
                        currentStatus: self.statuses[actionError.appID])
                    self.statuses[actionError.appID] = status
                    changedStatuses[actionError.appID] = status
                } else if let refreshed {
                    self.statuses[refreshed.appID] = refreshed
                    changedStatuses[refreshed.appID] = refreshed
                }
                CrawlBarStateBroadcast.statusesDidChange(changedStatuses)
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
        let registry = self.registry
        let runner = self.runner
        let statusService = self.statusService
        let logStore = self.logStore
        Task.detached {
            let updates = dueInstallations.map { installation -> CrawlActionStatusUpdate in
                let actionInstallation = (try? registry.installation(for: installation.id, includeSecrets: true)) ?? installation
                let statusInstallation = (try? registry.installationForStatus(for: installation.id)) ?? installation

                func failureUpdate(_ failure: CrawlAppStatus) -> CrawlActionStatusUpdate {
                    CrawlActionStatusUpdate(
                        status: statusService.status(for: statusInstallation, timeoutSeconds: 5),
                        actionFailure: failure)
                }

                if let config = configs[installation.id] {
                    let refreshAction = config.preferredRefreshAction ?? "refresh"
                    do {
                        CrawlBarLog.actions.notice("Running scheduled \(refreshAction, privacy: .public) for \(installation.id.rawValue, privacy: .public)")
                        let result = try runner.run(installation: actionInstallation, action: refreshAction, timeoutSeconds: 600)
                        _ = try? logStore.save(result)
                        if !result.succeeded {
                            CrawlBarLog.actions.error(
                                "Scheduled \(refreshAction, privacy: .public) for \(installation.id.rawValue, privacy: .public) failed with exit \(result.exitCode)")
                            return failureUpdate(Self.actionFailureStatus(result))
                        }
                    } catch {
                        CrawlBarLog.actions.error(
                            "Scheduled \(refreshAction, privacy: .public) for \(installation.id.rawValue, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
                        return failureUpdate(Self.actionFailureStatus(
                            appID: installation.id,
                            action: refreshAction,
                            message: error.localizedDescription))
                    }
                    if config.shareEnabled, config.shareAfterRefresh {
                        let shareAction = config.preferredShareAction ?? "publish"
                        do {
                            CrawlBarLog.actions.notice("Running scheduled \(shareAction, privacy: .public) for \(installation.id.rawValue, privacy: .public)")
                            let result = try runner.run(installation: actionInstallation, action: shareAction, timeoutSeconds: 600)
                            _ = try? logStore.save(result)
                            if !result.succeeded {
                                CrawlBarLog.actions.error(
                                    "Scheduled \(shareAction, privacy: .public) for \(installation.id.rawValue, privacy: .public) failed with exit \(result.exitCode)")
                                return failureUpdate(Self.actionFailureStatus(result))
                            }
                        } catch {
                            CrawlBarLog.actions.error(
                                "Scheduled \(shareAction, privacy: .public) for \(installation.id.rawValue, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
                            return failureUpdate(Self.actionFailureStatus(
                                appID: installation.id,
                                action: shareAction,
                                message: error.localizedDescription))
                        }
                    }
                }
                return CrawlActionStatusUpdate(
                    status: statusService.status(for: statusInstallation, timeoutSeconds: 5),
                    actionFailure: nil)
            }
            await MainActor.run {
                var changedStatuses: [CrawlAppID: CrawlAppStatus] = [:]
                for update in updates {
                    let status = update.actionFailure.map {
                        Self.actionFailureStatus($0, refreshedStatus: update.status, currentStatus: self.statuses[$0.appID])
                    } ?? update.status
                    self.statuses[status.appID] = status
                    changedStatuses[status.appID] = status
                    if update.actionFailure == nil, status.state != .error {
                        self.lastAutoSyncByAppID[status.appID] = now
                    }
                }
                CrawlBarStateBroadcast.statusesDidChange(changedStatuses)
                self.isRefreshing = false
                onComplete()
            }
        }
    }

    private func mergeStatuses(_ incoming: [CrawlAppID: CrawlAppStatus]) {
        for (appID, status) in incoming {
            self.statuses[appID] = status
        }
    }

    @objc private func statusesDidChange(_ notification: Notification) {
        guard let statuses = CrawlBarStateBroadcast.statuses(from: notification) else { return }
        self.mergeStatuses(statuses)
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

    nonisolated private static func actionFailureStatus(
        _ failure: CrawlAppStatus,
        refreshedStatus: CrawlAppStatus?,
        currentStatus: CrawlAppStatus?)
        -> CrawlAppStatus
    {
        guard let metadataStatus = CrawlAppStatus.richestMetadataStatus(refreshedStatus, fallback: currentStatus) else {
            return failure
        }
        return metadataStatus.mergingActionFailure(failure)
    }

}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
