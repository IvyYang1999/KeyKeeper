# Routing provider credential research — 2026-09-15

基线：`563896a6d0fe`。只核对公开的一方页面，不接触真实凭据。`verified` 表示发行方、创建入口、凭据变量和路由足以进入模板；`pending` 表示任一关键身份链或安全语义仍缺一方明文。示例 key 不作为前缀、长度或正则合同。

## 决策矩阵

| 建议 ID | 状态 | 创建入口与身份 | 凭据 / env | 固定路由 | 不可互换与最小权限 | 生命周期与只读验证 |
|---|---|---|---|---|---|---|
| `eflowcode` | **pending，不接 catalog** | 用户给出的仓库属于 `EF-FlowCode` GitHub 组织，但组织无公开成员；README 安装命令仍克隆 `WenNinghan/eflowcode-image-mcp`，贡献者又写 `zuoliangyu`。仓库、`e-flowcode.cc` 运营方与截图发行方无法形成可审计的同一身份链；createURL 未找到一方明文。 | MCP 的 GPT 路由读 `EFLOWCODE_API_KEY`，兼容 `EF_API_KEY` / `OPENAI_API_KEY`；Nano 读独立 `EFLOWCODE_NANO_API_KEY`；Grok 读 `EFLOWCODE_GROK_API_KEY` / `XAI_API_KEY`。不能把三类 key 合并成一个字段。 | GPT `https://e-flowcode.cc/v1`；Nano `https://e-flowcode.cc`；Grok 默认 `https://api.x.ai/v1`，仅在 E-FlowCode 代理时改为 `https://e-flowcode.cc/v1`。 | 仓库只证明 MCP 如何读取/发送 key，不证明谁发行 key、套餐边界或权限。 | expiry、shownOnce、格式、可依赖的只读 credential probe 均 **pending**。 |
| `opencode-zen`（alias `opencode-console`） | **verified** | 当前产品名是 **OpenCode Console**；`Zen` 仍保留在官方 endpoint 路径。入口 `https://opencode.ai/console/`。 | 官方 OpenCode 仓库使用 `OPENCODE_API_KEY`；TUI 官方首选 `/connect` 保存。 | `https://opencode.ai/zen/v1`；模型决定使用 Responses、Chat Completions、Messages 或 Gemini 路径。 | 按量 Console 与 Go 是不同计费产品。官方未说明同一 key 能否互用，因此必须分模板、默认不可互换。未公开按 key scope，建议每项目独立创建。 | expiry、shownOnce、格式未知。`GET /zen/v1/models` 可能无需认证，不能证明 key 有效；probe 保持 nil。 |
| `opencode-go` | **verified** | 同一 Console 中订阅 Go；入口 `https://opencode.ai/console/`。Go 主要面向国际用户且每 workspace 仅一名成员可订阅。 | `OPENCODE_API_KEY`。与 Console 相同变量名不代表同一 secret。 | `https://opencode.ai/zen/go/v1`；支持 Responses、Chat Completions、Messages；模型列表 `GET /zen/go/v1/models`。 | Go 是订阅用量合同；不要把按量 Console key 自动复用到 Go。未公开按 key scope。 | expiry、shownOnce、格式和 authenticated probe 状态语义未知；probe 保持 nil。 |
| `pipellm` | **verified** | 官方 Quick Start：注册 `https://console.pipellm.ai/`、充值、创建 API key。 | `PIPELLM_API_KEY`；按协议放入 Bearer、`x-api-key` 或 `x-goog-api-key`。这些 header 是同一 PipeLLM secret 的客户端适配，不是三份 secret。 | Native `https://api.pipellm.ai`；OpenAI converter `/openai/v1`；Anthropic converter `/anthropic`；Gemini converter `/gemini`。 | 官方未说明 per-key scopes；建议一项目一 key，且 base URL 固定在模板。 | `GET https://api.pipellm.ai/v1/models` 是官方只读候选，但文档未给无效 key 状态合同；当前 probe 保持 nil。expiry、shownOnce、格式未知。 |
| `relaxycode` | **verified（带文档瑕疵告警）** | 官网明确从 `https://www.relaxycode.com/dashboard/api-keys` 创建并绑定套餐或余额。 | 官方 Codex 教程把值放在 `OPENAI_API_KEY`。 | 当前只登记该教程明确的 Responses base：`https://api.relaxycode.com/v1`。不从首页“支持 Claude/GLM”反推未公开协议 base。 | 教程正文却写“替换成 DMXAPI 令牌”，与本站域名/发行方矛盾；不得因此接受 DMXAPI 或其他供应商 token，只保存 RelaxyCode 控制台实际创建的 key。 | expiry、shownOnce、格式和安全只读 probe 均未知；probe nil。 |
| `therouter`（alias `the-router`） | **verified** | 官方 Dashboard `https://dashboard.therouter.ai/`。 | canonical `THEROUTER_API_KEY`。Claude Code 官方明确把同一值映射为 `ANTHROPIC_AUTH_TOKEN`，并把 `ANTHROPIC_API_KEY` 置空；后者绝不能成为 alias。 | OpenAI-compatible `https://api.therouter.ai/v1`；Claude Code / Anthropic SDK root `https://api.therouter.ai`。 | 普通模型 key 与用于 `POST /v1/keys` 的 management key 权限不同，不应互换。创建时设置用途/额度；轮换必须先部署验证新 key，再撤销旧 key。 | 官方有 `GET /v1/models` 只读请求，但未给完整无效状态合同；当前 probe nil。expiry、shownOnce、格式未知；`sk-...` 只是示例，不硬校验。 |
| `zhipu-cn`（legacy `zhipu` 仅指向此项） | **verified** | 当前一般 API key 页：`https://bigmodel.cn/usercenter/proj-mgmt/apikeys`。 | 新官方 `zai-sdk` / 文档使用 `ZAI_API_KEY`；旧官方 `zhipuai` SDK 使用 `ZHIPUAI_API_KEY`。同一 secret 可按客户端同时注入两个 env，不应保存两份。 | `https://open.bigmodel.cn/api/paas/v4/`。 | 只代表中国一般 API，不与全球或 Coding 模板 alias。 | expiry、shownOnce、格式、稳定只读 probe 均未知。 |
| `zhipu-cn-coding` | **verified（个人）；团队 pending 独立项** | 个人创建：`https://bigmodel.cn/coding-plan/personal/overview`；团队：`https://bigmodel.cn/coding-plan?z_plan=team`。 | canonical `ZAI_API_KEY`；实际 coding tool 可映射到其协议变量。 | Anthropic `https://open.bigmodel.cn/api/anthropic`；OpenAI Chat `https://open.bigmodel.cn/api/coding/paas/v4`；Responses `https://open.bigmodel.cn/api/v1`。 | 官方只明确“**团队** Coding key 与平台其他 key 不通用”；个人 Coding key 是否与一般 API key 为不同 secret 未明文。模板可按套餐/route 拆开，但不能把团队结论写成个人事实。 | 仅用于官方支持工具。expiry、shownOnce、格式和 probe 未知。 |
| `zai-global`（legacy `zai` 仅指向此项） | **verified** | `https://z.ai/manage-apikey/apikey-list`。 | `ZAI_API_KEY`。 | `https://api.z.ai/api/paas/v4`。 | 与中国账号/endpoint 分离；官方未明说跨区域 key 可否互用，因此绝不自动跨域发送。 | expiry、shownOnce、格式、稳定只读 probe均未知。 |
| `zai-global-coding` | **verified（个人）；团队 pending 独立项** | 个人 Coding 官方链接目前也落到 `https://z.ai/manage-apikey/apikey-list`；团队为 `https://z.ai/manage-apikey/coding-plan/team/my-plan`。 | `ZAI_API_KEY`；按实际 coding tool 做协议变量映射。 | Anthropic `https://api.z.ai/api/anthropic`；OpenAI Chat `https://api.z.ai/api/coding/paas/v4`；Responses `https://api.z.ai/api/v1`。 | 仅团队 key 被官方明确为不可与其他 Z.AI API key 互换；个人不能照抄该结论。仅用于官方支持工具。 | expiry、shownOnce、格式和 probe 未知。 |

## 智谱 / Z.AI 兼容边界

1. 四个 canonical ID 应保持 `zhipu-cn`、`zhipu-cn-coding`、`zai-global`、`zai-global-coding`。旧 `zhipu`、`zhipu-coding`、`zai`、`zai-coding` 只能映射到同区域同套餐，绝不跨域。
2. `ZAI_API_KEY` 是新官方 SDK 的通用变量；仅中国一般 API 为兼容旧 SDK，将同一值额外注入 `ZHIPUAI_API_KEY`。这是一值多变量，不是两份凭据。
3. `Z_AI_API_KEY` 只在官方 `@z_ai/mcp-server` Vision MCP 文档中出现，并需配合 `Z_AI_MODE=ZHIPU` 或 `ZAI`；它不是一般 SDK/API 的变量，不能放进四个模板的全局 alias。
4. “Coding key 独立”必须分层表达：route/套餐合同明确独立；团队 secret 明确不通用；个人 secret 是否与一般 key 不通用仍 pending。

## 安全收口

- 未有一方格式合同的 provider：`prefixes=[]`、`minChars=nil`，不能把示例 `sk-...` 变成保存阻断。
- 未有一方“仅显示一次”明文：`shownOnce=false` 仅代表**未确认**，不能反向宣称以后可找回。
- 未有默认到期明文：展示“未知，以创建页实际日期为准”，不猜永久或固定天数。
- OpenAI / Anthropic 协议兼容只描述路由，不改变 secret 发行方；固定 base URL 是防止把 key 发错域名的安全边界。
- 当前五个已接 routing 模板 validation 均为 nil；即使存在 GET models，必须先冻结无效 key、权限不足、额度不足和匿名可访问的状态语义，才能成为 credential probe。

## 一方来源

- E-FlowCode：[`EF-FlowCode/eflowcode-image-mcp`](https://github.com/EF-FlowCode/eflowcode-image-mcp)、[`EF-FlowCode` 组织](https://github.com/EF-FlowCode)
- OpenCode：[`Console models`](https://opencode.ai/v2/docs/console/models/)、[`Go`](https://opencode.ai/v2/docs/console/go)、[`Providers`](https://opencode.ai/v2/docs/providers)、[官方 repo workflow 的 `OPENCODE_API_KEY`](https://github.com/anomalyco/opencode/blob/dev/.github/workflows/opencode.yml)
- PipeLLM：[`Quick Start`](https://docs.pipellm.ai/quickstart)、[`API overview`](https://docs.pipellm.ai/api-reference/introduction)、[`List Models`](https://docs.pipellm.ai/api-reference/list-models)
- RelaxyCode：[`官网 FAQ`](https://www.relaxycode.com/)、[`Codex 教程`](https://www.relaxycode.com/blog/codex-gpt)
- TheRouter：[`Quickstart`](https://therouter.ai/docs/quickstart/)、[`Claude Code`](https://therouter.ai/docs/guides/guides/claude-code-integration/)、[`API Key Rotation`](https://therouter.ai/docs/guides/guides/api-key-rotation/)
- 智谱中国：[`新 Python SDK`](https://docs.bigmodel.cn/cn/guide/develop/python/introduction)、[`Coding Plan Quick Start`](https://docs.bigmodel.cn/cn/coding-plan/quick-start)、[旧官方 Python SDK](https://github.com/MetaGLM/zhipuai-sdk-python-v4)
- Z.AI Global：[`API introduction`](https://docs.z.ai/api-reference/introduction)、[`Coding Plan Quick Start`](https://docs.z.ai/devpack/quick-start)
- MCP 专用变量：[`China Vision MCP`](https://docs.bigmodel.cn/cn/coding-plan/mcp/vision-mcp-server)、[`Global Vision MCP`](https://docs.z.ai/devpack/mcp/vision-mcp-server)
