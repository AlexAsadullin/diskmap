import Foundation

/// A saved scan: the tree plus when and where it was made.
public struct ScanDocument {
    public var root: Node
    public var date: Date
    public var volume: VolumeInfo?

    public init(root: Node, date: Date, volume: VolumeInfo?) {
        self.root = root
        self.date = date
        self.volume = volume
    }
}

public enum ArchiveError: Error, LocalizedError {
    case badFormat

    public var errorDescription: String? { T("Файл не является результатом сканирования DiskMap.", "The file is not a DiskMap scan result.") }
}

/// Compact binary format (.diskmap): header, then nodes in pre-order.
public enum ScanArchive {
    public static let fileExtension = "diskmap"
    private static let magic: [UInt8] = Array("DMAP".utf8)
    private static let version: UInt32 = 1

    public static func write(_ doc: ScanDocument, to url: URL) throws {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func putBytes(_ b: [UInt8]) { put(UInt32(b.count)); out.append(contentsOf: b) }

        out.append(contentsOf: magic)
        put(version)
        put(doc.date.timeIntervalSince1970.bitPattern)
        putBytes(doc.volume.flatMap { try? JSONEncoder().encode($0) }.map { [UInt8]($0) } ?? [])

        var stack: [Node] = [doc.root]
        while let n = stack.popLast() {
            let name = Array(n.name.utf8.prefix(Int(UInt16.max)))
            put(UInt16(name.count))
            out.append(contentsOf: name)
            put(n.flags.rawValue)
            put(n.category)
            put(n.physical)
            put(n.logical)
            put(n.mtime)
            if n.isDirectory {
                put(UInt32(n.children.count))
                stack.append(contentsOf: n.children.reversed())
            }
        }
        try Data(out).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ScanDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ScanDocument in
            var pos = 0
            func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
                guard pos + MemoryLayout<T>.size <= raw.count else { throw ArchiveError.badFormat }
                let v = raw.loadUnaligned(fromByteOffset: pos, as: T.self)
                pos += MemoryLayout<T>.size
                return T(littleEndian: v)
            }
            func getBytes(_ n: Int) throws -> UnsafeRawBufferPointer {
                guard pos + n <= raw.count else { throw ArchiveError.badFormat }
                defer { pos += n }
                return UnsafeRawBufferPointer(rebasing: raw[pos..<pos + n])
            }

            guard raw.count > 8, Array(try getBytes(4)) == magic, try get(UInt32.self) == version else { throw ArchiveError.badFormat }
            let date = Date(timeIntervalSince1970: Double(bitPattern: try get(UInt64.self)))
            let volLen = Int(try get(UInt32.self))
            let volume = try? JSONDecoder().decode(VolumeInfo.self, from: Data(try getBytes(volLen)))

            func readNode() throws -> (Node, Int) {
                let len = Int(try get(UInt16.self))
                let name = String(decoding: try getBytes(len), as: UTF8.self)
                let flags = NodeFlags(rawValue: try get(UInt8.self))
                let category = try get(UInt8.self)
                let physical = try get(Int64.self)
                let logical = try get(Int64.self)
                let mtime = try get(UInt32.self)
                let n = Node(name: name, flags: flags, physical: physical, logical: logical, mtime: mtime)
                n.category = category
                let count = flags.contains(.directory) ? Int(try get(UInt32.self)) : 0
                return (n, count)
            }

            let (root, rootCount) = try readNode()
            var stack: [(Node, Int)] = [(root, rootCount)]
            while !stack.isEmpty {
                let top = stack.count - 1
                if stack[top].1 == 0 { stack.removeLast(); continue }
                stack[top].1 -= 1
                let (child, count) = try readNode()
                let parent = stack[top].0
                child.parent = parent
                parent.children.append(child)
                if count > 0 { stack.append((child, count)) }
            }
            TreeOps.aggregate(root)
            return ScanDocument(root: root, date: date, volume: volume)
        }
    }
}
