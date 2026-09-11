// Chinese copy for the 2026-09 UI (trust prompt, main window, menu bar "now" view).
// Kept apart from ChineseTranslations.swift so parallel work on the older catalog does not
// collide; `AppL10n.render` consults the main catalog first, then this one.
extension AppL10n {
    static let chineseSupplement: [String: String] = [
        // Trust prompt
        "New, Ask every time": "新建，每次询问",
        "Fills in the missing value": "补回缺失的值",
        "Save a key found in source code?": "保存源码里的候选 key？",
        "Source": "来源",
        "Only this variable's text is read; the code is never run. {0} never sees the value.": "只读取这个变量的文本，不执行代码。{0} 看不到值。",
        "Save a service-account file?": "保存服务账号文件？",
        "{0} never sees the file. The original stays where it is, and nothing is overwritten.": "{0} 看不到文件内容。原文件保留，不会覆盖已有的 key。",
        "Save the value pasted in your browser?": "保存浏览器里粘贴的内容？",
        "Browser paste page on this Mac": "本机浏览器粘贴页",
        "{0} never sees the value, and nothing is overwritten.": "{0} 看不到内容，不会覆盖已有的 key。",
        "Save what you just copied?": "保存你刚复制的内容？",
        "Clipboard": "剪贴板",
        "{0} never sees the value. Nothing is overwritten, and the clipboard is cleared after saving.": "{0} 看不到内容。不会覆盖已有的 key，保存后剪贴板会清空。",
        "{0} wants to put it in KeyKeeper": "{0} 请求把它存进 KeyKeeper",
        "Save as": "存为",
        "Requested by": "请求方",
        "Requested by: {0}": "请求方：{0}",
        "Open": "打开",
        "Delete": "删除",
        "Website": "网站",
        "Snapshot": "快照",
        "{0} · {1} Cookies": "{0} · {1} 个 Cookie",
        "Only this snapshot is deleted. Chrome and the website account are unchanged.": "只删除这份快照，Chrome 和网站账号不受影响。",
        "This window can act on the account, not just view it.": "打开后可以操作这个账号，不只是查看。",
        "Details": "详细说明",
        "Cancels in {0} s": "{0} 秒后自动取消",
    ]
}
