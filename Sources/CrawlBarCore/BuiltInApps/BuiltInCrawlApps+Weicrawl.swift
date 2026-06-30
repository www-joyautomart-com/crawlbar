import Foundation

public extension BuiltInCrawlApps {
    static let weicrawl = CrawlAppManifest(
        id: Self.weicrawlID,
        displayName: "WeChat",
        description: "Local-first Weixin/WeChat desktop archive",
        binary: .init(name: "weicrawl"),
        branding: .init(
            symbolName: "message.fill",
            accentColor: "#07C160",
            bundleIdentifier: "com.tencent.xinWeChat"),
        paths: .init(
            defaultConfig: "~/.config/weicrawl/config.toml",
            configEnv: "WEICRAWL_CONFIG",
            defaultDatabase: "~/.config/weicrawl/weicrawl.db",
            defaultCache: "~/.cache/weicrawl",
            defaultLogs: "~/.local/state/weicrawl/logs"),
        commands: [
            "metadata": ["--json", "metadata"],
            "status": ["--json", "status"],
            "doctor": ["--json", "doctor"],
            "refresh": ["--json", "sync", "--source", "all"],
            "desktop-cache-import": ["--json", "sync", "--source", "desktop-macos", "--keep-source-snapshot"],
            "unlock": ["--json", "unlock", "status"],
            "query": ["--json", "sql"],
            "search": ["--json", "search"],
            "export-md": ["--json", "export", "--format", "markdown", "--out", "./weicrawl-export"],
            "snapshot": ["--json", "snapshot"],
        ],
        capabilities: [.status, .doctor, .refresh, .search, .desktopCache, .exportMarkdown, .exportDatabase],
        statusRequiresSecrets: false,
        privacy: .init(
            containsPrivateMessages: true,
            exportsSecrets: false,
            localOnlyScopes: ["WeChat desktop", "copied snapshots", "decrypted SQLite imports"]),
        configOptions: [
            .init(
                id: "official_app_id",
                label: "Official Account app ID",
                kind: .string,
                help: "Optional Weixin Official Account app ID for official-account sync.",
                envVar: "WEICRAWL_WECHAT_APP_ID"),
            .init(
                id: "official_app_secret",
                label: "Official Account app secret",
                kind: .secret,
                help: "Optional Weixin Official Account app secret. It is passed as an environment variable, not persisted into weicrawl output.",
                envVar: "WEICRAWL_WECHAT_APP_SECRET"),
            .init(
                id: "official_api_base_url",
                label: "Official API base URL",
                kind: .string,
                help: "Override used for local tests or controlled gateways.",
                placeholder: "https://api.weixin.qq.com",
                envVar: "WEICRAWL_WECHAT_API_BASE_URL"),
        ],
        configSections: [
            .init(
                id: "official-account",
                title: "Official Account API",
                optionIDs: ["official_app_id", "official_app_secret", "official_api_base_url"]),
        ],
        install: .init(method: .homebrew, package: "vincentkoc/tap/weicrawl"))
        .withSuggestion(Self.appSuggest("WeChat", ["com.tencent.xinWeChat"]))
}
