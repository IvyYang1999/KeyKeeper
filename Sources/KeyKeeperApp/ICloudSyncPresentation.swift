import Foundation

/// Metadata-only UI state. No transport object, account identifier or secret reaches a view.
struct ICloudSyncPresentation: Equatable {
    enum Phase: Equatable { case off, ready, syncing, paused, conflict, unavailable, migrationRequired }
    enum Issue: Equatable {
        case identityUnavailable, accountChanged, incompleteVault, storageUnavailable
        case networkUnavailable, pendingUpload, stale, unsupportedMigration, unsupportedSnapshotVersion
    }
    struct ConflictReview: Equatable, Identifiable {
        struct Row: Equatable, Identifiable {
            let id: String
            let label: String
            let localExists: Bool
            let remoteExists: Bool
            var localUpdated: String? = nil
            var remoteUpdated: String? = nil
            var canChooseLocal = true
            var canChooseRemote = true

            func allows(_ choice: ICloudSyncChoice) -> Bool {
                choice == .local ? canChooseLocal : canChooseRemote
            }
        }
        let id: UUID
        let rows: [Row]
    }

    var phase: Phase = .off
    var enabled = false
    var lastSuccess: Date? = nil
    var issue: Issue? = nil
    var review: ConflictReview? = nil
    var missingCredentialCount: Int? = nil
    var missingFieldCount: Int? = nil
    /// When KeyKeeper will try again by itself; nil when nothing is scheduled.
    var nextRetry: Date? = nil

    /// 【曾经的 bug】2026-11-08 yyt：「每次都要我手动在这台电脑上点击重试，然后再在另一台电脑上重试」。
    /// Every failure used to pause until someone clicked. These are the pauses an automatic retry
    /// can clear by doing exactly what the Retry button does: reload, re-check the iCloud account
    /// ID against the bound one, then run a normal cycle. A different account still fails that check
    /// and stays paused; an unconfirmed upload is only re-checked (read-only), never sent again.
    ///
    /// Not enabled and storage unavailable is a launch that could not read whether sync is on.
    /// Retrying that only re-reads this Mac's record and goes on from what it says: an unreadable
    /// record is never taken as an opt-in. A turn-off that could not be saved looks the same; the
    /// runtime never retries that one by itself, because the person asked it to stop.
    var retriesAutomatically: Bool {
        guard phase == .paused, let issue else { return false }
        guard enabled else { return issue == .storageUnavailable }
        switch issue {
        case .accountChanged, .networkUnavailable, .storageUnavailable, .incompleteVault, .pendingUpload, .stale:
            return true
        case .identityUnavailable, .unsupportedMigration, .unsupportedSnapshotVersion:
            return false
        }
    }
}

enum ICloudSyncChoice: String, Equatable { case local, remote }

enum ICloudSyncAction: Equatable {
    case enable, disable, syncNow, retry, retryPendingUpload, migrate
    case resolve(reviewID: UUID, choices: [String: ICloudSyncChoice])
}

/// Selections belong to exactly one review, not whichever cloud version arrived last.
struct ICloudSyncReviewSelection: Equatable {
    private(set) var reviewID: UUID
    private(set) var choices: [String: ICloudSyncChoice] = [:]

    init(reviewID: UUID) { self.reviewID = reviewID }

    mutating func select(_ choice: ICloudSyncChoice, for id: String,
                         review: ICloudSyncPresentation.ConflictReview) {
        guard reviewID == review.id, let row = review.rows.first(where: { $0.id == id }),
              row.allows(choice) else { return }
        choices[id] = choice
    }

    mutating func updateReview(_ id: UUID) {
        guard id != reviewID else { return }
        reviewID = id
        choices = [:]
    }

    func action(for review: ICloudSyncPresentation.ConflictReview, currentReviewID: UUID?) -> ICloudSyncAction? {
        let ids = Set(review.rows.map(\.id))
        guard reviewID == review.id, currentReviewID == review.id,
              !ids.isEmpty, ids.count == review.rows.count, Set(choices.keys) == ids,
              review.rows.allSatisfy({ row in choices[row.id].map { row.allows($0) } == true }) else { return nil }
        return .resolve(reviewID: review.id, choices: choices)
    }
}
