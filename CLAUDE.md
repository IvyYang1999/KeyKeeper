# 技术栈

Swift 6 + SwiftUI + macOS Keychain，构建工具 Swift Package Manager。
macOS 菜单栏应用 + CLI + Python/Node SDK。

# Git 规则（强制）

每完成一个独立改动，立即 `git add` 相关文件 + `git commit`（中文 message）。
commit 后 git hook 自动：push → 编译 → 替换 /Applications/KeyKeeper.app → 重启。
pre-commit hook 自动跑 `swift test` + 编译检查，不过就拒绝 commit。
绝对不允许：多个不相关功能塞同一个 commit / 编译不过就 commit / 测试不过就 commit。
改动前先 `git status` 确认工作区干净。

# 开发规则

- 日常调试：`swift build` 编译，`swift run keykeeper` 跑 CLI
- 编译验证：`swift build -c release`
- GUI 调试：Xcode 打开 Package.swift 或 `open Package.swift`

# 测试规则（强制，不可跳过）

**修 bug 时，必须先写测试再改代码。** 没有测试的 bug fix 不允许 commit。

- `swift test`：单元测试，<1 秒，commit 前必跑（pre-commit hook 已自动执行）
- 测试文件放在 `Tests/KeyKeeperCoreTests/` 目录，命名 `XxxTests.swift`
- 测试框架：XCTest

何时写测试：修 bug（强制）→ 改了已有函数行为（强制）→ 新逻辑 → 纯 UI 不需要。
测试名用中文注释说明意图，防回归加 `【曾经的 bug】` 前缀。

# 项目结构

```
Sources/
├── KeyKeeperCore/    # 核心逻辑（Models, Keychain, MetaStore, Grant）
├── KeyKeeperCLI/     # 命令行工具
└── KeyKeeperApp/     # macOS 菜单栏 GUI（SwiftUI）
Tests/
└── KeyKeeperCoreTests/  # 单元测试
```

# Agent 犯过的错（每次犯新错就追加）

