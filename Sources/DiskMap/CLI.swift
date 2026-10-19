import Foundation
@preconcurrency import DiskMapCore

/// `diskmap --csv <path>`: scan without the interface and print a CSV list.
enum CLI {
    static let usage = """
    DiskMap — disk usage treemap for macOS

    Usage:
      diskmap <path>                          open the app and scan <path>
      diskmap --csv <path> [options]          print a CSV list without the interface

    Options for --csv:
      --depth N        list only N levels below <path> (default: all)
      --logical        sort by logical size instead of physical
      --output FILE    write to FILE instead of standard output
      --quiet          no progress on standard error

    """

    static func run(_ args: [String]) -> Int32 {
        if args.contains("--help") || args.contains("-h") {
            print(usage, terminator: "")
            return 0
        }
        var path: String?
        var depth: Int?
        var mode = SizeMode.physical
        var output: String?
        var quiet = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--csv": break
            case "--logical": mode = .logical
            case "--quiet", "-q": quiet = true
            case "--depth":
                i += 1
                guard i < args.count, let d = Int(args[i]), d >= 0 else { return fail("--depth needs a number") }
                depth = d
            case "--output", "-o":
                i += 1
                guard i < args.count else { return fail("--output needs a file name") }
                output = args[i]
            default:
                if args[i].hasPrefix("-") { return fail("unknown option \(args[i])") }
                path = args[i]
            }
            i += 1
        }
        guard let path else { return fail("no path given") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDir) else {
            return fail("\(path): no such file or folder")
        }

        let scanner = DiskScanner(rootPath: path)
        let done = CLIFlag()
        if !quiet {
            Thread.detachNewThread {
                while !done.value {
                    let p = scanner.progress
                    FileHandle.standardError.write(Data("\r\u{1B}[K\(p.files) files, \(Fmt.bytes(p.physical))".utf8))
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
        guard let root = scanner.run() else { return fail("cannot read \(path)") }
        done.value = true
        if !quiet {
            FileHandle.standardError.write(Data("\r\u{1B}[K\(root.fileCount) files, \(Fmt.bytes(root.physical))".utf8))
            if scanner.progress.noAccess > 0 {
                FileHandle.standardError.write(Data(", \(scanner.progress.noAccess) folders not accessible (grant Full Disk Access)".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
        }
        TreeOps.sort(root, mode: mode)
        let table = CategoryTable(
            colors: (UserDefaults.standard.dictionary(forKey: "colorOverrides") as? [String: Int] ?? [:]).mapValues { UInt32($0) },
            custom: UserDefaults.standard.data(forKey: "customCategories").flatMap { try? JSONDecoder().decode([CategoryDef].self, from: $0) } ?? [])
        table.categorize(root: root)

        let out: FileHandle
        if let output {
            guard FileManager.default.createFile(atPath: output, contents: nil), let h = FileHandle(forWritingAtPath: output) else {
                return fail("cannot write \(output)")
            }
            out = h
        } else {
            out = .standardOutput
        }
        CSVExport.write(root, table: table, mode: mode, maxDepth: depth) { out.write(Data($0.utf8)) }
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("diskmap: \(message)\n\nRun diskmap --help for usage.\n".utf8))
        return 2
    }
}

private final class CLIFlag: @unchecked Sendable {
    var value = false
}
