import AppKit
@preconcurrency import DiskMapCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--csv") || arguments.contains("--help") || arguments.contains("-h") {
    exit(CLI.run(arguments))
}

// Paths given on the command line (`diskmap <path>`) are scanned on launch.
// Finder passes options such as "-NSDocumentRevisionsDebugMode YES"; keep only existing paths.
let launchPaths = arguments.filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
    .map { DiskScanner.canonicalPath($0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(launchPaths: launchPaths)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    _ = delegate
}
