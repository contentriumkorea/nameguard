import Foundation
#if canImport(NameGuard)
import NameGuard
#endif
#if canImport(NameGuardMenu)
import NameGuardMenu
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let home = FileManager.default.homeDirectoryForCurrentUser.path
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
let directory = option("--state-dir") ?? nameGuardDefaultDirectory(executable: executable, home: home)
let configPath = option("--config") ?? directory + "/config.json"
do {
    if arguments.contains("--help") {
        print("nameguard --menu | --watch | --audit | --roots [--config PATH] [--state-dir PATH]")
        exit(0)
    }
    if arguments.isEmpty || arguments.contains("--menu") {
        runMenuApp(directory: directory, configPath: configPath, executable: executable)
        exit(0)
    }
    var config = Configuration()
    if let data = FileManager.default.contents(atPath: configPath) {
        config = try JSONDecoder().decode(Configuration.self, from: data)
    }
    guard config.quietSeconds >= 1, config.directoryQuietSeconds >= config.quietSeconds else {
        throw NSError(domain: "NameGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid quiet periods"])
    }
    if arguments.contains("--roots") {
        print(discoverRoots(config).joined(separator: "\n"))
    } else if arguments.contains("--audit") {
        let watcher = try Watcher(config: config, directory: directory, auditOnly: true)
        exit(watcher.audit() == 0 ? 0 : 1)
    } else if arguments.contains("--watch") {
        try Watcher(config: config, directory: directory).run(parentPID: option("--parent-pid").flatMap(Int32.init))
    } else {
        fputs("Use --help, --audit, --roots, or --watch.\n", stderr)
        exit(2)
    }
} catch {
    fputs("NameGuard: \(error)\n", stderr)
    exit(1)
}
