import CrawlBarCore
import Foundation

@main
enum CrawlBarSelfTest {
    static func main() throws {
        try Self.testAppIDSortsByRawValue()
        try Self.testDefaultConfigNormalizesBuiltInApps()
        try Self.testConfigStoreRoundTrips()
        try Self.testExternalManifestCatalog()
        try Self.testNativeConfigRoundTrips()
        try Self.testStatusMapperNormalizesCounts()
        try Self.testActionFailuresPreserveStatusMetadata()
        try Self.testConfigValuesReachCommandEnvironment()
        try Self.testCommandTimeoutEscalates()
        try Self.testDatabaseBackupCopiesFiles()
        try Self.testRedactorScrubsSecrets()
        print("crawlbar selftest ok")
    }

    private static func testAppIDSortsByRawValue() throws {
        try Self.expect(
            [CrawlAppID(rawValue: "b"), CrawlAppID(rawValue: "a")].sorted().map(\.rawValue) == ["a", "b"],
            "app ids sort by raw value")
    }

    private static func testDefaultConfigNormalizesBuiltInApps() throws {
        let config = CrawlBarConfig(apps: []).normalized()
        try Self.expect(config.version == CrawlBarConfig.currentVersion, "config version normalizes")
        try Self.expect(config.apps.map(\.id) == BuiltInCrawlApps.all.map(\.id), "built-in apps are present")
        try Self.expect(config.appConfig(for: BuiltInCrawlApps.gogcliID)?.enabled == false, "coming soon apps normalize disabled")
        try Self.expect(config.appConfig(for: BuiltInCrawlApps.gogcliID)?.showInMenuBar == false, "coming soon apps stay out of menu bar")
        try Self.expect(config.manifestDirectories == ["~/.crawlbar/apps"], "manifest directory default is present")
    }

    private static func testConfigStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.json")
        let store = CrawlBarConfigStore(fileURL: url)
        let config = CrawlBarConfig(
            refreshFrequency: .hourly,
            apps: [CrawlBarAppConfig(
                id: BuiltInCrawlApps.gitcrawlID,
                enabled: false,
                configValues: ["embedding_model": "text-embedding-3-large"])])

        try store.save(config)
        guard let loaded = try store.load() else {
            throw SelfTestError.failed("config loads after save")
        }

        try Self.expect(loaded.refreshFrequency == .hourly, "refresh frequency round trips")
        try Self.expect(loaded.appConfig(for: BuiltInCrawlApps.gitcrawlID)?.enabled == false, "app enablement round trips")
        try Self.expect(loaded.appConfig(for: BuiltInCrawlApps.gitcrawlID)?.configValues["embedding_model"] == "text-embedding-3-large", "app config values round trip")
        try Self.expect(loaded.apps.count == BuiltInCrawlApps.all.count, "config store normalizes built-ins")
    }

    private static func testExternalManifestCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = CrawlAppManifest(
            id: CrawlAppID(rawValue: "customcrawl"),
            displayName: "Custom Crawl",
            description: "A custom crawl app",
            binary: .init(name: "customcrawl"),
            branding: .init(symbolName: "square.grid.2x2", accentColor: "#123456"),
            paths: .init(defaultConfig: "~/.customcrawl/config.toml"),
            commands: ["status": ["status", "--json"]],
            capabilities: [.status])
        let data = try CrawlCoding.makeJSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("customcrawl.json"))
        try Data("""
        {
          "schema_version": "crawlkit.control.v1",
          "id": "objectcrawl",
          "display_name": "Object Crawl",
          "description": "A crawlkit manifest",
          "binary": {"name": "objectcrawl"},
          "branding": {"symbol_name": "tray", "accent_color": "#123456"},
          "paths": {"default_config": "~/.objectcrawl/config.toml"},
          "commands": {
            "status": {"title": "Status", "argv": ["objectcrawl", "status", "--json"], "json": true},
            "sync": {"title": "Sync", "argv": ["objectcrawl", "sync", "--json"], "json": true, "mutates": true},
            "tap": {"title": "Desktop", "argv": ["objectcrawl", "tap", "--json"], "json": true, "mutates": true}
          },
          "capabilities": ["metadata", "status", "sync", "tap", "git-share"],
          "privacy": {"exports_secrets": false}
        }
        """.utf8).write(to: directory.appendingPathComponent("objectcrawl.json"))
        try Data("{ bad json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let config = CrawlBarConfig(manifestDirectories: [directory.path])
        let catalog = CrawlManifestCatalog()
        let manifests = catalog.manifests(config: config)
        let diagnostics = catalog.diagnostics(config: config)
        let configURL = directory.appendingPathComponent("config.json")
        let store = CrawlBarConfigStore(fileURL: configURL)
        try store.save(config)
        let registry = CrawlAppRegistry(configStore: store, catalog: catalog)
        let installations = try registry.installations(includeDisabled: true)
        try Self.expect(manifests.contains { $0.id == manifest.id }, "external manifests load from disk")
        guard let objectManifest = manifests.first(where: { $0.id.rawValue == "objectcrawl" }) else {
            throw SelfTestError.failed("crawlkit command-object manifests load from disk")
        }
        try Self.expect(objectManifest.commands["status"] == ["status", "--json"], "crawlkit command argv strips binary")
        try Self.expect(objectManifest.capabilities.contains(.refresh), "crawlkit sync capability maps to refresh")
        try Self.expect(objectManifest.capabilities.contains(.desktopCache), "crawlkit tap capability maps to desktop cache")
        try Self.expect(objectManifest.capabilities.contains(.publish), "crawlkit git-share capability maps to publish")
        try Self.expect(diagnostics.contains { $0.path.hasSuffix("broken.json") }, "external manifest parse errors are reported")
        try Self.expect(installations.contains { $0.id == manifest.id }, "external manifests appear as installations")
        try Self.expect(BuiltInCrawlApps.gitcrawl.configOptions.contains { $0.id == "embedding_model" }, "built-in config options exist")
        try Self.expect(!BuiltInCrawlApps.gitcrawl.needsSecretsForStatus, "built-in status avoids launch keychain reads")
        let secretStatusManifest = CrawlAppManifest(
            id: CrawlAppID(rawValue: "secretstatus"),
            displayName: "Secret Status",
            description: "Status requires an env secret",
            binary: .init(name: "secretstatus"),
            branding: .init(symbolName: "lock", accentColor: "#123456"),
            paths: .init(),
            commands: ["status": ["status", "--json"]],
            capabilities: [.status],
            configOptions: [.init(id: "token", label: "Token", kind: .secret, envVar: "SECRET_STATUS_TOKEN")])
        try Self.expect(secretStatusManifest.needsSecretsForStatus, "external secret status can opt into keychain reads")
        try Self.expect(BuiltInCrawlApps.slacrawl.privacy.containsPrivateMessages, "Slack privacy metadata flags local messages")
        try Self.expect(BuiltInCrawlApps.notcrawl.privacy.localOnlyScopes.contains("workspace pages"), "Notion privacy metadata flags workspace pages")
        try Self.expect(BuiltInCrawlApps.slacrawl.install?.package == "vincentkoc/tap/slacrawl", "built-in install metadata exists")
        try Self.expect(BuiltInCrawlApps.gogcli.availability == .comingSoon, "coming soon manifests are marked unavailable")
        try Self.expect(BuiltInCrawlApps.graincrawl.availability == .available, "graincrawl is available")
        try Self.expect(BuiltInCrawlApps.graincrawl.commands["status"] == ["status", "--json"], "graincrawl uses crawlkit status command")
        try Self.expect(
            BuiltInCrawlApps.graincrawl.commands["refresh"] == ["sync", "--source", "desktop-cache", "--json"],
            "graincrawl refresh uses desktop cache by default")
        try Self.expect(BuiltInCrawlApps.gitcrawl.commands["status"] == ["status", "--json"], "gitcrawl uses fast status command")
        try Self.expect(BuiltInCrawlApps.gitcrawl.configSections.contains { $0.id == "github" }, "built-in config sections exist")
    }

    private static func testNativeConfigRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-native-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.toml")
        try Data("""
        [openai]
        api_key = "from-file"
        """.utf8).write(to: configURL)

        let manifest = CrawlAppManifest(
            id: CrawlAppID(rawValue: "tomlcrawl"),
            displayName: "TOML Crawl",
            description: "A TOML test crawler",
            binary: .init(name: "tomlcrawl"),
            branding: .init(symbolName: "terminal", accentColor: "#123456"),
            paths: .init(defaultConfig: configURL.path),
            commands: [:],
            capabilities: [],
            configOptions: [
                .init(id: "openai_api_key", label: "OpenAI API key", kind: .secret, configKey: "openai.api_key"),
                .init(id: "embedding_model", label: "Embedding model", kind: .choice, configKey: "embeddings.model"),
            ])
        var appConfig = CrawlBarAppConfig(id: manifest.id)
        let nativeStore = CrawlNativeConfigStore()
        try Self.expect(
            nativeStore.resolvedConfigValues(appConfig: appConfig, manifest: manifest)["openai_api_key"] == "from-file",
            "native TOML config values load")

        appConfig.configValues = nativeStore.resolvedConfigValues(appConfig: appConfig, manifest: manifest)
        appConfig.configValues["embedding_model"] = "text-embedding-3-large"
        try nativeStore.write(appConfig: appConfig, manifest: manifest)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        try Self.expect(content.contains("api_key = \"from-file\""), "native TOML values preserve existing keys")
        try Self.expect(content.contains("[embeddings]"), "native TOML section writes")
        try Self.expect(content.contains("model = \"text-embedding-3-large\""), "native TOML value writes")

        appConfig.configValues.removeValue(forKey: "openai_api_key")
        try nativeStore.write(appConfig: appConfig, manifest: manifest)
        let clearedContent = try String(contentsOf: configURL, encoding: .utf8)
        try Self.expect(!clearedContent.contains("api_key ="), "native TOML keys clear when removed")
    }

    private static func testStatusMapperNormalizesCounts() throws {
        let output = """
        {"message_count":42,"channel_count":3,"last_sync_at":"2026-05-01T12:00:00Z","db_path":"/tmp/discrawl.db"}
        """
        let result = CrawlCommandResult(
            appID: BuiltInCrawlApps.discrawlID,
            action: "status",
            exitCode: 0,
            stdout: output,
            stderr: "",
            startedAt: Date(),
            finishedAt: Date())

        let status = CrawlStatusMapper().status(from: result, manifest: BuiltInCrawlApps.discrawl)
        try Self.expect(status.counts.contains(CrawlCount(id: "messages", label: "Messages", value: 42)), "discrawl messages map")
        try Self.expect(status.lastSyncAt != nil, "whole-second last sync dates map")
        try Self.expect(status.databasePath == "/tmp/discrawl.db", "database path maps")
        try Self.expect(status.databases.first?.label == "Discord archive", "database inventory maps")
        try Self.expect(status.databases.first?.counts.contains(CrawlCount(id: "messages", label: "Messages", value: 42)) == true, "database inventory carries counts")

        let crawlKitOutput = """
        {
          "schema_version": "crawlkit.control.v1",
          "app_id": "discrawl",
          "state": "current",
          "summary": "5052 messages across 293 channels",
          "database_path": "/tmp/discrawl.db",
          "database_bytes": 36397056,
          "counts": [
            {"id": "guilds", "label": "Guilds", "value": 56},
            {"id": "channels", "label": "Channels", "value": 293},
            {"id": "messages", "label": "Messages", "value": 5052}
          ],
          "databases": [
            {
              "id": "primary",
              "label": "Discord archive",
              "kind": "sqlite",
              "role": "archive",
              "path": "/tmp/discrawl.db",
              "is_primary": true,
              "bytes": 36397056,
              "modified_at": "2026-04-24T07:38:30Z",
              "counts": [
                {"id": "messages", "label": "Messages", "value": 5052}
              ]
            }
          ]
        }
        """
        let crawlKitResult = CrawlCommandResult(
            appID: BuiltInCrawlApps.discrawlID,
            action: "status",
            exitCode: 0,
            stdout: crawlKitOutput,
            stderr: "",
            startedAt: Date(),
            finishedAt: Date())

        let crawlKitStatus = CrawlStatusMapper().status(from: crawlKitResult, manifest: BuiltInCrawlApps.discrawl)
        try Self.expect(crawlKitStatus.summary == "5052 messages across 293 channels", "crawlkit status summary maps")
        try Self.expect(crawlKitStatus.state == .stale, "stale freshness wins over current state")
        try Self.expect(crawlKitStatus.databaseBytes == 36397056, "crawlkit database bytes map")
        try Self.expect(crawlKitStatus.counts.contains(CrawlCount(id: "messages", label: "Messages", value: 5052)), "crawlkit count array maps")
        try Self.expect(crawlKitStatus.databases.first?.id == "primary", "crawlkit databases map")
        try Self.expect(crawlKitStatus.databases.first?.modifiedAt != nil, "crawlkit database modified date maps")
        try Self.expect(crawlKitStatus.databases.first?.counts.contains(CrawlCount(id: "messages", label: "Messages", value: 5052)) == true, "crawlkit database counts map")

        let okOutput = """
        {
          "schema_version": "crawlkit.control.v1",
          "app_id": "graincrawl",
          "state": "ok",
          "summary": "1 notes",
          "counts": [{"id": "notes", "label": "Notes", "value": 1}]
        }
        """
        let okResult = CrawlCommandResult(
            appID: BuiltInCrawlApps.graincrawlID,
            action: "status",
            exitCode: 0,
            stdout: okOutput,
            stderr: "",
            startedAt: Date(),
            finishedAt: Date())
        let okStatus = CrawlStatusMapper().status(from: okResult, manifest: BuiltInCrawlApps.graincrawl)
        try Self.expect(okStatus.state == .current, "crawlkit ok state maps to current")
    }

    private static func testConfigValuesReachCommandEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("print-env.sh")
        try Data("""
        #!/bin/sh
        printf '%s' "$CRAWLBAR_TEST_VALUE"
        """.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifest = CrawlAppManifest(
            id: CrawlAppID(rawValue: "envcrawl"),
            displayName: "Env Crawl",
            description: "A test crawler",
            binary: .init(name: scriptURL.path),
            branding: .init(symbolName: "terminal", accentColor: "#123456"),
            paths: .init(),
            commands: ["status": []],
            capabilities: [.status],
            configOptions: [
                .init(id: "test_value", label: "Test Value", envVar: "CRAWLBAR_TEST_VALUE"),
            ])
        let installation = CrawlAppInstallation(
            manifest: manifest,
            binaryPath: scriptURL.path,
            configValues: ["test_value": "from-config"])
        let result = try CrawlCommandRunner().run(installation: installation, action: "status", timeoutSeconds: 5)
        try Self.expect(result.stdout == "from-config", "config values reach crawler command environment")
    }

    private static func testActionFailuresPreserveStatusMetadata() throws {
        let lastSyncAt = Date(timeIntervalSince1970: 1_775_000_000)
        let metadata = CrawlAppStatus(
            appID: BuiltInCrawlApps.discrawlID,
            state: .current,
            summary: "5052 messages",
            configPath: "/tmp/discrawl.toml",
            databasePath: "/tmp/discrawl.db",
            databaseBytes: 36_397_056,
            lastSyncAt: lastSyncAt,
            counts: [CrawlCount(id: "messages", label: "Messages", value: 5052)],
            databases: [
                CrawlDatabaseResource(
                    id: "primary",
                    label: "Discord archive",
                    kind: .sqlite,
                    path: "/tmp/discrawl.db",
                    isPrimary: true,
                    bytes: 36_397_056),
            ],
            freshness: CrawlFreshness(status: .current, ageSeconds: 12, staleAfterSeconds: 86_400),
            share: CrawlShareStatus(enabled: true, repoPath: "/tmp/share", remote: "origin", branch: "main"),
            warnings: ["old warning"])
        let failure = CrawlAppStatus(
            appID: BuiltInCrawlApps.discrawlID,
            state: .error,
            summary: "refresh: network timed out",
            errors: ["network timed out"])

        let merged = metadata.mergingActionFailure(failure)
        try Self.expect(merged.state == .error, "action failure state is visible")
        try Self.expect(merged.summary == "refresh: network timed out", "action failure summary is visible")
        try Self.expect(merged.databasePath == metadata.databasePath, "action failure preserves database path")
        try Self.expect(merged.databases == metadata.databases, "action failure preserves databases")
        try Self.expect(merged.counts == metadata.counts, "action failure preserves counts")
        try Self.expect(merged.lastSyncAt == lastSyncAt, "action failure preserves last sync")
        try Self.expect(merged.share == metadata.share, "action failure preserves share metadata")
        try Self.expect(merged.warnings == ["old warning"], "action failure preserves existing warnings")
        try Self.expect(merged.errors == ["network timed out"], "action failure keeps failure errors")

        let emptyRefreshed = CrawlAppStatus(
            appID: BuiltInCrawlApps.discrawlID,
            state: .error,
            summary: "status failed")
        let richest = CrawlAppStatus.richestMetadataStatus(emptyRefreshed, fallback: metadata)
        try Self.expect(richest == metadata, "previous rich metadata wins over empty refreshed status")
    }

    private static func testCommandTimeoutEscalates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("ignore-term.sh")
        try Data("""
        #!/bin/sh
        trap '' TERM
        sleep 5
        """.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifest = CrawlAppManifest(
            id: CrawlAppID(rawValue: "timeoutcrawl"),
            displayName: "Timeout Crawl",
            description: "A timeout test crawler",
            binary: .init(name: scriptURL.path),
            branding: .init(symbolName: "timer", accentColor: "#123456"),
            paths: .init(),
            commands: ["status": []],
            capabilities: [.status])
        let installation = CrawlAppInstallation(manifest: manifest, binaryPath: scriptURL.path)
        let startedAt = Date()
        do {
            _ = try CrawlCommandRunner().run(installation: installation, action: "status", timeoutSeconds: 0.1)
            throw SelfTestError.failed("timeout command should not complete")
        } catch CrawlCommandRunnerError.timedOut {
            try Self.expect(Date().timeIntervalSince(startedAt) < 2.5, "timed-out commands are killed promptly")
        }
    }

    private static func testDatabaseBackupCopiesFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crawlbar-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstDatabaseURL = firstDirectory.appendingPathComponent("sample.db")
        let secondDatabaseURL = secondDirectory.appendingPathComponent("sample.db")
        try Self.createSQLiteDatabase(firstDatabaseURL, value: "sqlite-one")
        try Self.createSQLiteDatabase(secondDatabaseURL, value: "sqlite-two")
        let status = CrawlAppStatus(
            appID: BuiltInCrawlApps.notcrawlID,
            state: .current,
            summary: "ok",
            databases: [
                CrawlDatabaseResource(
                    id: firstDatabaseURL.path,
                    label: "Workspace One",
                    kind: .sqlite,
                    path: firstDatabaseURL.path,
                    isPrimary: true),
                CrawlDatabaseResource(
                    id: secondDatabaseURL.path,
                    label: "Workspace Two",
                    kind: .sqlite,
                    path: secondDatabaseURL.path,
                    isPrimary: false),
            ])

        let backup = try CrawlDatabaseBackupStore.backup(status: status, root: directory.appendingPathComponent("backups", isDirectory: true))
        try Self.expect(backup.files.count == 2, "backup copies duplicate-named files")
        try Self.expect(Set(backup.files.map { URL(fileURLWithPath: $0).lastPathComponent }).count == 2, "backup destination names are unique")
        let copiedContents = try backup.files.map { try Self.sqliteValue(URL(fileURLWithPath: $0)) }
        try Self.expect(copiedContents.contains("sqlite-one"), "backup preserves first duplicate file")
        try Self.expect(copiedContents.contains("sqlite-two"), "backup preserves second duplicate file")
    }

    private static func testRedactorScrubsSecrets() throws {
        let redacted = CrawlCommandRedactor().redact("""
        token=abc123
        Authorization: Bearer secret-token
        discord_token=discord-secret
        github_pat_1234567890abcdef
        ghp_1234567890abcdef
        sk-proj-1234567890abcdef
        xoxc-1234567890abcdef
        secret_notion123
        mfa.discordsecret
        label=Discord archive
        """)
        try Self.expect(!redacted.contains("abc123"), "token value redacts")
        try Self.expect(!redacted.contains("secret-token"), "bearer value redacts")
        try Self.expect(!redacted.contains("discord-secret"), "discord token value redacts")
        try Self.expect(!redacted.contains("1234567890abcdef"), "bare tokens redact")
        try Self.expect(!redacted.contains("notion123"), "notion secrets redact")
        try Self.expect(redacted.contains("Discord archive"), "discord labels are not redacted")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SelfTestError.failed(message)
        }
    }

    private static func createSQLiteDatabase(_ url: URL, value: String) throws {
        try Self.runSQLite(url, sql: "create table sample(value text); insert into sample(value) values('\(value)');")
    }

    private static func sqliteValue(_ url: URL) throws -> String {
        try Self.runSQLite(url, sql: "select value from sample limit 1;")
    }

    @discardableResult
    private static func runSQLite(_ url: URL, sql: String) throws -> String {
        guard let sqlitePath = CrawlExecutableResolver().resolve("sqlite3") else {
            throw SelfTestError.failed("sqlite3 is available")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = [url.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SelfTestError.failed("sqlite3 failed: \(text)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum SelfTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            "selftest failed: \(message)"
        }
    }
}
