import Foundation
import XCTest
@testable import PhotoRelay

final class DiagnosticBundleExporterTests: XCTestCase {
    func testFreshInstallDisablesAutomaticPublicationAndPreservesExplicitChoice() {
        let name = "PhotoCuratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertFalse(CuratorPolicy.automaticPublicationEnabled(defaults: defaults))
        defaults.set(true, forKey: "curatorAutoPublish")
        XCTAssertTrue(CuratorPolicy.automaticPublicationEnabled(defaults: defaults))
        defaults.set(false, forKey: "curatorAutoPublish")
        XCTAssertFalse(CuratorPolicy.automaticPublicationEnabled(defaults: defaults))
    }

    func testDiagnosticExportContainsOnlySanitizedAggregates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("support")
        let logs = root.appendingPathComponent("logs")
        let destination = root.appendingPathComponent("diagnostics.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 12).write(to: support.appendingPathComponent("SECRET-PHOTO-TITLE.jpg"))
        let telemetry = """
        {"time":"2026-09-21T08:00:00Z","session":"PRIVATE-SESSION","title":"SECRET-TITLE","event":"catalog","counts":{"indexed":108999,"unknown":4}}
        {"time":"2026-09-21T08:01:00Z","session":"PRIVATE-SESSION","event":"notAllowed","counts":{"indexed":1}}
        """
        try telemetry.write(to: logs.appendingPathComponent("curator.jsonl"), atomically: true, encoding: .utf8)

        let context = DiagnosticExportContext(
            indexedPhotos: 108_999,
            availableMoments: 5_224,
            visibleMoments: 200,
            analyzedThisSession: 12,
            deferredThisSession: 1,
            backgroundCurationEnabled: true,
            automaticPublicationEnabled: false
        )
        try DiagnosticBundleExporter.export(
            context: context,
            to: destination,
            supportDirectory: support,
            logsDirectory: logs
        )

        let data = try Data(contentsOf: destination)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("SECRET-PHOTO-TITLE"))
        XCTAssertFalse(text.contains("PRIVATE-SESSION"))
        XCTAssertFalse(text.contains("SECRET-TITLE"))
        XCTAssertFalse(text.contains("notAllowed"))
        XCTAssertFalse(text.contains("unknown"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(DiagnosticBundle.self, from: data)
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.context, context)
        XCTAssertEqual(bundle.applicationSupport, DiagnosticStorageSummary(regularFiles: 1, bytes: 12))
        XCTAssertEqual(bundle.telemetry.count, 1)
        XCTAssertEqual(bundle.telemetry[0].counts, ["indexed": 108_999])
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
