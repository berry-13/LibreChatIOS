# Presets and native application

**Pinned LibreChat source:** `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native status:** live owner library, reviewed New Chat-only application, and bounded native creation implemented; edit/default/import/export/delete remain server-web surfaces  
**Evidence boundary:** package tests and generic iOS/iOS 17 builds pass; authenticated live and hands-on accessibility acceptance remain pending

## Product boundary

A LibreChat preset is not merely a saved model name. It is a per-user snapshot
over much of the conversation/provider parameter surface: routing, model,
instructions, sampling controls, reasoning controls, tools, files, search,
streaming behavior, and provider-specific fields can all be present. The native
app therefore treats presets as an evolving remote protocol, not as a Swift
copy of `TPreset`.

The first native slice has five deliberate constraints:

1. Presets are fetched live for the selected profile/account and are not put in
   SwiftData. A prompt prefix may be private and server access can be revoked.
2. Choosing a preset is possible only from **New chat**. It never rewrites an
   existing history or branch in place.
3. A preset must resolve to exactly one target in the freshly authenticated
   `TargetCatalogSnapshot`. Missing, stale, foreign-account, unauthorized, or
   ambiguous targets fail closed.
4. The app applies only fields its generation request reproduces exactly today:
   `endpoint`, optional `endpointType`, `model`, `agent_id`, `assistant_id`,
   `spec`, and `promptPrefix`. Any other meaningful execution field keeps the
   preset visible for review but disables Create.
5. Native creation is only for a newly reviewed target. It never turns the
   broader server upsert into a general preset editor.

Preset entry and every preset request are also capability-gated. The app
requires fresh authenticated policy evidence and `interface.presets == true`.
LibreChat's loaded-interface default is enabled when that key is absent, but
the native client trusts that default only after authenticated configuration.
Anonymous, failed, offline, malformed, or explicit-false policy leaves
`supportsPresets` unavailable/false and hides the library and creation controls
without issuing a preset request.

That last rule is important. Silently dropping `temperature`, `tools`,
`web_search`, `presetOverride`, reasoning controls, file IDs, or an unknown
future setting would create a chat that is labelled like the saved preset but
does not behave like it.

## Pinned server contract

All preset routes are JWT-protected by router middleware
(`api/server/routes/presets.js:5-12`).

| Operation | Exact route | Current response | Native use |
|---|---|---|---|
| List | `GET /api/presets` | `200` array of owner presets | Implemented, bearer, idempotent retry capped at two attempts |
| Bounded create | `POST /api/presets` | `201` saved preset; server also returns `201 {"message": …}` on an internal save failure | Implemented only for the safe native subset below |
| Delete one/all | `POST /api/presets/delete` with optional `presetId` | `201` Mongo delete result | Not implemented |

The database query is owner-filtered and sorted by `order` ascending, then
`updatedAt` descending; rows without `order` use an effective sort value of
10,000 (`packages/data-schemas/src/methods/preset.ts:137-188`). The native
mapper preserves that authoritative array order.

Upsert is not a conventional create/update pair. It is an owner-scoped upsert
by `presetId`; tools are normalized to string keys, a new default receives
`order: 0`, and a previous default is unset
(`packages/data-schemas/src/methods/preset.ts:191-253`). This is why default,
editing, default management, and deletion are not inferred from the bounded
create contract.

## Bounded native creation contract

Creation is intentionally a new, reviewed operation rather than a raw DTO
forwarder or an editable upsert screen.

1. The caller supplies a freshly generated UUID `presetId`, a title, optional
   prompt prefix, exact profile/account IDs, and a reviewed target option ID
   plus its execution-only fingerprint.
2. Immediately before dispatch, the repository fetches the live
   `TargetCatalogSnapshot` and requires the profile/account, option ID, and
   endpoint/endpointType/model/agent/assistant/spec fingerprint to match.
   Parent-message and ephemeral-agent state are never fingerprinted or
   persisted. A missing, changed, foreign, or unsupported target fails closed.
3. The one-shot `POST /api/presets` body contains only `presetId`, `title`,
   `endpoint`, and present `endpointType`, `model`, `agent_id`, `assistant_id`,
   `spec`, and `promptPrefix` fields. It omits `defaultPreset`, `order`,
   ownership/tenant identifiers, tools, files, parent message IDs, ephemeral
   agent configuration, sampling/reasoning/search controls, and all unknown
   fields. Retry policy is `.never`.
4. A `201` is confirmed only after strict mapping proves that the response is a
   native-representable preset with the exact caller UUID, title, reviewed
   target, prompt prefix, no default flag, and no meaningful unsupported
   settings. In particular, `201 {"message":"Error saving preset"}` is an
   error, not a created preset.
5. Definite 401 and 4xx outcomes are thrown. Only an already-dispatched request
   whose result cannot be reconciled may become finite `outcomeUnknown`; the UI
   locks another create and performs one owner-scoped `GET /api/presets`
   reconciliation. It never reposts automatically.

This creates a safe **create** operation despite LibreChat's upsert route. It
does not claim semantic support for editing an existing UUID or any server-side
default behavior.

The Mongoose schema spreads `conversationPreset`, whose fields include model
parameters, prompt/cache/thinking controls, tools, files, instructions,
reasoning, search, URL context, and streaming policy
(`packages/data-schemas/src/schema/preset.ts:5-94` and
`packages/data-schemas/src/schema/defaults.ts`). Unknown fields can also reach
older or newer deployments. The native DTO consequently captures a lossless
`[String: JSONValue]` envelope and classifies it after decoding.

## Difference from the web client

The web selection handler can clean unavailable tools, switch an existing
modular conversation, merge current conversation state, and construct another
conversation from the selected preset
(`client/src/hooks/Conversations/usePresets.ts:170-233`). New-conversation setup
may also substitute defaults, the first available endpoint/model, or an
assistant (`client/src/hooks/useNewConvo.ts:83-218`). Those behaviors are useful
inside the web app's complete parameter system, but they are unsafe defaults
for a smaller native adapter.

The native app instead shows a searchable, server-ordered library. Selecting a
preset returns to an explicit review section that shows:

- preset name and default status;
- the one authorized model/agent it resolves to;
- the complete prompt prefix in a disclosure control;
- a precise compatibility reason when application is blocked; and
- a statement that Create starts an unsent local chat and sends no message.

The model/agent picker is locked while a preset is selected. The user can
remove the preset to make a manual target choice, preventing a misleading
hybrid configuration.

## Mapping and compatibility rules

`LibreChatPresetDTO` is permissive at decode time and strict at execution time:

- `presetId` is required, bounded, opaque, and never used as a URL path;
- invalid and duplicate IDs are quarantined without changing independent row
  order;
- display title/model label are bounded before presentation;
- target coordinates and prompt prefix are type- and length-checked;
- null and empty future fields do not block a row;
- any meaningful unknown or unimplemented field becomes a bounded
  `unsupportedSettings` name;
- a nonempty `presetOverride` always blocks application because it can hide
  execution settings; and
- matching uses only the current profile/account target catalog. Optional
  coordinates narrow candidates, and anything other than one result blocks.

The target catalog remains authoritative for routing. On successful review the
app starts from that exact authorized target and overlays only the preset's
validated prompt prefix. If the preset omits a prompt prefix, a selected model
spec's authorized prompt prefix is retained. The preset title is not silently
used as the conversation title; the New Chat title remains user-owned.

## Implementation inventory

- Domain: `PresetID`, `ChatPreset`, `PresetLibrarySnapshot`,
  `PresetTargetFingerprint`, `PresetTargetReview`, `PresetCreationRequest`,
  finite creation outcome/error types, `PresetRepository`, and the narrowly
  scoped `PresetCreationRepository`.
- Protocol: permissive read DTO/classifier, duplicate/invalid quarantine, exact
  `GET /api/presets` factory/snapshot mapper, and the strict safe-subset
  `POST /api/presets` factory/confirmation mapper.
- Repository: active profile/account fencing around one live fetch; no cache.
- Presentation: New Chat library, native search, default/compatibility states,
  instruction review, target resolution, manual remove, and unsent draft
  creation.
- Fixture: one compatible and one blocked preset plus a deterministic UI flow
  that reviews instructions and creates a fresh chat.

## Verification

The complete Core run passes **350 Swift Testing tests across 43 suites plus 4
XCTest checks (354 package checks)** at
`/private/tmp/librechat-visual-audit-core`. The preset suite now covers read mapping
plus safe create fields/omissions, invalid input and target drift, and strict
success/message-envelope response handling, plus authenticated
`interface.presets` derivation that hides malformed or disabled policy.

The complete app and test bundle compile in the generic Simulator
build-for-testing at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`. Eight new app
model/repository preset-related creation/capability cases cover draft
validation, confirmed install, unknown-outcome refresh lock, changed reviewed
target, disabled capability/no traffic, post-confirm target revocation, exact
live POST body, and ambiguous reconciliation. A preset whose freshly
authorized target is later removed remains visible but non-applicable. The
reviewed-preset application and native-preset-creation XCUITest methods
compile, but no Simulator was booted and neither executed.

The generic iOS 17 device build passes at
`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`.

## Required live acceptance

Before promoting this surface to live-proven:

1. Load multiple real presets on a password-authenticated self-hosted account;
   verify server order, default marking, refresh, 401 refresh, and 403/404
   compatibility behavior.
2. Apply a simple endpoint/model/prompt preset and confirm the first generation
   receives the exact reviewed target and prompt prefix.
3. Confirm a preset with tools, sampling, search, reasoning, files,
   `presetOverride`, or an unknown field remains visible but cannot create.
4. Change/deauthorize the model or agent between list and Create; verify no
   draft is created and no fallback target is selected.
5. Switch between two accounts on one host; confirm titles and private prompt
   prefixes never cross the account boundary or appear offline.
6. Run VoiceOver, maximum Dynamic Type, keyboard, and Switch Control through
   search, selection, instruction disclosure, blocked state, removal, native
   creation review, uncertainty lock, and Create.

## Deferred breadth

Preset edit/upsert of an existing UUID, default management, import/export,
delete/clear, full provider parameter execution, tools, files, assistant
targets, and mid-conversation preset switching remain separate protocol
slices. They must not be enabled by merely forwarding the raw DTO or widening
the safe create payload.
