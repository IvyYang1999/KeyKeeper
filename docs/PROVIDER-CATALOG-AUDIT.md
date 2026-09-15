# Provider catalog audit

Last verified: 2026-09-15

This document records the safety boundary behind `keykeeper providers`. A provider template is a
credential contract, not merely a brand name. Region, billing plan, owner, protocol, and credential
type are separate templates whenever mixing them can reject a valid key, save an incomplete bundle,
grant broader access, or charge the wrong account.

## Audited contract boundary

The catalog contains 71 explicit credential contracts. Existing IDs and field names
remain compatible, including `zhipu` → `zhipuai-api-key` / `ZHIPUAI_API_KEY`.

The following distinctions are represented as separate selectable entries:

- Kimi China pay-as-you-go, Kimi Global pay-as-you-go, and Kimi Code.
- Zhipu China API, Zhipu China Coding Plan, Z.AI Global API, and Z.AI Global Coding Plan.
- MiniMax China/Global pay-as-you-go and China/Global Token Plan.
- Alibaba Bailian Beijing pay-as-you-go, China Coding Plan, and China Token Plan.
- Volcengine Ark China pay-as-you-go and China Coding Plan.
- SiliconFlow China and Global.
- Cloudflare user-owned and account-owned tokens.
- Neon personal and organization/project-scoped keys.
- Railway project tokens and account/workspace API tokens.
- AWS long-lived IAM keys and complete STS temporary credential bundles.
- PyPI and TestPyPI; Docker Hub personal and organization access tokens.
- PostHog Cloud US and EU; SendGrid US and EU regional subusers.
- App Store Connect team and individual API keys; Apple notarization by app-specific password or
  team API key; Developer ID Application and Installer identities.
- Feishu China and Lark Global; Slack non-rotating bot tokens and rotating OAuth bundles.

Variants whose official creation path or credential contract could not be verified precisely are
omitted instead of being guessed. Current known limits: BytePlus ModelArk AP/EU and Coding Plan,
Alibaba Model Studio Singapore/global plan variants, PostHog self-hosted, Sentry self-hosted and
personal tokens, GitLab personal/group/self-managed tokens, Mailgun account/RBAC keys, and non-US1
Twilio credentials. The existing entries state their narrower supported boundary in the name.

## Validation rules

- A probe is optional. Missing validation means “not checked”, never “invalid”.
- Secrets only travel to a fixed HTTPS provider host, in an authentication header, using a
  side-effect-free GET. Providers requiring POST, Basic bundle auth, tenant-specific hosts, a token
  in the URL, or structured response assertions are not probed by the current engine.
- HTTP 401 (and Gemini's documented 400 case) can mean invalid authentication. HTTP 403 is treated
  as unknown because it commonly means valid credentials without permission, SSO/IP policy, wrong
  team/resource context, or rate limiting.
- Cloudflare verification is disabled until the probe can assert JSON `status == active`; HTTP 200
  alone is insufficient. Slack `auth.test` is also disabled because it is POST and reports failure
  inside an HTTP 200 JSON body.
- Only documented full-value grammars are hard blockers. Current strict examples include PyPI,
  Telegram bot tokens, AWS access-key IDs, Twilio SIDs, Kimi Code, and plan-specific MiniMax/Bailian
  prefixes. Observed sample lengths are not contracts.

## Expiration semantics

KeyKeeper keeps two facts separate:

1. `expiryNote` is the provider policy or an explicit statement that no universal policy was
   confirmed. It appears in the save confirmation and credential details.
2. `Credential.expires` is the recorded date for this exact credential. It is editable, appears as
   a list/detail badge, and produces CLI warnings. KeyKeeper does not disable or delete a credential
   based on that date because a recorded reminder can be wrong.

Short-lived credentials such as AWS STS and Slack rotating access tokens also carry their complete
bundle fields. KeyKeeper currently records a day-level reminder, not an automatic refresh workflow;
their consuming integration remains responsible for refreshing before the provider timestamp.

## Logo policy

Regional and plan variants reuse the same provider artwork. KeyKeeper prefers exact provider-owned
artwork, preserves multicolour marks instead of tinting them, and records the first-party source next
to every bundled mark. If no suitable official asset is available, it uses a lettermark in the
provider's brand colour. It does not invent a neutral pseudo-logo.

OpenAI artwork comes from the [OpenAI brand package](https://openai.com/brand/), Kimi from the
[official Moonshot branding guide](https://moonshotai.github.io/Branding-Guide/), Z.AI from the
[official Z.AI site](https://z.ai/), Feishu from its provider CDN, and Slack from the
[Slack media kit](https://slack.com/media-kit). The catalog also uses the current first-party marks
for Volcengine Ark, AWS, Azure, App Store Connect, Telegram, and PostHog. Apple services without a
standalone service logo use distinct Apple SF Symbols: a seal for notarization, a badged bell for
APNs, and an identity card for Developer ID. This avoids both the ambiguous `A` fallback and the
incorrect reuse of the Apple corporate logo.

Known distribution limit: the public trademark/asset terms for Apple, AWS, Azure, and Volcengine do
not expressly license every third-party product-picker use. The product owner chose exact,
subordinate provider identification rather than synthetic marks; distribution should still obtain
brand-owner permission or legal review. This does not change the credential contracts or security
boundary.

## Verification and remaining work

- The isolated App/CLI E2E exercises 40 scenarios with synthetic credentials, including rejected
  formats and unchanged storage, save/replace approval, grant lifetime, and relaunch. This is not
  a claim that all 71 contracts have been tested against real provider accounts.
- All text-provider templates have synthetic save-path coverage. Official asset hashes and
  non-empty/colour-preserving rendering are checked; light/dark icon sheets and the expiration
  policy/date presentation were visually reviewed.
- Provider policy does not supply the real expiration timestamp of an existing credential.
  Automatic renewal, second-level expiration enforcement, and providers listed under known limits
  remain follow-ups.
- Public release and regeneration/deployment of the separate website's provider JSON/docs are
  separate delivery steps. Do not treat this source audit as evidence that those surfaces updated.
- The full-catalog preview still emits a pre-existing CoreSVG path warning. The newly replaced
  marks render correctly in isolated pixel checks; identifying that unrelated asset is a follow-up.

## Primary sources by area

- OpenAI: [API quickstart](https://platform.openai.com/docs/quickstart/make-your-first-api-request),
  [key permissions](https://help.openai.com/en/articles/8867743-assign-api-key-permissions).
- Anthropic: [authentication](https://platform.claude.com/docs/en/manage-claude/authentication),
  [models](https://platform.claude.com/docs/en/api/models/list).
- Gemini: [API keys](https://ai.google.dev/gemini-api/docs/api-key).
- Kimi: [China quickstart](https://platform.kimi.com/docs/api/quickstart),
  [Global overview](https://platform.kimi.ai/docs/api/overview),
  [Kimi Code setup](https://www.kimi.com/code/docs/third-party-tools/codex.html).
- Zhipu/Z.AI: [China Coding Plan](https://docs.bigmodel.cn/cn/coding-plan/quick-start),
  [Z.AI Coding FAQ](https://zcode.z.ai/en/docs/qa),
  [legacy SDK contract](https://github.com/MetaGLM/zhipuai-sdk-python-v4).
- MiniMax: [Token Plan](https://platform.minimax.io/docs/token-plan/intro).
- Alibaba Bailian: [regions](https://www.alibabacloud.com/help/en/model-studio/regions),
  [Coding Plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan),
  [Token Plan](https://www.alibabacloud.com/help/en/model-studio/token-plan-overview).
- Volcengine/BytePlus: [Ark quickstart](https://www.volcengine.com/docs/82379/1795150),
  [Ark Coding Plan](https://docs.volcengine.com/docs/82379/1928261),
  [ModelArk regions](https://docs.byteplus.com/api/docs/modelark/2191806).
- Cloud/deployment: [Cloudflare token formats](https://developers.cloudflare.com/fundamentals/api/get-started/token-formats/),
  [Railway tokens](https://docs.railway.com/integrations/api),
  [AWS temporary credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_use-resources.html),
  [PyPI secret format](https://docs.pypi.org/api/secrets/),
  [Docker token types](https://docs.docker.com/security/access-tokens/personal-access-tokens/).
- Apple: [App Store Connect API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api),
  [notarization credentials](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
  [APNs keys](https://developer.apple.com/help/account/keys/create-a-private-key),
  [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
- Messaging/observability: [Slack token rotation](https://api.slack.com/authentication/rotation),
  [Twilio API keys](https://www.twilio.com/docs/iam/api-keys/key-resource-v1),
  [Mailgun authentication](https://documentation.mailgun.com/docs/mailgun/api-reference/mg-auth),
  [PostHog API regions](https://posthog.com/docs/api),
  [Sentry authentication](https://docs.sentry.io/api/auth/).
