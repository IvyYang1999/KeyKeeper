import Foundation

/// Applies a `MetadataEdit`: names and notes only, never values or security. Used by the App
/// for edits from agents (`keykeeper edit`) and people. No confirmation step by design —
/// yyt: "the fewer prompts the better, just tell the person what changed".
///
/// A rename is three commits in an order that survives a failure at any point:
/// 1. copy values to their new names, keeping the originals;
/// 2. write metadata (now only the new names are referenced);
/// 3. move approvals, then drop the original values.
/// If step 2 fails, metadata still names the originals, which still have their values.
public struct MetadataEditor {
    let session: any CredentialSessionManaging
    let metaStore: any MetaStoring
    let grantStore: GrantStore
    let serviceGrantStore: ServiceGrantStore

    public init(session: any CredentialSessionManaging, metaStore: any MetaStoring,
                grantStore: GrantStore, serviceGrantStore: ServiceGrantStore) {
        self.session = session
        self.metaStore = metaStore
        self.grantStore = grantStore
        self.serviceGrantStore = serviceGrantStore
    }

    public func apply(_ edit: MetadataEdit, groupId: String) throws -> MetadataEditResult {
        let meta = try metaStore.load()
        guard meta.version == 1 else { throw ClipboardSaveError.storageUnavailable }
        let result = try MetadataEditPlan.apply(edit, to: meta, groupId: groupId)
        let oldId = result.previousGroupId
        let newId = result.groupId
        let before = meta.credentials[oldId]!
        let secretFields = before.fields.filter { $0.value.secret }.map(\.key)
        let movesValues = !secretFields.isEmpty && (oldId != newId || secretFields.contains { result.fieldMap[$0] != nil })

        if movesValues {
            try session.validateStorage()
            try session.copyValues(fromCredentialId: oldId, toCredentialId: newId, fieldMap: result.fieldMap)
        }
        try metaStore.save(result.meta)

        // Metadata is committed; what follows only tidies up and must not undo it.
        try? grantStore.moveGrants(from: oldId, to: newId)
        try? serviceGrantStore.moveGrants(from: oldId, to: newId, fieldMap: result.fieldMap)
        if movesValues {
            let stale = oldId != newId ? secretFields : secretFields.filter { result.fieldMap[$0] != nil }
            try? session.dropValues(credentialId: oldId, fieldNames: stale)
        }
        return result
    }
}
