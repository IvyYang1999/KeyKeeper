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
