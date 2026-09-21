import XCTest
import SwiftUI
@testable import PhotoRelay

final class SyncPresentationTests: XCTestCase {
    @MainActor
    func testRecoveryReviewFitsAndIdentifiesUnresolvedPhoto() throws {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let review = try JSONDecoder().decode(SyncReview.self, from: Data("""
        {"token":"preview","file_count":584,"total_bytes":1330000000,"unresolved_files":["IMG_5009.HEIC"],"destinations":[
          {"id":"new:Trip","title":"Desk Travels","is_new":true,"existing_count":0,"managed_count":0,"selected_count":584}
        ]}
        """.utf8))
        XCTAssertEqual(review.unresolvedFiles, ["IMG_5009.HEIC"])
        let view = NSHostingView(rootView: SyncReviewSheet(review: review, isFrame: true, cancel: {}, confirm: { _, _ in })
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 628, height: 660)
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.height, 660)
        if let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("sync-recovery.png"))
        }
    }

    @MainActor
    func testReviewRendersWithoutTruncatingTheActionArea() throws {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let review = try JSONDecoder().decode(SyncReview.self, from: Data("""
        {"token":"preview","file_count":48,"total_bytes":384000000,"destinations":[
          {"id":"frame","title":"Desk Travels","is_new":false,"existing_count":120,"managed_count":120,"selected_count":48}
        ]}
        """.utf8))
        let view = NSHostingView(rootView: SyncReviewSheet(review: review, isFrame: true, cancel: {}, confirm: { _, _ in })
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 628, height: 560)
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.height, 560)
        if let directory = ProcessInfo.processInfo.environment["PHOTO_RELAY_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sync-review.png"))
        }
    }

    func testReviewOnlyOffersReplacementForManagedPhotos() throws {
        let data = Data("""
        {"token":"review","file_count":4,"total_bytes":1234,"destinations":[
          {"id":"album","title":"Desk Travels","is_new":false,"existing_count":12,"managed_count":0,"selected_count":4}
        ]}
        """.utf8)
        let review = try JSONDecoder().decode(SyncReview.self, from: data)
        XCTAssertFalse(review.canReplace)
        XCTAssertEqual(review.destinations.first?.existingCount, 12)
    }

    func testSendingProgressDecodesServerContract() throws {
        let data = Data("""
        {"run_id":"review","phase":"uploading","message":"Sending photos","completed":3,"total":10,
         "reused":2,"sent_bytes":4000000,"total_bytes":10000000,"bytes_per_second":500000,"eta_seconds":12}
        """.utf8)
        let progress = try JSONDecoder().decode(TransferProgress.self, from: data)
        XCTAssertTrue(progress.isTransferring)
        XCTAssertEqual(progress.runID, "review")
        XCTAssertEqual(progress.reused, 2)
        XCTAssertTrue(progress.transferSummary.contains("1 min left to send"))
        XCTAssertTrue(progress.transferSummary.contains("Avg."))
    }

    func testProcessingDoesNotPromiseACompletionTime() throws {
        let data = Data("""
        {"phase":"processing","message":"Waiting for Google","eta_seconds":null}
        """.utf8)
        let progress = try JSONDecoder().decode(TransferProgress.self, from: data)
        XCTAssertTrue(progress.transferSummary.contains("Google is processing"))
        XCTAssertFalse(progress.transferSummary.contains("min left"))
    }

    func testAlbumPickerPreservesDuplicateTitlesWithSeparateIDs() throws {
        let data = Data("""
        [{"id":"one","title":"Travel","mediaItemsCount":"12"},{"id":"two","title":"Travel"}]
        """.utf8)
        let albums = try JSONDecoder().decode([GoogleAlbum].self, from: data)
        XCTAssertNotEqual(albums[0].id, albums[1].id)
        XCTAssertEqual(albums[0].count, 12)
        XCTAssertEqual(albums[1].count, 0)
    }
}
