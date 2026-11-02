import XCTest
@testable import KeyKeeperApp

final class ICloudSyncPresentationTests: XCTestCase {
    func testDefaultIsOffAndContainsNoReview() {
        let state = ICloudSyncPresentation()
        XCTAssertEqual(state.phase, .off)
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.review)
    }

    func testOnlyCompleteCurrentReviewCanApplyAndChangedReviewClearsChoices() {
        let review = ICloudSyncPresentation.ConflictReview(id: UUID(), rows: [
            .init(id: "synthetic", label: "Synthetic", localExists: true, remoteExists: false)
        ])
        var selection = ICloudSyncReviewSelection(reviewID: review.id)
        XCTAssertNil(selection.action(for: review, currentReviewID: review.id))
        selection.select(.remote, for: "unknown", review: review)
        XCTAssertTrue(selection.choices.isEmpty)
        selection.select(.local, for: "synthetic", review: review)
        XCTAssertEqual(selection.action(for: review, currentReviewID: review.id),
                       .resolve(reviewID: review.id, choices: ["synthetic": .local]))
        XCTAssertNil(selection.action(for: review, currentReviewID: UUID()))
        selection.updateReview(UUID())
        XCTAssertTrue(selection.choices.isEmpty)
        XCTAssertNil(selection.action(for: review, currentReviewID: review.id))
    }
    func testDuplicateOrEmptyReviewsCannotSubmit() {
        let row = ICloudSyncPresentation.ConflictReview.Row(id: "synthetic", label: "Synthetic",
            localExists: true, remoteExists: true)
        for rows in [[], [row, row]] {
            let review = ICloudSyncPresentation.ConflictReview(id: UUID(), rows: rows)
            var selection = ICloudSyncReviewSelection(reviewID: review.id)
            selection.select(.local, for: row.id, review: review)
            XCTAssertNil(selection.action(for: review, currentReviewID: review.id))
        }
    }

    func testSyncCopyHasChineseAndMatchingPlaceholders() {
        for (english, chinese) in AppL10n.iCloudSyncChinese {
            XCTAssertNotEqual(english, chinese)
            XCTAssertEqual(AppL10n.placeholders(in: english), AppL10n.placeholders(in: chinese), english)
            XCTAssertEqual(AppL10n.render(english, language: "zh-Hans"), chinese)
        }
    }

}
