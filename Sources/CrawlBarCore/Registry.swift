import Foundation

public struct CrawlAppRegistry: @unchecked Sendable {
    private let configStore: CrawlBarConfigStore
    private let catalog: CrawlManifestCatalog
    private let resolver: CrawlExecutableResolver
    private let nativeConfigStore: CrawlNativeConfigStore

    public init(
        configStore: CrawlBarConfigStore = CrawlBarConfigStore(),
        catalog: CrawlManifestCatalog = CrawlManifestCatalog(),
        resolver: CrawlExecutableResolver = CrawlExecutableResolver(),
        nativeConfigStore: CrawlNativeConfigStore = CrawlNativeConfigStore())
    {
        self.configStore = configStore
        self.catalog = catalog
        self.resolver = resolver
        self.nativeConfigStore = nativeConfigStore
    }

    public func loadConfig(includeSecrets: Bool = false) throws -> CrawlBarConfig {
        try self.configStore.loadOrCreateDefault(includeSecrets: includeSecrets)
    }

    public func installations(includeDisabled: Bool = true, includeSecrets: Bool = false) throws -> [CrawlAppInstallation] {
        let loadedConfig = try self.loadConfig(includeSecrets: includeSecrets)
        let manifests = Dictionary(uniqueKeysWithValues: self.catalog
            .manifests(config: loadedConfig)
            .map { ($0.id, $0) })
        let knownIDs = manifests.keys.sorted()
        let config = loadedConfig.normalized(knownIDs: knownIDs)
        return config.apps.compactMap { appConfig in
            guard let manifest = manifests[appConfig.id] else { return nil }
            let resolvedAppConfig = self.appConfigWithNativeValues(appConfig, manifest: manifest)
            let isAvailable = manifest.availability == .available
            let enabled = isAvailable && resolvedAppConfig.enabled
            guard includeDisabled || enabled else { return nil }
            let requestedBinary = resolvedAppConfig.binaryPath?.nilIfBlank ?? manifest.binary.name
            let resolvedBinary = isAvailable ? self.resolver.resolve(requestedBinary) : nil
            let refreshFrequency = resolvedAppConfig.refreshFrequency ?? config.refreshFrequency
            let staleAfterSeconds = resolvedAppConfig.autoRefreshEnabled ? refreshFrequency.seconds.map(Int.init) : nil
            return CrawlAppInstallation(
                manifest: manifest,
                binaryPath: resolvedBinary,
                configPathOverride: resolvedAppConfig.configPath,
                configValues: resolvedAppConfig.configValues,
                staleAfterSeconds: staleAfterSeconds,
                enabled: enabled)
        }
    }

    public func installation(for id: CrawlAppID, includeSecrets: Bool = false) throws -> CrawlAppInstallation? {
        try self.installations(includeDisabled: true, includeSecrets: includeSecrets).first { $0.id == id }
    }

    public func availableInstallations(includeSecrets: Bool = false) throws -> [CrawlAppInstallation] {
        try self.installations(includeDisabled: false, includeSecrets: includeSecrets).filter { $0.binaryPath != nil }
    }

    public func appConfigWithNativeValues(_ appConfig: CrawlBarAppConfig, manifest: CrawlAppManifest) -> CrawlBarAppConfig {
        var copy = appConfig
        copy.configValues = self.nativeConfigStore.resolvedConfigValues(appConfig: appConfig, manifest: manifest)
        return copy
    }
}
