# 模型与网关模板接入（2026-09-15）

本批在 71 个合同上新增 42 个，共 113 个。用户清单的 31 个品牌家族中，30 个已有模板覆盖；E-FlowCode 等待核对发行方，不冒险添加。地区、套餐、凭据种类不同会拆成多个模板，模板数不是供应商品牌数。

## 怎么使用

```sh
keykeeper providers
keykeeper providers show zhipu-cn
keykeeper providers show atlascloud-coding-plan
keykeeper providers show aws-bedrock-short-term
```

`show` 返回官方创建页、权限/登录门禁、字段、环境别名、协议与地区 endpoint、有效期政策及官方来源。按照真实账号的地区和套餐选模板，再用既有安全导入入口保存。不要把值写进命令、聊天或日志。

```sh
keykeeper save --provider zhipu-cn --from-browser --create
keykeeper run -c zhipu-cn --reason "使用此项目的智谱 API" -- your-command
```

接收页只负责安全传递，仍需在 App 中确认。`save` 成功只证明保存成功；本批新增模板没有默认在线探测，不等于账号可调用或套餐有余额。

## 环境变量与兼容性

- 主字段保留供应商/客户端变量对应的名字，不统一改成 `api-key`，避免所有字段都变成 `API_KEY` 并破坏旧脚本。
- 官方同值变量记录为字段 `aliases`，创建时随同一份秘密写入签名元数据；不存两份 key。没有官方默认 env 时明确写为 KeyKeeper 本地注入名，客户端需要显式读取。
- 国内智谱新模板为 `zhipu-cn`，字段 `zai-api-key`，兼容旧 SDK 的 `ZHIPUAI_API_KEY`。旧存储不自动改名、不增写 aliases。
- 已发布的 `save --provider zhipu` 等旧拼写继续以旧 credential ID/字段为默认保存目标；`--provider zhipu-cn` 使用新默认。显式 `-c`、`--field` 始终优先。
- endpoint 是供调用方配置的事实，**不会自动设置 BASE_URL，也不是网络目的域限制**。兼容 OpenAI 协议的网关 key 必须搭配本网关地址，不能只设置 `OPENAI_API_KEY` 而让客户端沿用 OpenAI 默认地址。
- 多凭据同时注入时，不能把多个供应商竞争的通用客户端变量当作自动选择器；调用方需明确选择目标凭据和 endpoint。
- Bedrock 短期 key 的小时级期限仅是政策说明；当前单条实际到期字段仍是日期粒度，不提供自动续期或小时级到期调度。

## 本批接入

| 分组 | 模板覆盖 |
|---|---|
| Gateway：17 项新增 | AtlasCloud 按量/Coding；Compshare ModelVerse CN/global、Agent Plan；CCSub；Micu Claude/Codex；RightCode Codex；Cubence；CrazyRouter；DMX CN/global/SSVIP；AiHubMix；Amux；CherryIN |
| Cloud/model：17 项新增 | Bedrock 短期/长期 bearer；千帆 CN/global/Token 福利包；NVIDIA Catalog/NGC；ModelScope CN/global；Novita；LongCat；StepFun 按量/Step Plan；MiMo 按量、Token Plan CN/SG/EU |
| Routing：5 项新增 | OpenCode Console/Go；PipeLLM；RelaxyCode；TheRouter |
| 百炼：3 项新增 | 新加坡、美国弗吉尼亚、中国香港按量；原北京、Coding Plan、Token Plan 保留 |
| 既有合同补齐 | SiliconFlow、DeepSeek、OpenRouter、xAI、MiniMax 四类、智谱/Z.AI 四类及百炼补路由/官方来源 |

## 未冒充完成的部分

- **E-FlowCode**：用户提供的仓库中，克隆地址、贡献者、运营域名与服务发行方关联未闭合；未添加模板，不发送凭据。
- 百炼东京、法兰克福只有业务空间专属域名，本批没有新增这两项；中国/全球套餐之外的其他变体不猜测。
- 百度国际 endpoint 已核实，CN/global 账号及 key 是否互通未知；模板分开且不承诺互通。
- TheRouter 官方要求清空客户端已有 `ANTHROPIC_API_KEY`，本批仅在 gate 提醒，不擅自改用户环境。
- 官网页面、正式安装包、appcast 尚未同步本批；本批交付为源码和验收后的本机 App/CLI。
- 新品牌的官方图标/主题色采购另列后续；已存在的官方资产复用，尚无已核实素材时只用中性字母回退。
- 真实账号创建、付费、套餐开通及每家实际调用没有执行。隔离验收使用合成值，不能称为所有供应商真人认证通过。

## 审计来源

- [Gateway 矩阵](provider-research-gateways-20260915.md)
- [Cloud/model 矩阵](provider-research-models-20260915.md)
- [Routing 与智谱矩阵](provider-research-routing-20260915.md)
- 百炼：[创建 key](https://help.aliyun.com/zh/model-studio/get-api-key)、[地区及 Base URL](https://help.aliyun.com/zh/model-studio/base-url)
- MiniMax：[API overview](https://platform.minimax.io/docs/api-reference/api-overview)、[客户端配置](https://platform.minimax.io/docs/token-plan/other-tools)
- 其他既有合同的精确来源同时随 `providers show` 返回。
