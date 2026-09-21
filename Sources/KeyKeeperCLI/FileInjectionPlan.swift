import KeyKeeperCore

/// Kept as a narrow adapter for older internal callers and tests. All validation and naming live
/// in `RunInjectionPlan`, so file execution and `run --plan` cannot drift apart.
struct FileInjectionPlan {
    private let plan: RunInjectionPlan
    var hasFiles: Bool { plan.hasFiles }

    init(credentials: [String], mappings: [String], prefix: String, meta: MetaFile) throws {
        plan = try RunInjectionPlan(
            credentials: credentials,
            environmentMappings: [],
            fileMappings: mappings,
            prefix: prefix,
            meta: meta
        )
    }

    func environmentName(credential: String, field: String) -> String? {
        guard plan.binding(credential: credential, field: field)?.kind == .secretFile else { return nil }
        return plan.binding(credential: credential, field: field)?.environmentName
    }
}
