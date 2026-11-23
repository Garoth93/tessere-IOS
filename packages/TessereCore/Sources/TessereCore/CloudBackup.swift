import Foundation

/// Automatic backups in iCloud Drive: shared container
/// `iCloud.com.garoth93.backup`, one sub-folder per app ("Tessere"),
/// visible in the Files app.
///
/// Files: `Tessere-backup-yyyy-MM-dd.json` (one per day, overwritten during
/// the day, the last `keepDaily` kept) plus `Tessere-backup-latest.json`.
/// Each file is a `BackupFile` (JSON with `version`).
public enum CloudBackupPlan {
    public static let containerID = "iCloud.com.garoth93.backup"
    public static let folderName = "Tessere"
    public static let latestName = "Tessere-backup-latest.json"
    public static let prefix = "Tessere-backup-"
    public static let keepDaily = 30

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Day of the backup (nil for "latest").
        public var day: Date?
        public var isLatest: Bool { day == nil }
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func dailyName(for date: Date) -> String {
        "\(prefix)\(dayFormatter().string(from: date)).json"
    }

    /// iCloud placeholder of a file not downloaded yet: ".name.json.icloud".
    public static func realName(_ fileName: String) -> String {
        guard fileName.hasPrefix("."), fileName.hasSuffix(".icloud") else { return fileName }
        return String(fileName.dropFirst().dropLast(".icloud".count))
    }

    /// Backups found in the folder, newest first ("latest" on top).
    public static func entries(fromFileNames names: [String]) -> [Entry] {
        let f = dayFormatter()
        var latest: Entry?
        var daily: [Entry] = []
        for raw in Set(names.map(realName)) {
            if raw == latestName {
                latest = Entry(name: raw, day: nil)
            } else if raw.hasPrefix(prefix), raw.hasSuffix(".json") {
                let stamp = String(raw.dropFirst(prefix.count).dropLast(5))
                if let d = f.date(from: stamp) { daily.append(Entry(name: raw, day: d)) }
            }
        }
        daily.sort { $0.day! > $1.day! }
        return (latest.map { [$0] } ?? []) + daily
    }

    /// Daily files beyond the newest `keep`.
    public static func namesToPrune(_ names: [String], keep: Int = keepDaily) -> [String] {
        let daily = entries(fromFileNames: names).filter { !$0.isLatest }
        return daily.count > keep ? daily[keep...].map(\.name) : []
    }

    /// Fingerprint of what a backup contains (cards, settings, logos), not of
    /// when it was made: an unchanged fingerprint means no new backup needed.
    public static func fingerprint(_ backup: BackupFile) -> String {
        var b = backup
        b.exportedAt = Date(timeIntervalSince1970: 0)
        guard let data = try? JSONFileStore<BackupFile>.encoder(compact: true).encode(b) else { return "" }
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16) + "-" + String(data.count)
    }
}
