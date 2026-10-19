import Foundation
import Darwin

/// Multithreaded directory scanner built on getattrlistbulk(2).
///
/// - Reads metadata only; never opens file contents.
/// - Stays on the root's volume and does not follow symbolic links.
/// - Counts each hard-linked inode once.
/// - Does not materialize dataless (iCloud) files or folders.
public final class DiskScanner {
    public struct Progress {
        public var files = 0
        public var folders = 0
        public var physical: Int64 = 0
        public var noAccess = 0
        public var currentPath = ""
        public init() {}
    }

    public let rootPath: String
    /// Called (on a scanner thread) with the path of every folder that could not be opened.
    public var onNoAccess: ((String) -> Void)?
    public var threadCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12)

    private let progressLock = NSLock()
    private var progressValue = Progress()

    private let cond = NSCondition()
    private var queue: [(Node, String)] = []
    private var active = 0
    private var cancelled = false

    private var allowedDevices: Set<Int32> = []
    private var skippedPaths: Set<String> = []

    private let linkLock = NSLock()
    private var seenInodes = Set<UInt64>()

    private static let bufferSize = 256 * 1024

    public init(rootPath: String) {
        self.rootPath = DiskScanner.canonicalPath(rootPath)
    }

    /// Absolute path with symlinks in the root itself resolved (e.g. /tmp → /private/tmp).
    public static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(expanded, &buf) != nil else { return expanded }
        return String(cString: buf)
    }

    public var progress: Progress {
        progressLock.lock(); defer { progressLock.unlock() }
        return progressValue
    }

    public var isCancelled: Bool {
        cond.lock(); defer { cond.unlock() }
        return cancelled
    }

    public func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    /// Scans synchronously. Returns nil when cancelled or the root cannot be read.
    public func run() -> Node? {
        DiskScanner.disableMaterialization()

        var st = stat()
        guard lstat(rootPath, &st) == 0 else { return nil }
        let mtime = UInt32(clamping: max(0, st.st_mtimespec.tv_sec))

        if (st.st_mode & S_IFMT) != S_IFDIR {
            let n = Node(name: rootPath, flags: [], physical: Int64(st.st_blocks) * 512, logical: Int64(st.st_size), mtime: mtime)
            return n
        }

        let root = Node(name: rootPath, flags: .directory, mtime: mtime)
        allowedDevices = [st.st_dev]
        if rootPath == "/" {
            // The data volume is firmlinked into "/" (/Users, /Applications, …); scan it once, through the firmlinks.
            var dst = stat()
            if stat("/System/Volumes/Data", &dst) == 0 {
                allowedDevices.insert(dst.st_dev)
                skippedPaths.insert("/System/Volumes/Data")
            }
        }

        queue = [(root, rootPath)]
        active = 0
        let group = DispatchGroup()
        for _ in 0..<threadCount {
            group.enter()
            let t = Thread { [self] in
                worker()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()

        if isCancelled { return nil }
        TreeOps.aggregate(root)
        return root
    }

    public static func disableMaterialization() {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        _ = setiopolicy_np(3, 0, 1)
    }

    // MARK: - Workers

    private func worker() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: DiskScanner.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var found: [(Node, String)] = []

        while true {
            cond.lock()
            while queue.isEmpty && active > 0 && !cancelled { cond.wait() }
            if queue.isEmpty || cancelled {
                cond.broadcast()
                cond.unlock()
                return
            }
            let (node, path) = queue.removeLast()
            active += 1
            cond.unlock()

            found.removeAll(keepingCapacity: true)
            scanDirectory(node, path: path, buffer: buffer, subfolders: &found)

            cond.lock()
            queue.append(contentsOf: found)
            active -= 1
            if !found.isEmpty || active == 0 { cond.broadcast() }
            cond.unlock()
        }
    }

    private static let commonAttrs: UInt32 =
        0x8000_0000 /* RETURNED_ATTRS */ | 0x0000_0001 /* NAME */ | 0x2000_0000 /* ERROR */ |
        0x0000_0002 /* DEVID */ | 0x0000_0008 /* OBJTYPE */ | 0x0000_0400 /* MODTIME */ |
        0x0004_0000 /* FLAGS */ | 0x0200_0000 /* FILEID */
    private static let fileAttrs: UInt32 = 0x1 /* LINKCOUNT */ | 0x2 /* TOTALSIZE */ | 0x4 /* ALLOCSIZE */

    private func scanDirectory(_ node: Node, path: String, buffer: UnsafeMutableRawPointer, subfolders: inout [(Node, String)]) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err != ENOENT {
                node.flags.insert(.noAccess)
                progressLock.lock(); progressValue.noAccess += 1; progressLock.unlock()
                onNoAccess?(path)
            }
            return
        }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = 5
        attrs.commonattr = DiskScanner.commonAttrs
        attrs.fileattr = DiskScanner.fileAttrs

        let prefix = path.hasSuffix("/") ? path : path + "/"
        var children: [Node] = []
        var files = 0
        var bytes: Int64 = 0

        loop: while true {
            let count = withUnsafeMutablePointer(to: &attrs) {
                getattrlistbulk(fd, $0, buffer, DiskScanner.bufferSize, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                node.flags.insert(.incomplete)
                break
            }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var p = entry + 4
                let retCommon = p.loadUnaligned(as: UInt32.self)
                let retFile = (p + 12).loadUnaligned(as: UInt32.self)
                p += 20 // attribute_set_t

                var error: UInt32 = 0
                if retCommon & 0x2000_0000 != 0 { error = p.loadUnaligned(as: UInt32.self); p += 4 }
                var name = ""
                if retCommon & 0x1 != 0 {
                    let off = Int(p.loadUnaligned(as: Int32.self))
                    name = String(cString: (p + off).assumingMemoryBound(to: CChar.self))
                    p += 8
                }
                var dev: Int32 = 0
                if retCommon & 0x2 != 0 { dev = p.loadUnaligned(as: Int32.self); p += 4 }
                var type: UInt32 = 0
                if retCommon & 0x8 != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                var mtime: Int = 0
                if retCommon & 0x400 != 0 { mtime = p.loadUnaligned(as: Int.self); p += 16 }
                var bsdFlags: UInt32 = 0
                if retCommon & 0x4_0000 != 0 { bsdFlags = p.loadUnaligned(as: UInt32.self); p += 4 }
                var inode: UInt64 = 0
                if retCommon & 0x200_0000 != 0 { inode = p.loadUnaligned(as: UInt64.self); p += 8 }
                var links: UInt32 = 1
                if retFile & 0x1 != 0 { links = p.loadUnaligned(as: UInt32.self); p += 4 }
                var total: Int64 = 0
                if retFile & 0x2 != 0 { total = p.loadUnaligned(as: Int64.self); p += 8 }
                var alloc: Int64 = 0
                if retFile & 0x4 != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }

                if name.isEmpty { continue }
                if name == ".git" { node.flags.insert(.gitRepository) }
                let mt = UInt32(clamping: max(0, mtime))
                let dataless = bsdFlags & 0x4000_0000 != 0

                if type == 2 { // VDIR
                    let childPath = prefix + name
                    if !allowedDevices.contains(dev) || skippedPaths.contains(childPath) { continue }
                    let child = Node(name: name, flags: .directory, mtime: mt)
                    child.parent = node
                    children.append(child)
                    if error != 0 {
                        child.flags.insert(.noAccess)
                    } else if dataless {
                        child.flags.insert(.dataless)
                    } else {
                        subfolders.append((child, childPath))
                    }
                } else {
                    var flags: NodeFlags = []
                    if type == 5 { flags.insert(.symlink) }
                    if dataless { flags.insert(.dataless) }
                    var phys = alloc, logi = total
                    if type == 1 && links > 1 && inode != 0 {
                        linkLock.lock()
                        let fresh = seenInodes.insert(inode).inserted
                        linkLock.unlock()
                        if !fresh {
                            flags.insert(.hardlinkDuplicate)
                            phys = 0
                            logi = 0
                        }
                    }
                    let child = Node(name: name, flags: flags, physical: phys, logical: logi, mtime: mt)
                    child.parent = node
                    children.append(child)
                    files += 1
                    bytes += phys
                }
                if isCancelledFast { break loop }
            }
        }
        node.children = children

        progressLock.lock()
        progressValue.files += files
        progressValue.folders += 1
        progressValue.physical += bytes
        progressValue.currentPath = path
        progressLock.unlock()
    }

    /// Unsynchronized read of the cancel flag; good enough to stop a long listing early.
    private var isCancelledFast: Bool { cancelled }
}
