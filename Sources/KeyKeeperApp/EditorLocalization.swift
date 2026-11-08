import Foundation

/// Key editor copy (2026-11-08 redesign: one name per key, saved values shown masked).
extension AppL10n {
    static let editorChinese: [String: String] = [
        // Rows
        "plain text": "明文",
        "The name scripts and agents use, and the environment variable it becomes.": "脚本和 Agent 用的名字，以及它变成的环境变量。",
        "Service-account JSON (contents hidden)": "服务账号 JSON（内容隐藏）",
        "Paste the new value": "粘贴新值",
        "Keep the saved value": "保留已存的值",
        "No value stored. Paste it here.": "没有存值，在这里粘贴补上。",
        "Saved": "已保存",
        "Click to replace this value": "点击替换这个值",
        "Change field name\u{2026}": "修改字段名…",
        "Store as plain text\u{2026}": "改为明文保存…",
        "Store as a secret": "改为秘密保存",
        "More": "更多",
        "Field name": "字段名",
        "Scripts use this name.": "脚本用这个名字。",
        "Scripts use this name; the old one keeps working.": "脚本用这个名字；旧名字照样能用。",
        "Done": "完成",
        // Checks before saving
        "Give this key a name.": "给这个密钥起个名字。",
        "Same name as \u{201C}{0}\u{201D} above. Use another name.": "和上面的「{0}」重名，换个名字。",
        "Some keys need a fix before saving; see the marked rows.": "有密钥需要先改一下才能保存，见标红的那几行。",
        // Editor frame
        "Editing": "正在编辑",
        "Advanced: group ID and who may use these keys": "高级：组 ID 和谁可以使用这些密钥",
    ]
}
