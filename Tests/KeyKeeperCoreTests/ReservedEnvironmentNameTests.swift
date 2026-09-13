import XCTest
@testable import KeyKeeperCore

/// 【安全审计 2026-09-13】`keykeeper run` 注入的变量名是从字段名推出来的，而改字段名和
/// 写明文字段（`keykeeper edit --rename-field` / `--set`）都**不弹窗**。于是一个本地进程
/// 可以把某个字段改名成 `path`，或者塞一个明文字段叫 `dyld-insert-libraries`，
/// 下一次 `keykeeper run` 就会用它覆盖掉子进程继承来的同名变量——那不是泄密，是执行。
final class ReservedEnvironmentNameTests: XCTestCase {
    func test会改变程序如何被执行的变量名一律拒绝() {
        for dangerous in ["path", "PATH", "dyld-insert-libraries", "DYLD_LIBRARY_PATH",
                         "ld_preload", "git-ssh-command", "bash-env", "shell", "ifs",
                         "pythonpath", "pythonstartup", "node-options", "perl5opt",
                         "editor", "visual", "pager"] {
            XCTAssertTrue(EnvironmentVariableName.isReserved(fieldName: dangerous),
                          "\(dangerous) 会改变子进程执行什么，不能由字段名决定")
        }
    }

    func test正常的密钥字段名照旧() {
        for fine in ["api-key", "token", "apple-id", "database-url", "openai_api_key",
                     "secret", "password", "admin-token", "pathology-api-key"] {
            XCTAssertFalse(EnvironmentVariableName.isReserved(fieldName: fine), fine)
        }
    }

    /// 加前缀之后仍然危险的，也要拦——`--prefix DYLD_` + 字段 `insert-libraries`。
    func test带前缀拼出来的危险名字也拦() {
        XCTAssertTrue(EnvironmentVariableName.isReserved(fieldName: "insert-libraries", prefix: "DYLD_"))
        XCTAssertFalse(EnvironmentVariableName.isReserved(fieldName: "insert-libraries", prefix: "MYAPP_"))
    }
}

extension ReservedEnvironmentNameTests {
    /// 不弹窗的元数据编辑是这条路的入口：改名和写明文字段都要拦。
    func test元数据编辑拒绝保留名() throws {
        let meta = MetaFile(credentials: [
            "demo": Credential(label: "Demo", notes: "", links: [],
                               fields: ["token": CredentialField(secret: true)],
                               security: .standard, created: "2026-09-13", updated: "2026-09-13")
        ])
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(fieldRenames: ["token": "path"]), to: meta, groupId: "demo")) {
            XCTAssertEqual($0 as? MetadataEditError, .reservedFieldName("path"))
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["dyld-insert-libraries": "/tmp/evil.dylib"]), to: meta, groupId: "demo")) {
            XCTAssertEqual($0 as? MetadataEditError, .reservedFieldName("dyld-insert-libraries"))
        }
        // 正常改名不受影响
        XCTAssertNoThrow(try MetadataEditPlan.apply(
            MetadataEdit(fieldRenames: ["token": "api-key"]), to: meta, groupId: "demo"))
    }
}
