import XCTest
@testable import KeyKeeperApp

final class MaskedValueFieldTests: XCTestCase {
    /// 【曾经的 bug】值非空且未点眼睛时，输入框被换成遮罩文本，手动逐字输入在第一个字符后失焦。
    func test曾经的Bug输入中保持输入框不被遮罩替换() {
        // 空值、聚焦、未揭示：显示输入框
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: false, valueIsEmpty: true, isFocused: true
        ))
        // 打了第一个字符后：值非空、仍聚焦、未揭示 —— 必须继续显示输入框
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: false, valueIsEmpty: false, isFocused: true
        ))
    }

    func test未揭示的非空值失焦后显示遮罩标签() {
        XCTAssertFalse(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: false, valueIsEmpty: false, isFocused: false
        ))
    }

    /// 【曾经的 bug】点眼睛揭示时，SecureField 卸载触发的失焦回调把 visible 拍回 false，值从未明文显示。
    /// 揭示与否只由 revealed 决定，焦点变化不再参与遮罩。
    func test曾经的Bug揭示状态不受焦点变化影响() {
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: true, valueIsEmpty: false, isFocused: false
        ))
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: true, valueIsEmpty: false, isFocused: true
        ))
    }

    func test点眼睛揭示后即使失焦也显示输入框() {
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: true, valueIsEmpty: false, isFocused: false
        ))
    }

    func test空值始终显示输入框以便粘贴() {
        XCTAssertTrue(MaskedFieldPresentation.showsTextField(
            editable: true, revealed: false, valueIsEmpty: true, isFocused: false
        ))
    }

    func test不可编辑时永不显示输入框() {
        XCTAssertFalse(MaskedFieldPresentation.showsTextField(
            editable: false, revealed: true, valueIsEmpty: true, isFocused: true
        ))
    }

    func test遮罩保留首尾两位() {
        XCTAssertEqual(MaskedFieldPresentation.mask("sk_live_abc123def456"), "sk***56")
        XCTAssertEqual(MaskedFieldPresentation.mask("abcd"), "***")
        XCTAssertEqual(MaskedFieldPresentation.mask(""), "***")
    }
}
