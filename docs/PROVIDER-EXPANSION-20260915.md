# Provider expansion — 2026-09-15

## Frozen delivery boundary

Base: `563896a`. Implement the user's 31 named provider families, reusing existing contracts,
and keeping distinct regions, billing plans, credential issuers and protocols explicit. A family
is not automatically one template. Official sources that cannot be verified are recorded as
pending; an unverified identity or endpoint must not enter the built-in catalog as a fact.

Required: official creation guidance and sources, complete credential fields, compatible
environment-variable aliases, explicit plan/region endpoints, conservative expiry and shape
rules, and canonical China/global Zhipu IDs without modifying existing stored credentials.

Not in this batch: real account/key creation, billing, secret rotation, automatic refresh,
website deployment/public release, custom logo design, or a new UI layout. Existing official
marks are reused when available; new artwork acquisition is a follow-up.

Blockers: secret disclosure, incorrect destination/credential contract, data loss or unintended
write, existing compatibility/startup regression, or failure of the required gates below.
Other improvements are follow-ups, not reasons for unlimited review.

## Coverage and ownership

| Requirement | Contract / gate | Owner |
|---|---|---|
| Official gateway boundaries | Gateway research + exact source URLs + catalog tests | Gateway investigator / integrator |
| Cloud/model region and plan boundaries | Model research + region/plan matrix tests | Model investigator / integrator |
| Routing platforms and Zhipu compatibility | Routing research + old-ID/field tests | Routing investigator / integrator |
| One saved value, multiple official env names | Provider field aliases → signed CredentialField aliases → existing run injection; save-path and process tests | Integrator |
| Endpoint metadata cannot redirect an automatic probe | Endpoints are descriptive only, never implicitly injected or probed | Integrator |
| Failed validation preserves old values | Existing replacement and storage regression suite | Existing App save boundary |
| Installed App and CLI match candidate | Full tests once, signed build + isolated E2E, signature/hash/version checks, read-only native UI smoke | Integrator |

Mechanical closure: focused red/green tests first → finish catalog → immutable candidate
review → full gate → commit → signed isolated E2E → recoverable local install → handoff.
Two review rejections trigger one grouped diagnosis and user-visible stop condition, not
open-ended patch/review ping-pong.

## Integration record

- 42 additional templates; 113 total. All named families except E-FlowCode are covered.
- E-FlowCode is pending issuer/console identity verification, not a silently invented endpoint.
- Foundation review 1: one compatibility blocker (old `save --provider` default write target).
  Fixed with frozen legacy spelling defaults and red/green CLI tests. Review 2: ACCEPTED.
- Gateway/routing independent review: ACCEPTED (12 focused tests).
- Cloud/enrichment review 1: grouped corrections to StepFun paths, ModelScope SDK env,
  case-insensitive aliases, Zhipu Responses, NVIDIA copy guidance, MiniMax SDK alias/prefix.
  NVIDIA "may not be retrievable" must not be upgraded to an unproven always-once claim.
- Same canonical-ID compatibility sweep found the detail picker still bound to a raw legacy
  ID. Display-only resolution now matches canonical menu tags; storage and values stay intact.
- UI skill routing selected the existing SwiftUI picker/binding patterns; no layout changes.
- `PROVIDER-EXPANSION-USAGE.md` records remaining limits, notably explicit endpoint setup,
  no automatic BASE_URL injection, and no claim of destination enforcement or real-key E2E.
- Final full gate, signed isolated E2E and installed version are recorded in the Vault handoff.
