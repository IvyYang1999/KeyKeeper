import Foundation

/// First-run admission, welcome guide and CLI status copy (2026-11-05).
extension AppL10n {
    static let onboardingChinese: [String: String] = [
        // Startup admission
        "Checking this Mac…": "正在检查这台 Mac…",
        "Preparing this Mac…": "正在准备这台 Mac…",
        "First, set up this Mac": "先准备这台 Mac",
        "KeyKeeper keeps your keys in protected storage on this Mac. Nothing is uploaded.": "KeyKeeper 会把你的 key 保存在这台 Mac 的本地安全存储里，不会上传任何内容。",
        "iCloud sync stays off. You can turn it on later in Settings.": "iCloud 同步保持关闭，之后可以在设置里开启。",
        "Copy data from the earlier KeyKeeper": "复制旧版 KeyKeeper 的数据",
        "Found {0} keys saved by an earlier version on this Mac. They will be copied into the new protected storage; the originals stay where they are.": "在这台 Mac 上找到旧版保存的 {0} 把 key。它们会被复制到新的安全存储，原来的数据留在原处，不会删除。",
        "Found settings and history from an earlier version, but no saved keys. They will be copied into the new protected storage; the originals stay where they are.": "找到旧版的设置和记录，但没有已保存的 key。它们会被复制到新的安全存储，原来的数据留在原处。",
        "{0} values were already missing before the copy. They stay marked as missing; copying cannot recover them.": "其中 {0} 个值在复制前就已缺失，复制后仍标记为缺失；复制无法找回它们。",
        "{0} website sign-ins are copied too.": "{0} 个网站登录状态也会一起复制。",
        "Approvals are not copied. Each agent asks you again the first time it uses a key.": "使用权限不会复制：每个 Agent 第一次使用 key 时，会重新请你批准。",
        "Set Up": "开始准备",
        "Copy and Continue": "复制并继续",
        "Try Again": "重试",
        "Could not read the earlier KeyKeeper’s data": "没能读取旧版 KeyKeeper 的数据",
        "This Mac’s data can’t be copied automatically yet": "这台 Mac 上的数据暂时无法自动复制",
        "This Mac could not be set up": "这台 Mac 暂时没能准备好",
        "Nothing was changed, and no empty store was created in its place.": "没有做任何改动，也没有用空的存储代替它。",
        "The originals are unchanged.": "原来的数据保持不变。",
        "Existing data was kept. If setup was interrupted, trying again continues from where it stopped.": "已有数据已保留。如果准备过程被中断，重试会从上次停下的地方继续。",

    ]
}
