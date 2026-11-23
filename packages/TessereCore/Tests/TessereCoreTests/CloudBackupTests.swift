import XCTest
@testable import TessereCore

final class CloudBackupTests: XCTestCase {
    let now = Synthetic.now

    func testNamesAndEntries() {
        let d1 = CloudBackupPlan.dailyName(for: now)
        let d0 = CloudBackupPlan.dailyName(for: now.addingTimeInterval(-86_400))
        XCTAssertTrue(d1.hasPrefix("Tessere-backup-20"))
        XCTAssertTrue(d1.hasSuffix(".json"))
        let names = [d0, "." + d1 + ".icloud", CloudBackupPlan.latestName, "altro.txt", "Tessere-backup-xx.json"]
        let e = CloudBackupPlan.entries(fromFileNames: names)
        XCTAssertEqual(e.map(\.name), [CloudBackupPlan.latestName, d1, d0])
        XCTAssertTrue(e[0].isLatest)
        XCTAssertEqual(CloudBackupPlan.realName(".a.json.icloud"), "a.json")
        XCTAssertEqual(CloudBackupPlan.realName("a.json"), "a.json")
    }

    func testPrune() {
        let names = (0..<35).map { CloudBackupPlan.dailyName(for: now.addingTimeInterval(Double(-$0) * 86_400)) } + [CloudBackupPlan.latestName]
        let prune = CloudBackupPlan.namesToPrune(names)
        XCTAssertEqual(prune.count, 5)
        XCTAssertFalse(prune.contains(CloudBackupPlan.latestName))
        XCTAssertTrue(prune.contains(CloudBackupPlan.dailyName(for: now.addingTimeInterval(-34 * 86_400))))
        XCTAssertTrue(CloudBackupPlan.namesToPrune(Array(names.prefix(3))).isEmpty)
    }

    func testFingerprintIgnoresDate() {
        var d = TessereData()
        d.upsert(Synthetic.card("Alfa TEST"), now: now)
        let a = BackupFile(data: d, logos: [:], now: now)
        let b = BackupFile(data: d, logos: [:], now: now.addingTimeInterval(500))
        XCTAssertEqual(CloudBackupPlan.fingerprint(a), CloudBackupPlan.fingerprint(b))
        d.edit(d.cards[0].id, now: now) { $0.note = "nuova" }
        XCTAssertNotEqual(CloudBackupPlan.fingerprint(a), CloudBackupPlan.fingerprint(BackupFile(data: d, logos: [:], now: now)))
        XCTAssertNotEqual(CloudBackupPlan.fingerprint(a), CloudBackupPlan.fingerprint(BackupFile(data: TessereData(), logos: [:], now: now)))
    }
}
