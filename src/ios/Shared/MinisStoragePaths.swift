import Foundation

/// Shared by the app and FileProvider. A re-signed build may not have the
/// App Group entitlement, even though it is present in the source project.
struct MinisStoragePaths: Sendable {
    static let appGroupID = "group.com.openminis.app"

    // Resolve once so every consumer in this process uses the same container.
    static let current = MinisStoragePaths(
        appGroupContainer: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ),
        sandboxHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    )

    let appGroupContainer: URL?
    let containerRoot: URL

    /// Explicit inputs keep regression tests out of the real app's storage.
    init(appGroupContainer: URL?, sandboxHome: URL) {
        self.appGroupContainer = appGroupContainer
        self.containerRoot = appGroupContainer ?? sandboxHome
            .appendingPathComponent("Library/Application Support/Minis", isDirectory: true)
    }

    var hasAppGroup: Bool { appGroupContainer != nil }

    var providerRoot: URL {
        containerRoot.appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    // Keep credentials and internal metadata outside the FileProvider tree,
    // including when running entirely in the app's private sandbox.
    var configRoot: URL {
        containerRoot.appendingPathComponent("MinisConfig", isDirectory: true)
    }
}
