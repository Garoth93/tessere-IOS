import Foundation
import UIKit
import TessereCore

/// Files shared by the app and the widgets through the App Group:
/// the widget snapshot and the processed logos.
///
/// The real group id is read from the provisioning profile, because
/// free-account signers (Sideloadly / SideStore) may rename it.
enum SharedStore {
    static let configuredGroup = "group.com.garoth93.tessere"
    static let snapshotFileName = "widget-snapshot.json"

    /// The App Group actually available to this process, if any.
    static let groupID: String? = {
        var candidates: [String] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            candidates = ProvisioningProfile.appGroups(from: data)
        }
        if let declared = Bundle.main.object(forInfoDictionaryKey: "TSAppGroup") as? String, !declared.isEmpty {
            candidates.append(declared)
        }
        candidates.append(configuredGroup)
        var seen = Set<String>()
        let ordered = candidates.filter { seen.insert($0).inserted }
        let preferred = ProvisioningProfile.pickGroup(configured: configuredGroup, available: ordered)
        for id in [preferred].compactMap({ $0 }) + ordered {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil { return id }
        }
        return nil
    }()

    static var containerURL: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var isShared: Bool { containerURL != nil }

    static var snapshotURL: URL? { containerURL?.appendingPathComponent(snapshotFileName) }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL else { return nil }
        return try? JSONFileStore<WidgetSnapshot>(url: url).load()
    }

    /// Returns true when the file changed (so widgets need a reload).
    @discardableResult
    static func saveSnapshot(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        let store = JSONFileStore<WidgetSnapshot>(url: url)
        if var old = try? store.load() {
            old.generatedAt = snapshot.generatedAt
            if old == snapshot { return false }
        }
        try? store.save(snapshot)
        return true
    }
}

/// Processed logos (white mark on transparent, PNG), one per card.
/// Stored in the App Group when available so the widgets can read them.
enum LogoStore {
    private static let cache = NSCache<NSString, UIImage>()

    static var directory: URL {
        let base = SharedStore.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logos", isDirectory: true)
    }

    static func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    static func data(for id: UUID) -> Data? { try? Data(contentsOf: url(for: id)) }

    static func image(for id: UUID, version: Int) -> UIImage? {
        let key = "\(id.uuidString)-\(version)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let d = data(for: id), let img = UIImage(data: d, scale: 3) else { return nil }
        let template = img.withRenderingMode(.alwaysTemplate)
        cache.setObject(template, forKey: key)
        return template
    }

    static func save(_ png: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: url(for: id), options: .atomic)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes logos of cards that no longer exist.
    static func removeOrphans(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "png" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
