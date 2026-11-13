import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
defer { try? fm.removeItem(at: temporary) }
let home = temporary.appendingPathComponent("Sandbox", isDirectory: true)
let group = temporary.appendingPathComponent("Group", isDirectory: true)

for container in [nil, group] as [URL?] {
    let paths = MinisStoragePaths(appGroupContainer: container, sandboxHome: home)
    let expectedRoot = container ?? home.appendingPathComponent("Library/Application Support/Minis", isDirectory: true)
    expect(paths.hasAppGroup == (container != nil), "App Group availability")
    expect(paths.providerRoot == expectedRoot.appendingPathComponent("MinisFileProvider", isDirectory: true), "Stable user data location")
    expect(paths.configRoot == expectedRoot.appendingPathComponent("MinisConfig", isDirectory: true), "Stable private metadata location")
    expect(!paths.configRoot.path.hasPrefix(paths.providerRoot.path + "/"), "Private metadata must not be exposed")

    for directory in ["memory", "skills", "shared"] {
        let target = paths.providerRoot.appendingPathComponent(directory, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("persistent-data.txt")
        try Data("retained".utf8).write(to: file, options: .atomic)
        // Simulate resolving storage again on the next launch.
        let reopened = MinisStoragePaths(appGroupContainer: container, sandboxHome: home)
        let data = try Data(contentsOf: reopened.providerRoot.appendingPathComponent(directory).appendingPathComponent("persistent-data.txt"))
        expect(data == Data("retained".utf8), "Data survives storage resolution")
    }
    try fm.createDirectory(at: paths.configRoot, withIntermediateDirectories: true)
}
print("PASS: App Group and sandbox fallback paths, private metadata separation, persistent reads/writes")
