import Foundation

enum AuthorizationMetadataError: Error, LocalizedError {
    case changed
    var errorDescription: String? {
        L("This credential changed while approval was waiting. Cancel this request and ask the caller to try again.")
    }
}
