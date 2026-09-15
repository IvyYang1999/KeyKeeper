# 第三方模型网关 Provider 合同复核（2026-09-15）

## 范围与安全边界

本轮只核对供应商自己发布的文档和控制台链接，不登录、不创建账户、不读取真实凭据、不发送带密钥请求。模板只描述网关自己发行的 key；“兼容 OpenAI / Anthropic / Gemini 协议”不等于可以保存对应模型原厂 key。

所有未被官方明确说明的 key 前缀、最短长度、一次展示、统一有效期均记为 `unknown`，不从示例值推断。除 CrazyRouter 的官方文档明确要求 `sk-...` token 外，其余模板不设前缀门禁。所有网关的在线 validation 均保持 `nil`：本轮没有足够证据证明存在稳定、只读、无计费且不会把秘密发往错误 realm 的认证探测。

字段说明：`env` 是 KeyKeeper 的主字段/环境变量；`aliases` 仅列供应商文档明确要求同一值注入的客户端变量。供应商没有原生环境变量时，采用品牌专属 env，避免把普通 `OPENAI_API_KEY` 当作原厂凭据；这类自定义 env 会明确标注。

## 可落地合同

| Provider ID | 主字段 / aliases | 精确创建入口 | 固定 endpoint / 协议 | 套餐、地区与生命周期事实 | 官方来源 |
|---|---|---|---|---|---|
| `atlascloud` | `ATLASCLOUD_API_KEY`（官方） | `https://www.atlascloud.ai/console/api-keys` | OpenAI-compatible `https://api.atlascloud.ai/v1`；图像/视频/上传另用 `https://api.atlascloud.ai/api/v1` | 普通按量 key；官方明确完整值只显示一次。未说明统一有效期、前缀或长度。 | [API Keys](https://www.atlascloud.ai/docs/en/api-keys) |
| `atlascloud-coding-plan` | `ATLASCLOUD_CODING_API_KEY`（KeyKeeper canonical）；aliases `OPENAI_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | `https://www.atlascloud.ai/console/api-keys`，在 Plan Management 获取 | OpenAI-compatible `https://api.atlascloud.ai/v1`；Anthropic Messages `https://api.atlascloud.ai` | 官方明确 Coding Plan 使用与普通 Atlas Cloud key 分离的专用 key。Coding 页面未确认一次展示或统一有效期，不能继承普通 key 的 shown-once 结论。 | [Coding Plan API](https://www.atlascloud.ai/docs/coding-plan/api) |
| `compshare-modelverse-cn` | `COMPSHARE_API_KEY`（KeyKeeper canonical） | `https://console.compshare.cn/` → ModelVerse API Key | OpenAI-compatible `https://api.modelverse.cn/v1`；Anthropic/Gemini client base `https://api.modelverse.cn` | 普通按量 ModelVerse；不是 Agent Plan。未确认官方 env、一次展示、统一有效期、前缀或长度。 | [Quick Start](https://compshare.cn/docs/modelverse/models/quick-start), [Certificate](https://compshare.cn/docs/modelverse/models/common/certificate) |
| `compshare-modelverse-global` | `COMPSHARE_API_KEY`（KeyKeeper canonical） | 同上 | OpenAI-compatible `https://api.umodelverse.ai/v1`；Anthropic/Gemini client base `https://api.umodelverse.ai` | 官方称海外地址与中国地址提供相同内容，并建议 `.cn` 不可访问时使用；拆成独立 ID 是为了让秘密目的域显式可审查，不推断跨域 key 合同。 | [Quick Start](https://compshare.cn/docs/modelverse/models/quick-start), [Certificate](https://compshare.cn/docs/modelverse/models/common/certificate) |
| `compshare-agent-plan` | `COMPSHARE_AGENT_PLAN_API_KEY`（KeyKeeper canonical）；aliases `OPENAI_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | `https://console.compshare.cn/light-gpu/model-manage` | OpenAI-compatible `https://cp.compshare.cn/v1`；Anthropic Messages `https://cp.compshare.cn` | FAQ 明确普通按量与 Agent Plan 的 BaseURL 和 API Key 都不同；套餐到期或配额耗尽后停止。Codex 指南里的本地 `PROXY_ACCESS_KEY` 是 ccx 代理口令，不是 Compshare key，绝不能收进此模板。 | [FAQ](https://compshare.cn/docs/modelverse/codingfaq), [Use cases](https://compshare.cn/docs/modelverse/package_plan/usecases), [Codex Agent](https://compshare.cn/docs/modelverse/best_practice/codexagent) |
| `ccsub` | `CCSUB_API_KEY`（KeyKeeper canonical）；aliases `OPENAI_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | `https://www.ccsub.net/keys` | OpenAI-compatible `https://www.ccsub.net/v1`；Anthropic Messages `https://www.ccsub.net` | 安装页明确同一 CCSub key 的两种客户端配置。未确认一次展示、统一有效期、前缀或长度。 | [Install](https://www.ccsub.net/docs/install) |
| `micu-claude` | `MICU_API_KEY`（KeyKeeper canonical）；alias `ANTHROPIC_API_KEY` | `https://www.micuapi.ai/sign-in?redirect=%2Fdashboard` → Token management | Anthropic Messages `https://www.micuapi.ai` | 官方文档说明 Claude、Codex、Grok、国内模型等 token 分组不同，分组不匹配会 401/403 或模型不可用；因此不与 Codex 模板合并。未确认一次展示、统一有效期、前缀或长度。 | [Claude Code](https://docs.micuapi.ai/claude-code/config), [External compatibility](https://docs.micuapi.ai/external-compat) |
| `micu-codex` | `MICU_API_KEY`（KeyKeeper canonical）；alias `OPENAI_API_KEY` | 同上 | OpenAI Responses `https://www.micuapi.ai/v1` | 只覆盖 Codex/OpenAI Responses 和对应 token 分组；不能假设与 Claude 分组 key 互通。 | [External compatibility](https://docs.micuapi.ai/external-compat) |
| `rightcode-codex` | `RIGHTCODE_API_KEY`（KeyKeeper canonical）；alias `OPENAI_API_KEY` | `https://rightapi.ai/` → 令牌管理 | OpenAI Responses `https://rightapi.ai/codex/v1` | key 可限制模型，并可关闭“允许使用余额”；只用 Codex 套餐时关闭余额可避免套餐外按量扣费。未确认一次展示、统一有效期、前缀或长度。 | [API key 管理](https://docs.right.codes/docs/rc_quick_start/apikey), [Codex](https://docs.right.codes/docs/rc_cli_config/codex) |
| `cubence` | `CUBENCE_API_KEY`（KeyKeeper canonical）；aliases `OPENAI_API_KEY`, `ANTHROPIC_AUTH_TOKEN` | `https://cubence.com/dashboard/keys` | 推荐 OpenAI-compatible `https://api.cubence.com/v1`；Anthropic Messages `https://api.cubence.com` | 创建 key 时可设置 Quota Limit；官方说明当前按量计费、不提供订阅，且仅在支持的国家/地区可用。未确认一次展示、统一有效期或长度。官网中的 `sk-user-...` 标为示例/illustration，不作为格式门禁。 | [Quick Start](https://docs.cubence.com/en/docs/quick-start), [Endpoints](https://docs.cubence.com/en/docs/guides/endpoints), [Claude](https://docs.cubence.com/en/docs/setup/claude-code), [Codex](https://docs.cubence.com/en/docs/setup/codex) |
| `crazyrouter` | `CRAZYROUTER_API_KEY`（官方）；alias `OPENAI_API_KEY` | `https://crazyrouter.com/` → Token Management | 国际 OpenAI `https://api.crazyrouter.com/v1`、Anthropic `https://api.crazyrouter.com`；东亚分别为 `https://cn.crazyrouter.com/v1`、`https://cn.crazyrouter.com` | API 域名只用于模型/媒体；账户、钱包、token、日志管理必须留在 `crazyrouter.com`。官方明确要求创建 `sk-...` token，并建议按工具拆 key、限制模型/IP/预算；未确认最短长度、一次展示或统一有效期。 | [OpenClaw](https://docs.crazyrouter.com/en/openclaw-deploy), [Endpoints](https://docs.crazyrouter.com/en/api-endpoint) |
| `dmxapi-cn` | `DMX_API_KEY`（官方） | `https://www.dmxapi.cn` → 工作台 → 令牌管理 | OpenAI-compatible `https://www.dmxapi.cn/v1`；Claude Code root `https://www.dmxapi.cn` | 国内站、人民币、折扣渠道；令牌必须与域名配套。创建时可设置到期、模型、IP、速率；默认永久有效，推荐 `default` 分组。未确认一次展示、前缀或长度。 | [Token](https://doc.dmxapi.com/lingpai.html), [Base URL](https://doc.dmxapi.com/baseurl.html) |
| `dmxapi-global` | `DMX_API_KEY`（官方） | `https://www.dmxapi.com` → 工作台 → 令牌管理 | OpenAI-compatible `https://www.dmxapi.com/v1`；Claude Code root `https://www.dmxapi.com` | 国际站、美元、折扣渠道；与 CN/SSVIP key 不互通，其他生命周期合同同上。 | [Token](https://doc.dmxapi.com/lingpai.html), [Base URL](https://doc.dmxapi.com/baseurl.html) |
| `dmxapi-ssvip` | `DMX_API_KEY`（官方） | `https://ssvip.dmxapi.com` → 工作台 → 令牌管理 | OpenAI-compatible `https://ssvip.dmxapi.com/v1`；Claude Code root `https://ssvip.dmxapi.com` | 国际服、美元、原价无折扣；与 CN/普通国际站 key 不互通，其他生命周期合同同上。 | [Token](https://doc.dmxapi.com/lingpai.html), [Base URL](https://doc.dmxapi.com/baseurl.html) |
| `aihubmix` | `AIHUBMIX_API_KEY`（官方示例变量） | `https://aihubmix.com/token` | 主 OpenAI-compatible `https://aihubmix.com/v1`；官方备用 `https://api.inferera.com/v1` | 官方要求注意每个 key 的 validity period 和 usage limits，但未给统一期限；创建时应记录页面实际日期。未确认一次展示、前缀或长度。 | [Quick Start](https://docs.aihubmix.com/en/quick-start) |
| `amux` | `AMUX_API_KEY`（官方） | `https://amux.ai/keys` | 当前 OpenAI-compatible `https://gateway.amux.ai/v1`；Anthropic/Gemini client base `https://gateway.amux.ai` | key 属于 workspace，个人和组织账户余额分离；当前为预付按量且尚无订阅。官方明确 key 创建后仍可在 keys 页面查看，因此 `shownOnce=false`。较早 `www.amux.ai/docs/amux-api` 的 `api.amux.ai` 不用于新模板，采用 2026-08/09 更新后的 `gateway.amux.ai`。 | [Quickstart](https://amux.ai/docs/quickstart), [API reference](https://amux.ai/api-reference) |
| `cherryin` | `CHERRYIN_API_KEY`（KeyKeeper canonical）；alias `ANTHROPIC_AUTH_TOKEN` | `https://open.cherryin.net` → Token Management | OpenAI-compatible `https://open.cherryin.net/v1`；Anthropic Messages `https://open.cherryin.net` | `default` 组可调用通用模型；促销组 token 必须匹配对应模型组，官方建议分别配置。未确认一次展示、统一有效期、前缀或长度；文档中的 `sk-xxxxx` 只是占位示例。 | [Quick Start](https://docs.cherryin.ai/en/docs/newapi/getting-started/), [OpenAI-compatible](https://docs.cherryin.ai/en/docs/newapi/openai-compatible-usage/), [Claude Code](https://docs.cherryin.ai/en/docs/newapi/claude-code-usage/) |

## 拆分结论

必须拆开的合同：

- Atlas Cloud 普通按量 vs Coding Plan：官方明确 key 独立。
- Compshare ModelVerse 按量 vs Agent Plan：官方明确 BaseURL 和 key 都要同时更换。
- Micu Claude vs Codex：token 渠道分组按模型/客户端区分，不能承诺互通。
- DMXAPI CN / COM / SSVIP：官方明确令牌与域名配套，且币种、折扣渠道不同。
- Compshare CN / global access：服务内容相同，但目的域不同；独立模板让每次秘密注入的目标域可见，避免后台静默切换。

## Pending，不进入强约束

- Micu、RightCode、CrazyRouter、CherryIN 的公开文档只给出控制台根路径或登录后的菜单，没有公开、稳定、免登录可核对的深层 token URL；模板使用官方控制台入口并把人工菜单路径写进 gate，不猜 `/console/token`。
- 除 Atlas Cloud 普通 key 和 Amux 的“可再次查看”外，其余供应商未清楚声明完整值是否只显示一次。实现一律 `shownOnce=false`，其语义是“未确认”，不是承诺可找回。
- 除 Compshare Agent Plan、DMXAPI、AIHubMix 的上述事实外，未发现统一有效期合同；不替用户编造到期日。
- 未发现足以安全上线的只读 validation 合同。模型列表端点也可能计费、受套餐/分组影响，或无法区分“有效但无权限”和“无效 key”；本批全部保持 `validation=nil`。
- Atlas Coding、Compshare、CCSub、Micu、RightCode、Cubence、CherryIN 没有稳定的供应商原生 env 命名时，品牌专属主 env 是 KeyKeeper canonical；只有官方工具配置明确出现的 `OPENAI_API_KEY` / `ANTHROPIC_*` 才作为同值 alias。
