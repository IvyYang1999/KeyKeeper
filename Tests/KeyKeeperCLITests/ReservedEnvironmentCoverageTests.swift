import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

/// 【独立审计 2026-09-13】「会改变程序怎么运行的变量名」只在 metadata 改名那一条路上拦了。
/// 真正把名字变成环境变量的是 `keykeeper run`，通往它的路还有：--file 指定的变量名、--prefix
/// 拼出来的名字、字段的旧名。检查应该放在注入的地方，而不是某一个入口。
final class ReservedEnvironmentCoverageTests: XCTestCase {
    private func credential(_ fields: [String: CredentialField]) -> Credential {
        Credential(label: "Svc", notes: "", links: [], fields: fields,
                   security: .standard, created: "2026-01-01", updated: "2026-01-01")
    }

    private func meta(_ fields: [String: CredentialField]) -> MetaFile {
        MetaFile(credentials: ["svc": credential(fields)])
    }

    func test文件字段不能注入到执行控制变量() {
        let m = meta(["sa": CredentialField(secret: true, fileFormat: .serviceAccountJSON)])
        for name in ["NODE_OPTIONS", "GIT_SSH_COMMAND", "PYTHONPATH", "BASH_ENV"] {
            XCTAssertThrowsError(try FileInjectionPlan(credentials: ["svc"], mappings: ["svc:sa=\(name)"], prefix: "", meta: m), name)
        }
    }

    func test前缀拼出来的名字也拦() {
        let m = meta(["insert-libraries": CredentialField(secret: true)])
        XCTAssertThrowsError(try FileInjectionPlan(credentials: ["svc"], mappings: [], prefix: "DYLD_", meta: m))
    }

    func test密钥字段的旧名也拦() {
        let m = meta(["token": CredentialField(secret: true, aliases: ["ld-preload"])])
        XCTAssertThrowsError(try FileInjectionPlan(credentials: ["svc"], mappings: [], prefix: "", meta: m))
    }

    func test明文字段的前缀和旧名也拦() {
        var injected: [String: String] = [:], aliases: [String: String] = [:]
        let prefixed = credential(["insert-libraries": CredentialField(value: "/tmp/x.dylib", secret: false)])
        XCTAssertThrowsError(try RunCommand.mergePlainFields(of: prefixed, prefix: "DYLD_", into: &injected, aliases: &aliases))
        injected = [:]; aliases = [:]
        let aliased = credential(["region": CredentialField(value: "/tmp/evil", secret: false, aliases: ["path"])])
        XCTAssertThrowsError(try RunCommand.mergePlainFields(of: aliased, prefix: "", into: &injected, aliases: &aliases))
        XCTAssertNil(aliases["PATH"])
    }

    /// USER、LOGNAME 只是名字，不控制执行。本机已有凭据里就有叫 user 的字段——检查一旦放到注入处，
    /// 拦着它，那条凭据就再也 run 不了。
    func testUSER和LOGNAME不算保留名() {
        XCTAssertFalse(EnvironmentVariableName.isReserved(fieldName: "user"))
        XCTAssertFalse(EnvironmentVariableName.isReserved(fieldName: "logname"))
        XCTAssertTrue(EnvironmentVariableName.isReserved(fieldName: "home"))
    }
}
