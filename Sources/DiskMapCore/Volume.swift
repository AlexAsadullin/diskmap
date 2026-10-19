import Foundation

public struct VolumeInfo: Codable, Equatable {
    public var name: String
    public var mountPath: String
    public var capacity: Int64
    /// Free space, not counting purgeable data.
    public var available: Int64
    /// Free space including purgeable data that macOS can release.
    public var availableForImportantUsage: Int64
    public var readOnly: Bool
    public var format: String
    public var snapshotCount: Int

    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedNameKey, .volumeURLKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let available = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            name: v.volumeLocalizedName ?? v.volumeName ?? path,
            mountPath: v.volume?.path ?? "/",
            capacity: Int64(total),
            available: available,
            availableForImportantUsage: max(available, v.volumeAvailableCapacityForImportantUsage ?? available),
            readOnly: v.volumeIsReadOnly ?? false,
            format: v.volumeLocalizedFormatDescription ?? "",
            snapshotCount: 0)
    }

    /// True when the scan root is a whole volume (so free space blocks make sense).
    public static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]) else { return false }
        return v.isVolume ?? false
    }

    public static func isReadOnly(path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }

    /// Local Time Machine snapshots, as listed by `tmutil listlocalsnapshots`.
    public static func localSnapshotCount(mountPath: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", mountPath]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }

    /// Adds free, purgeable and "snapshots & system volumes" blocks to a volume scan
    /// so that all blocks together add up to the volume capacity.
    public static func addSyntheticBlocks(to root: Node, volume: VolumeInfo, table: CategoryTable) {
        root.children.removeAll { $0.isSynthetic }
        TreeOps.aggregate(root)
        let used = root.physical
        let free = volume.available
        let purge = volume.purgeable
        let rest = max(0, volume.capacity - free - purge - used)

        func block(_ name: String, _ size: Int64, _ cat: UInt8) {
            guard size > 0 else { return }
            let n = Node(name: name, flags: .synthetic, physical: size, logical: size)
            n.category = cat
            n.parent = root
            root.children.append(n)
        }
        block(T("Свободно", "Free space"), free, table.free)
        block(T("Очищаемое (purgeable)", "Purgeable"), purge, table.purgeable)
        let snaps = volume.snapshotCount
        let restName = snaps > 0
            ? T("Снимки Time Machine (\(snaps)) и служебные тома", "Time Machine snapshots (\(snaps)) & system volumes")
            : T("Снимки и служебные тома", "Snapshots & system volumes")
        block(restName, rest, table.reserved)
        TreeOps.aggregate(root)
    }
}
