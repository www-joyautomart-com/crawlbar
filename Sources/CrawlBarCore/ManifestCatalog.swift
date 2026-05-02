import Foundation

public struct CrawlManifestDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var message: String

    public var id: String {
        self.path
    }

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct CrawlManifestCatalog: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func manifests(config: CrawlBarConfig) -> [CrawlAppManifest] {
        var manifestsByID: [CrawlAppID: CrawlAppManifest] = [:]
        for manifest in BuiltInCrawlApps.all {
            manifestsByID[manifest.id] = manifest
        }
        for manifest in self.externalManifestScan(directories: config.manifestDirectories).manifests {
            manifestsByID[manifest.id] = manifest
        }
        return manifestsByID.values.sorted { $0.id < $1.id }
    }

    public func manifest(for id: CrawlAppID, config: CrawlBarConfig) -> CrawlAppManifest? {
        self.manifests(config: config).first { $0.id == id }
    }

    public func diagnostics(config: CrawlBarConfig) -> [CrawlManifestDiagnostic] {
        self.externalManifestScan(directories: config.manifestDirectories).diagnostics
    }

    private func externalManifestScan(directories: [String]) -> (manifests: [CrawlAppManifest], diagnostics: [CrawlManifestDiagnostic]) {
        var manifests: [CrawlAppManifest] = []
        var diagnostics: [CrawlManifestDiagnostic] = []

        for directory in directories {
            let expanded = PathExpander.expandHome(directory)
            guard let enumerator = self.fileManager.enumerator(
                at: URL(fileURLWithPath: expanded, isDirectory: true),
                includingPropertiesForKeys: nil)
            else {
                continue
            }

            for item in enumerator {
                guard let url = item as? URL, url.pathExtension == "json" else { continue }
                do {
                    let data = try Data(contentsOf: url)
                    manifests.append(try CrawlCoding.makeJSONDecoder().decode(CrawlAppManifest.self, from: data))
                } catch {
                    diagnostics.append(CrawlManifestDiagnostic(
                        path: url.path,
                        message: error.localizedDescription))
                }
            }
        }

        return (manifests, diagnostics)
    }
}
