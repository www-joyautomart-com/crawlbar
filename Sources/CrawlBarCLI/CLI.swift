import CrawlBarCore
import Foundation

@main
enum CrawlBarCLI {
    static func main() {
        do {
            try Self.run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            CLIOutput.writeError(error.localizedDescription)
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            Self.printHelp()
            return
        }

        let options = CLIOptions(arguments.dropFirst())
        let registry = CrawlAppRegistry()
        let runner = CrawlCommandRunner()
        let statusService = CrawlStatusService(runner: runner)
        let installer = CrawlInstaller()

        switch command {
        case "apps":
            try Self.printApps(registry: registry, json: options.json)
        case "logs":
            try Self.printLogs(json: options.json)
        case "metadata":
            try Self.printMetadata(
                registry: registry,
                appID: options.appID,
                json: options.json,
                diagnostics: options.diagnostics)
        case "status":
            try Self.printStatus(registry: registry, statusService: statusService, options: options)
        case "backup":
            try Self.backup(registry: registry, statusService: statusService, json: options.json, appID: options.requiredAppID())
        case "folder":
            try Self.printFolder(registry: registry, statusService: statusService, json: options.json, appID: options.requiredAppID())
        case "doctor", "refresh":
            try Self.runAction(command, registry: registry, runner: runner, json: options.json, appID: options.requiredAppID())
        case "install":
            try Self.install(registry: registry, installer: installer, json: options.json, appID: options.requiredAppID())
        case "query":
            try Self.query(registry: registry, runner: runner, options: options)
        case "action":
            guard let action = options.positionals.first else {
                throw CLIError.usage("action requires an action id")
            }
            try Self.runAction(action, registry: registry, runner: runner, json: options.json, appID: options.requiredAppID())
        case "config":
            try Self.runConfig(options, registry: registry)
        case "help", "--help", "-h":
            Self.printHelp()
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func printApps(registry: CrawlAppRegistry, json: Bool) throws {
        let apps = try registry.installations(includeDisabled: true).map(CLIApp.init)
        if json {
            try CLIOutput.writeJSON(apps)
            return
        }
        for app in apps {
            let marker = app.availability == .comingSoon ? "soon" : (app.enabled ? (app.available ? "ok" : "missing") : "disabled")
            print("\(marker)\t\(app.id)\t\(app.displayName)")
        }
    }

    private static func printMetadata(
        registry: CrawlAppRegistry,
        appID: CrawlAppID?,
        json: Bool,
        diagnostics: Bool)
        throws
    {
        if diagnostics {
            let config = try registry.loadConfig()
            let diagnostics = CrawlManifestCatalog().diagnostics(config: config)
            if json {
                try CLIOutput.writeJSON(diagnostics)
                return
            }
            if diagnostics.isEmpty {
                print("ok")
                return
            }
            for diagnostic in diagnostics {
                print("warning\t\(diagnostic.path)\t\(diagnostic.message)")
            }
            return
        }

        let installations = try registry.installations(includeDisabled: true)
        let manifests = installations
            .filter { appID == nil || $0.id == appID }
            .map(\.manifest)
        if json {
            try CLIOutput.writeJSON(manifests)
            return
        }
        for manifest in manifests {
            print("\(manifest.id.rawValue)\t\(manifest.displayName)\t\(manifest.binary.name)")
        }
    }

    private static func printLogs(json: Bool) throws {
        let logs = CrawlActionLogStore().recent(limit: 50).map { $0.path }
        if json {
            try CLIOutput.writeJSON(logs)
            return
        }
        logs.forEach { print($0) }
    }

    private static func printStatus(
        registry: CrawlAppRegistry,
        statusService: CrawlStatusService,
        options: CLIOptions)
        throws
    {
        let requestedID = options.appID
        let installations = try registry.installationsForStatus(includeDisabled: true)
            .filter { requestedID == nil || requestedID == CrawlAppID(rawValue: "all") || $0.id == requestedID }
        let statuses = installations.map { installation -> CrawlAppStatus in
            statusService.status(for: installation, timeoutSeconds: 30)
        }

        if options.json {
            try CLIOutput.writeJSON(statuses)
            return
        }
        for status in statuses {
            print("\(status.state.rawValue)\t\(status.appID.rawValue)\t\(status.summary)")
        }
    }

    private static func runAction(
        _ action: String,
        registry: CrawlAppRegistry,
        runner: CrawlCommandRunner,
        json: Bool,
        appID: CrawlAppID)
        throws
    {
        guard let installation = try registry.installation(for: appID, includeSecrets: true) else {
            throw CLIError.usage("unknown app: \(appID.rawValue)")
        }
        guard installation.enabled else {
            throw CLIError.usage("\(appID.rawValue) is disabled")
        }
        guard installation.binaryPath != nil else {
            throw CLIError.usage("\(installation.manifest.binary.name) is not on PATH")
        }
        let result = try runner.run(installation: installation, action: action, timeoutSeconds: 600)
        _ = try? CrawlActionLogStore().save(result)
        if json {
            try CLIOutput.writeJSON(result)
            if !result.succeeded {
                Foundation.exit(Int32(result.exitCode))
            }
            return
        }
        print(result.stdout.nilIfBlank ?? result.stderr.nilIfBlank ?? "exit \(result.exitCode)")
        if !result.succeeded {
            Foundation.exit(Int32(result.exitCode))
        }
    }

    private static func install(
        registry: CrawlAppRegistry,
        installer: CrawlInstaller,
        json: Bool,
        appID: CrawlAppID)
        throws
    {
        guard let installation = try registry.installationForStatus(for: appID) else {
            throw CLIError.usage("unknown app: \(appID.rawValue)")
        }
        guard installation.manifest.availability == .available else {
            throw CLIError.usage("\(installation.manifest.displayName) is coming soon")
        }
        let result = try installer.install(installation)
        _ = try? CrawlActionLogStore().save(result)
        if json {
            try CLIOutput.writeJSON(result)
            return
        }
        print(result.stdout.nilIfBlank ?? result.stderr.nilIfBlank ?? "installed \(installation.manifest.binary.name)")
    }

    private static func query(registry: CrawlAppRegistry, runner: CrawlCommandRunner, options: CLIOptions) throws {
        let queryArguments = options.positionals
        guard !queryArguments.isEmpty else {
            throw CLIError.usage("query requires text or SQL")
        }

        let installations: [CrawlAppInstallation]
        if let appID = options.appID, appID != CrawlAppID(rawValue: "all") {
            guard let installation = try registry.installation(for: appID, includeSecrets: false) else {
                throw CLIError.usage("unknown app: \(appID.rawValue)")
            }
            guard installation.manifest.availability == .available else {
                throw CLIError.usage("\(installation.manifest.displayName) is coming soon")
            }
            guard installation.enabled else {
                throw CLIError.usage("\(appID.rawValue) is disabled")
            }
            guard installation.binaryPath != nil else {
                throw CLIError.usage("\(installation.manifest.binary.name) is not on PATH")
            }
            installations = [installation]
        } else {
            installations = try registry.availableInstallations(includeSecrets: false)
                .filter { Self.queryAction(for: $0) != nil }
        }

        let results = installations.map { installation -> CrawlCommandResult in
            guard let action = Self.queryAction(for: installation) else {
                return CrawlCommandResult(
                    appID: installation.id,
                    action: "query",
                    exitCode: 64,
                    stdout: "",
                    stderr: "\(installation.id.rawValue) does not expose a query command",
                    startedAt: Date(),
                    finishedAt: Date())
            }
            do {
                return try runner.run(
                    installation: installation,
                    action: action,
                    extraArguments: queryArguments,
                    timeoutSeconds: 120)
            } catch {
                return CrawlCommandResult(
                    appID: installation.id,
                    action: action,
                    exitCode: 1,
                    stdout: "",
                    stderr: error.localizedDescription,
                    startedAt: Date(),
                    finishedAt: Date())
            }
        }

        if options.json {
            try CLIOutput.writeJSON(results)
        } else if results.count == 1, let result = results.first {
            print(result.stdout.nilIfBlank ?? result.stderr.nilIfBlank ?? "exit \(result.exitCode)")
        } else {
            for result in results {
                print("== \(result.appID.rawValue) ==")
                print(result.stdout.nilIfBlank ?? result.stderr.nilIfBlank ?? "exit \(result.exitCode)")
            }
        }

        if results.contains(where: { !$0.succeeded }) {
            Foundation.exit(1)
        }
    }

    private static func queryAction(for installation: CrawlAppInstallation) -> String? {
        ["query", "sql", "search"].first { installation.manifest.commands[$0] != nil }
    }

    private static func backup(
        registry: CrawlAppRegistry,
        statusService: CrawlStatusService,
        json: Bool,
        appID: CrawlAppID)
        throws
    {
        let status = try Self.status(for: appID, registry: registry, statusService: statusService)
        let backup = try CrawlDatabaseBackupStore.backup(status: status)
        if json {
            try CLIOutput.writeJSON(backup)
            return
        }
        print(backup.directory)
    }

    private static func printFolder(
        registry: CrawlAppRegistry,
        statusService: CrawlStatusService,
        json: Bool,
        appID: CrawlAppID)
        throws
    {
        let status = try Self.status(for: appID, registry: registry, statusService: statusService)
        guard let path = status.databases.first(where: { $0.isPrimary })?.path ?? status.databasePath else {
            throw CLIError.usage("no database folder for \(appID.rawValue)")
        }
        let folder = URL(fileURLWithPath: PathExpander.expandHome(path)).deletingLastPathComponent().path
        if json {
            try CLIOutput.writeJSON(["app_id": appID.rawValue, "folder": folder])
            return
        }
        print(folder)
    }

    private static func status(
        for appID: CrawlAppID,
        registry: CrawlAppRegistry,
        statusService: CrawlStatusService)
        throws -> CrawlAppStatus
    {
        guard let installation = try registry.installationForStatus(for: appID) else {
            throw CLIError.usage("unknown app: \(appID.rawValue)")
        }
        return statusService.status(for: installation, timeoutSeconds: 30)
    }

    private static func runConfig(_ options: CLIOptions, registry: CrawlAppRegistry) throws {
        let store = CrawlBarConfigStore()
        let nativeConfigStore = CrawlNativeConfigStore()
        switch options.positionals.first {
        case "path":
            print(store.fileURL.path)
        case "validate":
            _ = try store.loadOrCreateDefault()
            print("ok")
        case "init", nil:
            let config = try store.loadOrCreateDefault()
            try CLIOutput.writeJSON(config)
        case "get":
            let appID = try options.requiredAppID()
            let config = try store.loadOrCreateDefault(includeSecrets: options.revealSecrets)
            let installation = try registry.installation(for: appID)
            let baseAppConfig = config.appConfig(for: appID) ?? CrawlBarAppConfig(id: appID)
            let appConfig = installation.map {
                var copy = baseAppConfig
                copy.configValues = nativeConfigStore.resolvedConfigValues(appConfig: baseAppConfig, manifest: $0.manifest)
                return copy
            } ?? baseAppConfig
            let values = Self.configValues(
                appConfig: appConfig,
                manifest: installation?.manifest,
                key: options.key,
                revealSecrets: options.revealSecrets)
            if options.json {
                try CLIOutput.writeJSON(values)
                return
            }
            if let key = options.key {
                guard let value = values.first else {
                    throw CLIError.usage("unknown config key for \(appID.rawValue): \(key)")
                }
                print(value.value ?? "")
                return
            }
            for value in values {
                print("\(value.id)\t\(value.value ?? "")")
            }
        case "set":
            let appID = try options.requiredAppID()
            guard let key = options.key?.nilIfBlank else {
                throw CLIError.usage("config set requires --key <id>")
            }
            guard let value = options.value else {
                throw CLIError.usage("config set requires --value <value>")
            }
            var config = try store.loadOrCreateDefault()
            guard let index = config.apps.firstIndex(where: { $0.id == appID }) else {
                throw CLIError.usage("unknown app: \(appID.rawValue)")
            }
            if value.nilIfBlank == nil {
                config.apps[index].configValues.removeValue(forKey: key)
            } else {
                config.apps[index].configValues[key] = value
            }
            try store.save(config)
            if let installation = try registry.installation(for: appID),
               let appConfig = config.appConfig(for: appID)
            {
                var nativeAppConfig = appConfig
                var resolvedValues = nativeConfigStore.resolvedConfigValues(
                    appConfig: appConfig,
                    manifest: installation.manifest)
                if value.nilIfBlank == nil {
                    resolvedValues.removeValue(forKey: key)
                } else {
                    resolvedValues[key] = value
                }
                nativeAppConfig.configValues = resolvedValues
                let clearMissingSecretIDs: Set<String> = value.nilIfBlank == nil ? [key] : []
                try nativeConfigStore.write(
                    appConfig: nativeAppConfig,
                    manifest: installation.manifest,
                    clearMissingSecretIDs: clearMissingSecretIDs)
            }
            if options.json {
                try CLIOutput.writeJSON(["app_id": appID.rawValue, "key": key, "updated": "true"])
                return
            }
            print("ok")
        case let command?:
            throw CLIError.usage("unknown config command: \(command)")
        }
    }

    private static func configValues(
        appConfig: CrawlBarAppConfig,
        manifest: CrawlAppManifest?,
        key: String?,
        revealSecrets: Bool)
        -> [CLIConfigValue]
    {
        let options = manifest?.configOptions ?? []
        let knownIDs = Set(options.map(\.id))
        let extraOptions = appConfig.configValues.keys
            .filter { !knownIDs.contains($0) }
            .sorted()
            .map { CrawlAppManifest.ConfigOption(id: $0, label: $0) }
        return (options + extraOptions)
            .filter { key == nil || $0.id == key }
            .map { option in
                let rawValue = appConfig.configValues[option.id] ?? option.defaultValue
                let isSecret = option.kind == .secret
                return CLIConfigValue(
                    id: option.id,
                    label: option.label,
                    value: isSecret && !revealSecrets && rawValue?.nilIfBlank != nil ? "********" : rawValue,
                    secret: isSecret,
                    envVar: option.envVar,
                    configKey: option.configKey)
            }
    }

    private static func printHelp() {
        print("""
        crawlbar commands:
          apps [--json]
          backup --app <id> [--json]
          folder --app <id> [--json]
          logs [--json]
          metadata [--app <id>] [--json] [--diagnostics]
          status [--app <id|all>] [--json]
          install --app <id> [--json]
          query [--app <id|all>] [--json] -- <text-or-sql>
          doctor --app <id> [--json]
          refresh --app <id> [--json]
          action <action-id> --app <id> [--json]
          config path|validate|init
          config get --app <id> [--key <id>] [--json] [--reveal]
          config set --app <id> --key <id> --value <value> [--json]
        """)
    }
}

private struct CLIConfigValue: Encodable {
    var id: String
    var label: String
    var value: String?
    var secret: Bool
    var envVar: String?
    var configKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case value
        case secret
        case envVar = "env_var"
        case configKey = "config_key"
    }
}

private struct CLIApp: Encodable {
    var id: String
    var displayName: String
    var enabled: Bool
    var available: Bool
    var availability: CrawlAppManifest.Availability
    var binaryPath: String?
    var configPath: String?

    init(_ installation: CrawlAppInstallation) {
        self.id = installation.id.rawValue
        self.displayName = installation.manifest.displayName
        self.enabled = installation.enabled
        self.available = installation.binaryPath != nil
        self.availability = installation.manifest.availability
        self.binaryPath = installation.binaryPath
        self.configPath = installation.configPathOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case enabled
        case available
        case availability
        case binaryPath = "binary_path"
        case configPath = "config_path"
    }
}

private struct CLIOptions {
    var json = false
    var appID: CrawlAppID?
    var key: String?
    var value: String?
    var revealSecrets = false
    var diagnostics = false
    var positionals: [String] = []

    init(_ arguments: ArraySlice<String>) {
        var iterator = Array(arguments).makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                self.json = true
            case "--app":
                if let value = iterator.next() {
                    self.appID = CrawlAppID(rawValue: value)
                }
            case "--key":
                self.key = iterator.next()
            case "--value":
                self.value = iterator.next()
            case "--reveal":
                self.revealSecrets = true
            case "--diagnostics":
                self.diagnostics = true
            case "--":
                while let value = iterator.next() {
                    self.positionals.append(value)
                }
            default:
                self.positionals.append(argument)
            }
        }
    }

    func requiredAppID() throws -> CrawlAppID {
        guard let appID else {
            throw CLIError.usage("--app <id> is required")
        }
        return appID
    }
}

private enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            message
        }
    }
}
