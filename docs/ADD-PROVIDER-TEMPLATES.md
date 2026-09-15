# 新增凭据的供应商模板

## 冻结验收边界（2026-09-15）

- 必须：新增入口复用供应商搜索/分类/官方图标；手动填写仍可用；选择仅改草稿，保存完整字段类型、别名和 provider 绑定；必填项和官方已声明格式在任何写入前检查。
- 必须：切换不能悄悄丢弃已填值/文件；文件选择仅记录路径与打开的文件身份，Save 才读取并验证；所有文件验证通过后才一次写入新凭据，不覆盖已有凭据或权限。
- 明确不做：改供应商目录合同、重设计整体 UI、自动联网验证、导出系统签名身份、自动安装插件、修改 CLI/IPC 或公开发版。
- 用户门禁：真实 App 安装/重启前确认未保存表单；本轮不读取真实凭据。
- 可阻断：秘密泄漏、数据损失/错误写入、无法启动、现有回归及上述显式验收失败。其余记为后续能力。
- 机械收口：定向测试 → 真实隔离 App 视觉/保存接线 → 冻结全量门禁与隔离 E2E → 提交 → 获准后安装并重启/核验。

## 覆盖映射

| 当前必达 | 合同 / 实现 | 验证 |
| --- | --- | --- |
| 选择模板和手动模式 | AddProviderTemplateSection / 既有 ProviderPickerView | 原有搜索测试 + 真实 UI |
| 草稿保护 | selectProvider(discardValues:) | AddCredentialProviderTests |
| 正确字段类型、别名、绑定 | ProviderTemplate → AddCredentialViewModel.save | 全目录类型检查、落盘元数据测试 |
| 必填及形状检查先于写入 | providerProblem | 缺字段、类型篡改、官方形状拒绝反例 |
| 凭据文件 | CredentialFileSource，沿用文件身份和格式检查 | 合成 JSON、替换/格式错误拒绝，真实 UI |
| 本地签名身份不导入 | localIdentity 仅显示说明和管理入口，禁止保存 | 不产生空壳测试 |

## 已知边界

- Developer ID Application/Installer 属于系统签名身份，本页只提供管理入口；不把证书私钥存为 API key。
- 无法由本地格式判断账号、地区、套餐或实际权限。模板名称区分合同，但实际可用性需要另外授权的供应商验证。
- 模板文案与字段 label 沿用目录；中文界面通用交互已本地化，供应商提供的说明部分仍是英文。
- 文件读后只保存在函数局部并写进 Keychain；UI/元数据不保留文件内容，原件不删除。保存成功后不自动授予调用者权限。

## 验收结果

- `AddCredentialProviderTests`：11 项通过，包括 113 个模板的字段类型映射、别名、必填项、草稿取消、错误形状/类型、文件替换/错误格式、合成 P-256 `.p8` 整包保存、可选空字段和中文占位符。
- `bash scripts/pre-commit`：全量 Swift 812 项，11 个原有 opt-in 跳过，0 失败；Python 插件测试和构建通过。
- `bash scripts/e2e-isolated.sh --build`：签名 App 的 46 项隔离 E2E 全过；测试钥匙串退出后清理。
- 真实隔离 App Computer Use：新增选择器可搜索，Apple 公证模板显示三个正确类型的字段；填入合成数据，更换模板弹出确认，取消后所有输入保留；保存成功后 CLI metadata 可见 provider、3 个字段、injectOnly=true、valueStatus=present，无新授权。Firebase JSON 从原生文件选择器选取→Save→详情和 CLI 验证 fileFormat 仍为 serviceAccountJSON、内容未进 metadata、原件存在。
- 视觉：沿用 Claude 的布局，实际检查了窄窗口、长名称、展开提示/更多选项、纵向滚动及底部 Save；没有保存含真实隐私的截图。独立菜单栏小窗口尚未单独视觉复核，不把主窗口验收冒充这一项。
- 有界回看结论：ACCEPTED，无当前验收 blocker。安装/重启仍需用户确认；本机交付不等于公开发布。
- 过程：先红测（新 API 缺失），再定向通过，随后真实 UI，最终全量门禁；1 个实现批次，无 verifier REJECT 循环。阶段未独立计时，故不填虚假的 planning / implementation / verification 精确用时；等待项只剩安装重启许可。
