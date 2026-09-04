# LibreChat capability, agents, and advanced-feature audit

**Audited server:** `LibreChat` commit `b2128a7d189ac020ebb6e49a57ee986e98326b77` (source checkout `/tmp/librechat-knowledge.mI6Evl/LibreChat`).  
**iOS baseline:** this workspace as verified on 2026-08-19.  
**Scope:** pinned source/protocol audit plus the living native implementation boundary; authenticated runtime claims remain explicit.

## Executive conclusion

LibreChat's web product is a capability- and policy-driven client, not a fixed
OpenAI-compatible chat UI. A native client must first obtain anonymous startup
configuration for sign-in, then repeat `/api/config` with the authenticated
session and use the authenticated result as the authoritative feature/policy
envelope. It must discover selectable targets from the *combination* of
`/api/endpoints`, `/api/models`, `modelSpecs`, user presets, agents, assistants,
and permissions; it must not derive permission or tool availability from names
or cached UI state.

The current iOS app already has a sound foundation for the deployed generation
protocol v2: token/cookie isolation, endpoint/model discovery, model-spec target
mapping, uploading, SSE reconnection/checkpointing, tool/approval events, and
an explicit refusal of Assistant generation. Its product surface now includes
conversation/message search, bounded Projects metadata/membership workflows,
an ACL-filtered Agents library with bounded metadata edit, server duplicate, safe version review/revert, and ACL-proven delete, a live owner Files library with
inert preview and protected download/share, the authenticated shared-link owner
lifecycle, the conversation browser, and the basic composer. The largest gaps are policy-faithful
startup config, target composition, full agent/assistant authoring,
tools/MCP/OAuth, public/ACL/shared-file sharing surfaces, and rich response rendering.

## Capability matrix

| Capability | LibreChat source behavior | Native must preserve | Native may redesign | Current iOS status / priority |
| --- | --- | --- | --- | --- |
| Startup config | Anonymous `/api/config` exposes only sign-in/legal/bootstrap fields; authenticated requests add interface, model specs, balance, sharing, search, file/Sandpack and admin flags. | Fetch separately per auth state; treat absent fields as unavailable; never use anonymous response after login. | Navigation and caching strategy. | **Partial / authenticated provenance and fail-closed refresh implemented:** capability state distinguishes verified post-login policy from anonymous/legacy evidence; failure clears account-gated feature claims and exposes an explicit Settings retry. Agent support comes from authenticated `/api/endpoints`, while current-role MCP/Memory/Prompt/Bookmark and separate speech evidence are applied. The complete typed/lossless interface/model-spec envelope remains incomplete. **P0 hardening** |
| Account profile and deletion | Authenticated `GET /api/user` returns the sanitized current account; authenticated config supplies `allowAccountDeletion`; avatar mutation is under `/api/files/images/avatar`; deletion is optional-2FA `DELETE /api/user/delete`. | Require exact account identity and fresh authenticated policy; never infer mutation support for read-only identity fields; never blindly retry deletion. | A native identity/security screen with photo picker and explicit destructive confirmation. | **Implemented / package-tested and app-compiled; live-unproven:** exact profile refresh, configured avatar limit, safe PNG/JPEG upload/URL, fail-closed deletion capability, optional proof, ambiguity lock, and confirmed namespace purge/sign-out are wired. See [AccountProfileAndDeletion.md](AccountProfileAndDeletion.md). **P0 live gate** |
| Endpoints/models | Both are JWT-protected and separately resolved by server. | Fetch after login; use server data rather than a static provider list. | Picker layout/grouping. | Implemented and combined in `TargetCatalogMapper`; no capability-refresh policy. **P0** |
| Model specs | Server sanitizes/removes hidden specs; `enforce` replaces ordinary model selection. Specs can prescribe agent, tools/MCP/search/code/artifacts. | Honor hidden, `showInMenu`, defaults, and `enforce`; send the selected `spec` plus the public browser companion configuration. | Present as modes/templates rather than menu entries. | **Implemented foundation:** mapper preserves the exact visible companion defaults (`mcp`, search, files, code, memory, artifacts), rejects malformed policy, and fingerprints them for durable follow-ups. Private fields remain server-owned. Live acceptance and user overrides remain. |
| Presets | Per-user CRUD snapshots across the broad conversation/provider setting surface. | Keep them live/account-scoped; require one exact authorized target; never drop an unknown execution field or rewrite an existing history silently. | Searchable library, explicit instruction/settings review, bounded safe creation, then separate management slices. | **Read/review/apply-compatible plus bounded native create implemented / package-tested, app-compiled:** exact owner list, permissive DTO, unknown-field fail-closed classification, fresh target resolution, unsent New Chat creation, and reviewed UUID/title/routing/prompt-only creation exist. Creation refetches and exact-matches the live profile/account/target fingerprint, never retries, rejects a message-only 201, and locks/reconciles after post-dispatch ambiguity. Edit/default/import/export/delete and full provider parameters remain absent. See [PresetsAndNativeApplication.md](PresetsAndNativeApplication.md). **P1** |
| Agents | Permissioned, versioned resources; view-safe vs expanded edit data; actions/tools; chat via agent endpoint. | Agent ID and all server-validated configuration; distinguish role USE/CREATE from resource VIEW/EDIT/DELETE/share, and public agent `id` from Mongo ACL `_id`. | Dedicated agent gallery and progressively disclosed editors. | **Browse/start plus basic private creation, bounded metadata edit, server duplicate, safe version review/revert, and ACL-proven deletion implemented / package-tested, app-compiled:** ACL VIEW list/search/cursor, view-safe exact-ID detail, conversation starters, and authoritative target refresh remain. Authenticated-online AGENTS USE+CREATE permits creation only after fresh `/api/models` exact provider/model review; the one-shot allowlisted POST requires generated-ID/request-echo 201, excludes tools/actions/files/MCP/skills/subagents/credentials/avatar/sharing, and reconciles ambiguity once with owner GET before a finite no-repost lock. Expanded and historical responses are immediately reduced to safe metadata. Native PATCH sends only name/description/category and reconciles ambiguity with GET-only truth. Version history preserves the server's unmodified array indices, keeps malformed entries as non-restorable placeholders, and restores only after a fresh exact-index check. Duplicate, revert, and delete are one-shot; duplicate/revert lock if delivery is uncertain, while deletion performs one read-only existence reconciliation and succeeds only on exact acknowledgement or absence. Post-response 401/browser redirects do not replay `.never` mutations; GET/idempotent auth recovery remains available. Advanced/full configuration, avatar, action/tool, and share management remain absent. See [SavedAgentManagement.md](SavedAgentManagement.md). **P1** |
| Ephemeral agents | Request body may carry temporary agent configuration; endpoint route is `/api/agents/chat/:endpoint`; model specs merge MCP/search/file/code/artifact options. Resume restores server-captured context. | Preserve a serializable ephemeral config for a turn and do not invent it on resume. | Composer chips/sheet. | **Partial:** model-spec companion configuration is typed, serialized, restored onto hydrated visible-spec conversations, and queue-fingerprinted. The composer discloses only safe effective categories and an MCP count, never server-owned connector/artifact identifiers; unknown and verified-empty scopes remain distinct. User-controlled tool/MCP toggles are not implemented. |
| Assistants | Legacy `v1` and current `v2`, CRUD/list/docs/actions/tools/chat. | Support only after a version-aware contract is implemented; otherwise label unavailable. | Can use an assistant gallery rather than web forms. | Explicitly rejected in repository. **P1** |
| Tools/actions | Agent tools are listed/called/auth-checked; actions belong to editable agents and validate OpenAPI/domain/OAuth metadata. | Treat tool identity, result, approval and errors as server data; do not execute remote tools locally. | Tool activity cards and approval sheets. | Streaming domain has tool events/approval UI, but no catalog/configuration. **P1** |
| MCP + OAuth | CRUD server registry, list tools/status/auth variables; OAuth uses initiate/bind/callback/poll/cancel and CSRF/session/state ownership. | Use system browser and a per-flow state machine; never expose/copy tokens. | Connection-management screen. | **Read-only catalog implemented / package-tested and app-compiled:** role-gated exact list+status GETs, redacted searchable native presentation, no offline cache, and unknown-state fail-closed mapping. Selection, tools, auth-value entry, CRUD/share, and OAuth remain absent. **P1** |
| Memories | Permissioned CRUD and preference opt-out; personal vs agent partition and token/character budgets. | Send `agentId` only for an existing authorized partition; show limits; retain user opt-out; never cache private values. | Native Memory settings with live-only values, partition filters, usage, and create/edit/delete controls. | **Implemented / package-tested, app-compiled, live-unproven:** exact role bits and authenticated routes gate each action, mutations never blindly retry, response identity is verified, raw agent IDs are not displayed, and only the preference boolean is retained. Authenticated/accessibility acceptance remains pending. **P1** |
| Projects | Authenticated metadata CRUD plus move/unassign conversation; list is cursor/search/sort based. The pinned contract has no project-owned instructions, files, or sources. | Preserve project membership when reading/sending conversations without inventing project context fields. | Sidebar/tab/workspace. | **Implemented / fixture- and simulator-tested; authenticated live acceptance pending.** Strong IDs/domain types, `chatProjectId` mapping, exact routes/repository, browser/detail search/sort/paging, CRUD, project-scoped New Chat, and assign/unassign are app-wired. Clear-description, name-only search, stale-page/result fencing, stale-page 401 revision fencing, and matching-membership deletion behavior are covered. **P1 hardening** |
| Prompts/skills | Prompt groups have resource permissions; skills are user/admin-managed file trees with active/always-apply state. | Treat contents as private, permissioned server resources; never automatically execute uploaded instruction content on device. | Native prompts include a role/ACL-gated read-and-insert library plus live-only owned-template metadata/version management. Create, add version, metadata update, and explicit production promotion are exact-identity/no-retry operations with ambiguity locks or GET reconciliation; prompt text is never cached. Native Skills add bearer-authenticated paginated catalog/active-state reads, role plus agents-capability gates, active defaults, model-spec/saved-agent scope, duplicate-name quarantine, exact cancel, max-ten fresh preflight, and `manualSkills`/regeneration replay wiring. Settings manages account activation through serialized whole-map POSTs with no automatic retry and one bounded GET reconciliation. Authoring/files/import, durable pending-selection persistence, and live Skills/generation proof remain deferred. Delete, labels, sharing/ACL administration, and broader Skills authoring remain absent. | Prompt management and Skills catalog/activation are package/build evidenced but live-unproven. **P1/P2** |
| Permissions/sharing | Resource ACL endpoint, effective permissions, people picker; shared links have an authenticated owner lifecycle plus distinct public/scope-checked reader/config/file/fork routes. Omitted `snapshotFiles` defaults to enabled when supported. | Server is authority; keep resource `_id`, public `shareId`, pseudonymous shared IDs, and canonical fork IDs distinct; default to file exclusion and require explicit capability-gated opt-in. | System share sheet, owner management, owner-reachable read-only viewer, and direct-path fork review/navigation; branch-inclusive fork modes and later external-link/admin entry remain separate work. | **Owner plus bounded snapshot preview and direct-path fork implemented / broader fork modes unproven:** direct-path `POST /api/convos/fork` uses authoritative source preflight/graph validation, `.never` retry, typed preflight-vs-ambiguous handling, fresh IDs, unchanged original, and cache-after-success classification. The one-shot review sheet navigates only on authoritative dismissal. `includeBranches`, `targetLevel`, and `splitAtTarget` remain unimplemented/unproven. **P1 hardening/breadth** |
| Conversation/message search | `/api/search/enable` is only the Meilisearch health/capability probe. Conversation search uses `/api/convos?search=` and message search uses `/api/messages?search=`. | Treat the probe as retrieval-search evidence only; use the two resource routes for results. | One native library-search entry can federate both result kinds. | Implemented with Chats/Messages scopes, conversation cursors, offline cached title/model search, and conversation deep-links; fixture/simulator tested, not live-proven. **P1 hardening** |
| Owner Files library | `GET /api/files` is a complete live owner catalog; preview/download independently enforce file/tenant/agent ACLs; `DELETE /api/files` is a batch owner/resource mutation whose 200 does not expose per-file storage failure. | Treat rows as metadata, not access tokens; keep transfer disk-backed; never use signed URLs; send one exact owner delete with no blind retry and prove raw-catalog absence before success. | Native searchable/sortable catalog, inert text preview, protected download + system Share/Save, and confirmed single-owner deletion with retained/verification-required states. | **Catalog + preview + protected download/share + ambiguity-safe owner deletion implemented / package-tested and app-compiled; authenticated live pending.** Binary/image preview, reattach, bulk cleanup, agent/assistant unlinking, byte-level progress, and background transfer remain separate. See [FileCatalogAndLibrary.md](FileCatalogAndLibrary.md). **P1 hardening/breadth** |
| Web/file search and citations | `web_search` and `file_search` are generation tools. Results arrive as message/tool-scoped attachments and assistant text contains turn/type/index citation markers; file citations additionally require `FILE_CITATIONS` use permission. | Preserve attachment provenance, updates, literal/Unicode private-use markers, source metadata, and authorization. Never infer these tools from `/api/search/enable`. | Source sheet, citation grouping, and file-page presentation. | **Typed attachment/citation domain and native web-source renderer implemented / fixture-tested; live pending.** Positional file anchors deliberately fail closed because server filtering/reordering/deduplication can make their indexes ambiguous; the owner Files library does not make citation anchors actionable. **P1 hardening** |
| Balance/usage | Authenticated balance endpoint/config and per-run token usage events. | Display only server-reported balances/usage; do not estimate as billing truth. | Settings/gauge placement. | Per-generation usage model exists; balance missing. **P2** |
| Artifacts/Mermaid/code execution/UI resources | Artifacts are fenced message directives edited by document-order index; Mermaid uses `application/vnd.mermaid`; server code execution emits sandbox activity and deferred file previews; MCP UI resources are attachment payloads referenced by `\ui{resourceId}` across turns. | Preserve exact identities and pending → ready/failed updates; keep execution server-side; isolate HTML/SVG/UI resources and authorize preview/download routes. | Native semantic artifact/generated-file cards, safe plain-text preview, explicit authenticated transfer/download/share, plus constrained `WKWebView` compatibility paths later. | Artifact/generated-file presentation and lifecycle foundation is fixture/simulator-tested; HTML/SVG/Mermaid/React/unknown remain source-only; live generated-file lifecycle/download, exact artifact editing, diagram, sandbox, and UI-resource surfaces remain pending. **P1/P2** |

## Discovery and endpoint contracts

All paths are relative to the configured server origin. Authentication means the
existing server JWT/cookie/session mechanism, not a locally inferred role.

### Bootstrap and catalog

| Request | Auth | Contract and client consequence | Source |
| --- | --- | --- | --- |
| `GET /api/config` | optional JWT | Anonymous: title, server domain, e-mail/social/OpenID/SAML/LDAP availability, registration/reset/email/Turnstile, legal/build metadata. Authenticated: adds interface config, sanitized visible `modelSpecs`, balance config, share flags, web-search config, Sandpack bundler URLs, file upload flags, and related feature flags. | `api/server/routes/config.js:50-151, 196-330`; mount `api/server/index.js:314` |
| `GET /api/endpoints` | JWT | Server resolves role/tenant-scoped endpoint configuration. `GET /api/endpoints/token-config` is a second authenticated config endpoint. | `api/server/routes/endpoints.js:8-11` |
| `GET /api/models` | JWT | Server returns models separately from endpoint config. | `api/server/routes/models.js:5-8` |
| `GET /api/keys?name=…`; `PUT /api/keys`; `DELETE /api/keys/:name` | JWT | Endpoint config proves which account credentials are required. Reads return expiry only; writes are opaque encrypted values; mutation retry is unsafe. Exact native forms: [UserProvidedProviderCredentials.md](UserProvidedProviderCredentials.md). | `api/server/routes/keys.js:1-52`; `packages/data-schemas/src/methods/key.ts:22-112` |
| `GET /api/presets`; `POST /api/presets`; `POST /api/presets/delete` | JWT | Per-user preset list, upsert (`presetId` generated if absent), delete one or all. | `api/server/routes/presets.js:8-51` |

Important protocol detail: `/api/config` is explicitly mounted with
`optionalJwtAuth`, whereas endpoint and model discovery require JWT. The React
query key includes `isAuthenticated` specifically to prevent anonymous startup
config being reused post-login (`client/src/data-provider/Endpoints/queries.ts:35-78`).

`modelSpecs` is a server-filtered policy document. Its `list` drives named
targets, `enforce` suppresses ordinary endpoint/model choices, and specs may
bring an agent preset and a tool configuration. `buildEndpointOption` resolves
the named spec on the server in both enforced and ordinary modes. The server
also merges spec MCP/search/file/code/memory and related policies while building
an ephemeral agent. One important exception is artifact mode: the pinned agent
loader reads artifacts from `req.body.ephemeralAgent`, so the browser creates a
public companion object containing `mcp`, `web_search`, `file_search`,
`execute_code`, `memory`, and `artifacts`
(`client/src/utils/endpoints.ts:334-405`; `packages/api/src/agents/load.ts:45-165`;
`api/server/middleware/buildEndpointOption.js:43-116`). Sending only `spec`
therefore does not faithfully execute an artifact-enabled model spec.

The native target mapper now reproduces that exact public companion object for
every visible spec. Missing booleans become `false`, missing MCP becomes `[]`,
and artifact values map exactly as the web does: `true` → `"default"`, a
nonempty string → that string, and absent/false/empty → `""`. Wrong JSON types,
control characters, or unbounded MCP/artifact values quarantine the spec rather
than silently weakening it. The object is carried in `ConversationTarget`, is
encoded under generation `ephemeralAgent`, is restored when a canonical
conversation names a still-visible spec, and participates in the durable
follow-up target fingerprint. Private prompt fields, skills, subagent IDs, and
server execution policy are never reconstructed by the client. Resume remains
server-replayed from the pending action's captured context before endpoint and
fingerprint guards (`api/server/routes/agents/chat.js:30-75`).
Do not turn a hidden or non-menu spec into a native menu item merely because it
appears in a cached response.

Search/tool availability and result rendering are separate contracts. The
exact web-search attachment, file-citation permission, citation marker,
artifact, code-preview, Mermaid, and MCP UI-resource shapes are pinned in
[`CitationsArtifactsAndInteractiveContent.md`](CitationsArtifactsAndInteractiveContent.md).

### Agents, assistants, tools, and generation

| Request family | Auth/authorization | Contract |
| --- | --- | --- |
| `/api/agents` | JWT; system capability plus per-agent ACL | `GET /` list; `POST /` create; `GET /:id` view-safe; `GET /:id/expanded` and versions require edit; `PATCH`, duplicate, delete, revert use edit/delete rights. Categories and avatars are additional routes. | 
| `/api/agents/actions` | JWT; editable agent set | List actions, write/delete an action on an editable agent. The server validates parsed OpenAPI URL vs submitted domain, allowed domains/addresses, encrypts metadata, validates OAuth metadata, and versions the agent. |
| `/api/agents/tools` | JWT/config/permission | `GET /`, `GET /calls`, `GET /:toolId/auth`, and rate-limited `POST /:toolId/call`. This call endpoint is a tool invocation, not a way to grant a tool. |
| `/api/agents/chat`, `/api/agents/chat/:endpoint` | request filters, moderation, agent access, resource view, conversation access | Normal and ephemeral-agent sends. `POST /resume` rebuilds server-captured graph context. Status/stream/abort/steer endpoints are also under this namespace. |
| `/api/assistants/v1/*`, `/api/assistants/v2/*` | JWT, ban check/config | Versioned assistant list/CRUD/chat; tools, documents and actions live below versioned roots. |

Sources: agent routes and ACL levels are at
`api/server/routes/agents/v1.js:18-169`, actions at
`api/server/routes/agents/actions.js:39-208`, tools at
`api/server/routes/agents/tools.js:8-38`, and generation chain at
`api/server/routes/agents/chat.js:38-98`. Assistant version routing is in
`api/server/routes/assistants/index.js:8-18` and CRUD routing in
`api/server/routes/assistants/v1.js:17-112` / `v2.js:10-98`.

For a native composer, a **saved agent** is a resource reference
(`agent_id`/`endpoint: agents`), while an **ephemeral agent** is a turn-local
requested graph. Never hydrate an ephemeral graph merely from a saved agent's
current configuration: version changes and permissions can make it different.
The server deliberately restores resume context before request guards to prevent
a crafted resume from swapping models or tools (`agents/chat.js:38-74`).

### MCP and OAuth

| Request | Auth | Contract |
| --- | --- | --- |
| `GET /api/mcp/servers`, `POST /api/mcp/servers`, `GET/PATCH/DELETE /api/mcp/servers/:serverName` | JWT + MCP use/create or resource permission | Manage the configured MCP registry. |
| `GET /api/mcp/tools`, `GET /api/mcp/connection/status[/:serverName]`, `GET /api/mcp/:serverName/auth-values` | JWT + use permission | Discover tools, connection health, and variables needed for UI—not credentials. |
| `GET /api/mcp/:serverName/oauth/initiate`; `POST .../oauth/bind`; `GET .../callback`; `GET /oauth/status/:flowId`; `POST /oauth/cancel/:serverName` | Initiate/bind/status/cancel require JWT; callback is redirect-based | OAuth flow is stateful and user-bound. Bind sets CSRF/session cookies before browser launch; callback checks state, flow ownership/state freshness and CSRF/session/active flow before token storage and reconnect. |

Sources: route inventory is `api/server/routes/mcp.js:98-1129`; bind/status/token
ownership controls are at `mcp.js:607-727`; callback validation is
`mcp.js:280-408`. The React client maintains per-conversation MCP selection in
ephemeral agent state and strips unconfigured servers (`client/src/hooks/MCP/useMCPSelect.ts:20-114`).

**iOS implementation rule:** launch OAuth in `ASWebAuthenticationSession` (or
equivalent system browser) only after the bind step; correlate callback/status to
the original server profile, account, server name, and flow ID. Treat returned
token material as server-private even if an endpoint can return a completed
flow's result; native UI needs status, never a token display or Keychain copy.

### Personalisation, organization, search, balance, sharing

| Area | Contracts | Source |
| --- | --- | --- |
| Memories | `GET/POST /api/memories`, `PATCH /preferences`, `PATCH/DELETE /:key?agentId=`. CRUD requires distinct Memories permission bits. Responses contain entries plus personal-pool `totalTokens`, `tokenLimit`, `charLimit`, usage %. Agent names are resolved only when the user can view that agent. | `api/server/routes/memories.js:20-117, 132-347` |
| Projects | `GET/POST /api/projects`, `GET/PATCH/DELETE /:projectId`, `PUT /conversations/:conversationId`; all JWT. | `api/server/routes/projects.js:8-24`; React cursor/search list `client/src/data-provider/Projects/queries.ts:10-48` |
| Prompt groups | Group/list/detail/all/random, create/update/delete, prompt membership/labels/production/usage routes; permissioned prompt-group resource. | `api/server/routes/prompts.js:77-553` |
| Skills | `GET/POST /api/skills`, item patch/delete, file list/read/upload/delete, import and states routes; resource permissions also apply. | `api/server/routes/skills.js:299-363` |
| Conversation and message search | `GET /api/search/enable` only reports configured/healthy Meilisearch availability. Actual conversation search is `GET /api/convos?search=…&cursor=…`; message search is `GET /api/messages?search=…`. The shared data-provider's `/api/search?q=` builder is stale at this pinned server baseline and must not be used as a native route contract. | `api/server/routes/search.js:8-25`; `api/server/routes/convos.js:38-73`; `api/server/routes/messages.js:25-105` |
| Balance | `GET /api/balance`, JWT, config is built from app/user balance policy. Streaming also sends per-run token usage. | `api/server/routes/balance.js:1-15`; `client/src/data-provider/Endpoints/queries.ts:15-31` |
| Shared links | Owner lookup is `GET /api/share/link/:conversationId`; publish is `POST /api/share/:conversationId`; refresh/revoke use `PATCH/DELETE /api/share/:shareId`. Anonymous snapshot read is `GET /api/share/:shareId`; files are share-scoped below `/files/:fileId[/preview|/download]`; authenticated fork is non-idempotent `POST /api/share/:shareId/fork` with target index and exact revision. Owner directory, external-link native entry, `/config`, and ACL/public grants remain separate contracts. The protocol permits omitted publication fields, but omission of `snapshotFiles` means enabled on the pinned server when supported; the native owner flow therefore sends `false` unless the user explicitly opts in. | mounts `api/server/index.js:316`; routes `api/server/routes/share.js:283-630`; URL builders `packages/data-provider/src/api-endpoints.ts:67-102`; native boundary [SharingAndPublicSnapshots.md](SharingAndPublicSnapshots.md) |

The native Memory contract, privacy boundary, exact mutation acknowledgements, and live acceptance gates are expanded in [MemoriesAndPersonalization.md](MemoriesAndPersonalization.md).

### Access sharing and permissions

`/api/permissions` is the common ACL surface for `AGENT`, `REMOTE_AGENT`,
`PROMPTGROUP`, `MCPSERVER`, `SKILL`, and `SHARED_LINK`. It offers principal
search, per-resource role choices, fetch/replace resource ACL, and effective
permissions. Reading/mutating an ACL requires resource `SHARE`; enabling public
access additionally requires `SHARE_PUBLIC`. Shared-link ownership cannot be
changed through the general endpoint. See
`api/server/routes/accessPermissions.js:19-195`.

Native should make server responses the only source of truth for availability:
a hidden button is not permission enforcement, and an older cached grant must
not authorize UI after profile/account/tenant changes. Use a read-only/share
viewer that clearly separates public-link state from a signed-in resource share.

## How the React client composes the product

1. `StartupLayout` fetches startup config for auth pages; its startup query uses
   auth-aware keys. `ChatRoute` then fetches models, endpoints, conversation,
   project, assistant map, and agent list after authentication
   (`client/src/routes/Layouts/Startup.tsx:19-76`,
   `client/src/routes/ChatRoute.tsx:45-158`).
2. `ChatRoute` waits for roles and, when appropriate, an agent catalog before
   it resolves defaults or query-selected model specs. It protects a project
   scope from a transient request failure and removes a confirmed-dead project
   from a new-chat URL (`ChatRoute.tsx:58-117, 143-230`).
3. React Query owns server caches (models, endpoints, resources); Recoil/Jotai
   own live conversation and ephemeral agent/MCP selection. Mutations
   invalidate related projects, conversations, and resource details rather
   than trusting an optimistic local authorization state.
4. The agent/spec layer composes endpoint/model settings, saved agent data and
   per-conversation ephemeral settings. The MCP selector synchronizes ephemeral
   state, filters removed servers, and keeps new-chat defaults scoped by spec
   or environment, not globally (`useMCPSelect.ts:20-114`).
5. Artifacts use a separate provider/panel; shared views use the same model in
   a read-only responsive overlay. Sandpack preview is a browser sandbox,
   Mermaid output is sanitised before injection, and tool-generated files have
   explicit download/preview routes (`components/Share/ShareArtifacts.tsx:51-178`,
   `components/Artifacts/ArtifactPreview.tsx:28-64`,
   `hooks/Mermaid/useMermaid.ts:89-147`).

This architecture is not prescriptive for SwiftUI. Its semantic invariants are:
auth-separated startup policy; server-first catalogs and ACLs; explicit
per-conversation configuration ownership; mutation-driven invalidation; and
separate state for raw streaming, tool approval, artifacts, and shared read-only
views.

## Recommended native domain model

Keep the existing `ConversationTarget`, then replace raw feature guessing with
typed, account-scoped policy and resource aggregates:

```swift
struct ServerPolicy {          // authenticated /api/config, lossless extensions
  let interface: InterfacePolicy
  let modelSpecs: ModelSpecPolicy
  let enabled: FeatureFlags
  let balance: BalancePolicy?
  let webSearch: WebSearchPolicy?
}
struct ChatConfiguration {     // persisted per conversation / draft
  let target: ConversationTarget
  var modelSettings: [String: JSONValue]
  var presetID: String?
  var projectID: ProjectID?
  var isTemporary: Bool
}
struct EphemeralAgentConfiguration {
  var mcpServers: [String]
  var webSearch: Bool; var fileSearch: Bool; var executeCode: Bool; var memory: Bool
  var artifacts: ArtifactMode
}
struct ResourceAccess { let bits: PermissionBits; let role: ResourceRole? }
```

Use typed models for stable fields, but retain lossless `JSONValue` extensions
for independently evolving config and provider parameters. Scope every cache
key and persisted draft by server profile, authenticated account, and tenant
where applicable. Split repositories by concern: `DiscoveryRepository`,
`AgentRepository`, `MCPRepository`, `PersonalizationRepository`,
`SharingRepository`, and `ArtifactRepository`; this prevents basic chat from
implicitly gaining authority to manage keys, sharing, or OAuth.

## UX semantics to preserve

* A target picker must communicate whether the user selected a model, preset,
  saved agent, or policy-defined spec. `enforce` means there is no free-form
  model picker.
* Show a persistent but compact configuration summary in the composer: target,
  project, temporary mode, active MCP servers, and tool/search/code/artifact
  status. Disabled/unauthorized choices should explain that the server policy
  or role disallows them.
* Agent and tool steps are not ordinary assistant prose. Render progress,
  tool input/result summaries, auth-needed, approval/ask-user, restart/retry,
  and token usage as structured state. Keep the existing approval interaction.
* `isTemporary` means privacy/retention semantics; it should be visible before
  sending and never be silently lost when changing targets.
* Shared links are a different viewer mode: clear public/private state, link
  owner controls, read-only content, and file access scoped to that link.
* Artifacts should be an attachment-like inspection surface. On iOS, prefer
  native text/code/PDF/image/Office preview and export; use a tightly controlled
  `WKWebView` only for HTML/interactive previews and do not equate it with code
  execution.

## Security constraints

1. **Never promote anonymous config.** Re-fetch `/api/config` after login and
   discard auth-scoped config on logout/profile/account/tenant change.
2. **Server authorization wins.** All resource operations may be denied after
   discovery. Handle 401/403/404 without revealing resource metadata, and do
   not use UI visibility as access control.
3. **OAuth is a browser-bound flow.** Preserve CSRF/state/flow ownership and
   callback verification. Do not parse, log, sync, display, or retain returned
   OAuth secrets locally.
4. **Tools/actions/MCP are remote authority.** Never invoke an action URL or
   MCP tool directly from iOS. The LibreChat server performs allow-list,
   OpenAPI/domain, credential, rate-limit and ACL checks.
5. **Untrusted content requires containment.** Tool results, SVG/Mermaid,
   HTML artifacts and downloadable files are untrusted. Disable arbitrary JS
   bridges/navigation in previews, validate allowed origins, and make downloads
   explicit user actions. Server code execution is not device code execution.
6. **Memory/prompt/skill data is private data.** Respect per-resource ACLs,
   user opt-out, agent partitioning, content limits, and secure local cache
   erasure on sign-out.
7. **Resumable generation must preserve graph identity.** On a resume/reconnect,
   use the server-issued handle/context; never resend altered tools/model/agent
   parameters in an attempt to recreate a paused run.

## Prioritized iOS gap matrix and delivery path

| Priority | Gap | Safe delivery slice | Acceptance criterion |
| --- | --- | --- | --- |
| P0 hardening/live gate | Authenticated policy provenance, endpoint/role/speech composition, fail-closed failure handling, and explicit retry are implemented, but the full interface/model-spec envelope is still permissive JSON. | Continue toward a typed/lossless `ServerPolicy`, then live-prove failure/retry, role changes, and account/profile isolation. | Anonymous config never enables post-login features; endpoint/role evidence is account-bound; failed refresh hides gated surfaces; 401 signs out; every remaining policy field is typed before it controls UI. |
| P0 live gate | Model-spec catalog/default validation and the exact browser companion request are implemented; user-controlled per-conversation ephemeral overrides are not. | Live-prove enforced/non-enforced specs, artifact mode, MCP/search/code/memory defaults, config changes, and restored conversations before adding user toggles. | A selected spec sends the exact public companion fields, malformed policy is unavailable, private fields remain server-owned, and a changed companion fingerprint cannot silently drain an older queued turn. |
| P0 live gate | A shared endpoint policy is implemented across catalog mapping, generation admission, queue fingerprints, composer state, and upload staging. It allows pinned built-in families, requires authenticated `type: custom` evidence for arbitrary custom names, rejects Assistant protocols and exact `abort`/`resume`/`steer` control-route collisions, and serializes a permitted endpoint as one URL path component. | Live-prove custom endpoint typing and negative reserved/unknown/Assistants cases across representative self-hosted deployments. | Unsupported endpoints remain read-only and never produce generation or upload traffic; a legitimate custom name with spaces/punctuation reaches exactly one encoded route component. |
| P1 | Read-only Agents and compatible Preset application plus bounded safe creation exist, but assistants, broader agent/preset management, and full preset execution remain incomplete; bounded Projects and Memory still lack authenticated live/accessibility acceptance. | Live-accept Projects/Agents/Memory/Presets, then add each mutation or execution field only with its exact ACL, ambiguity, and provider-wire contract. | Presets never cross accounts, mutate existing histories, select fallback targets, repost an uncertain create, or claim unsupported parameters; Project and Agent authorization changes fail closed. |
| P1 | Read-only MCP list/status is implemented and compile-verified, but selection, tools/actions, auth-value entry, management, and OAuth remain absent. | Live-accept the no-cache redacted catalog first; then add explicit per-conversation selection and a reviewed `ASWebAuthenticationSession` OAuth state machine only after account/server/flow binding is complete. | Unknown states never authorize; no URL/header/custom-variable/credential/OAuth token reaches logs, UI, cache, or Keychain; reconnect state is account/server-bound. |
| P1 | Owner management, an owner-reachable public snapshot preview, and direct-path fork are implemented but not live-proven; branch-inclusive fork modes, external universal-link/standalone anonymous entry, directory, and ACL/public controls are absent. | Complete authenticated owner/snapshot/file and direct-path fork acceptance, including preflight, ambiguity, and cache-after-success outcomes. Then implement `includeBranches`/`targetLevel`/`splitAtTarget` only with explicit contract proof, followed by secure external-link routing and ACL/directory administration. | Capability never substitutes for authorization; public/private snapshots never fall back to account file routes or enter authoritative conversation cache. |
| P2 | Prompt read/insert and owned metadata/version management are bounded and build-tested; delete, labels, sharing/ACL administration, skills, balance, and broader artifact/Mermaid previews remain absent, while search still needs live/accessibility hardening. | Live-accept prompt role/resource ACL and ambiguity behavior before adding destructive or sharing controls; add other capability-gated resources only after their privacy contracts. | Feature flags and role/resource ACL evidence gate entry points; prompt mutations never blind-retry; untrusted content cannot auto-send or escape its origin policy. |
| P1 | Exact web/file-search attachments and citation markers are not decoded or resolved. | Add provenance-preserving attachment DTOs, literal/Unicode citation parsing, authorized source/file views, and replay upsert. | Highlight re-emission does not duplicate results; all six reference types survive cache restore; conversation-search health never enables the web-search tool. |
| P2 | Semantic tool/file mapping now includes artifact directives and generated-file pending/ready/failed upsert, but still lacks Mermaid rendering/export, full sandbox previews, and MCP UI-resource references. | Add document-order artifact parsing/edit conflict handling, stable diagram IDs, constrained Mermaid/code rendering, and a sandboxed UI-resource renderer. | Nested fences, stale edits, terminal preview replay, live authorized generated-file download, cross-turn `\ui{}` references, denied navigation, and unknown types are fixture-tested before live acceptance. |

Recommended implementation order is: (1) authenticated discovery/policy and
target correctness, (2) live saved-agent/spec/ephemeral-agent send correctness, (3)
authenticated live/accessibility hardening for bounded Projects, shared-link ownership, and the live Preset library, (4) MCP/OAuth/tools and public/ACL sharing breadth,
then (5) authoring, artifacts and rich previews. Each phase should use contract
fixtures captured from this exact server revision and test anonymous versus
authenticated config cache separation.

## Current iOS source references

* Capability detection now records authenticated-policy provenance and fails
  account-gated features closed when that refresh fails. The repository also
  joins authenticated endpoint, current-role, and speech evidence; remaining
  interface/model-spec fields are still permissive JSON:
  `Packages/LibreChatCore/Sources/LibreChatProtocol/Capabilities.swift` and
  `LibreChat/Data/Repositories/LibreChatRepository.swift`.
* Target mapping combines endpoint/model responses with `modelSpecs`, honors
  `enforce`, validates the browser-compatible model-spec companion policy, and
  applies the same domain endpoint route policy used by chat, queue, composer,
  and upload admission. Generation serializes the companion object and durable
  follow-ups include it in their exact routing fingerprint:
  `LibreChatProtocol/TargetCatalog.swift` and
  `LibreChatDomain/GenerationEndpoints.swift`.
* Provider-credential discovery and exact OpenAI/custom/Azure/Google/Bedrock
  envelopes are in `LibreChatDomain/UserKeys.swift` and
  `LibreChatProtocol/UserKeys.swift`. The repository exposes live expiry-only
  status, no-retry writes, ambiguity reconciliation, and shared Azure-slot
  target evidence; the SwiftUI editor retains no secret-bearing model state.
* Saved-agent browse and bounded management contracts are in
  `LibreChatDomain/Agents.swift`, `LibreChatProtocol/Agents.swift`, and
  `LibreChatProtocol/Roles.swift`. `LibreChatRepository` performs exact
  expanded preflight, metadata-only PATCH reconciliation, and one-shot server
  duplication; `Features/Agents/` owns item-identified editor/confirmation
  sheets without retaining expanded configuration. The privacy and acceptance
  boundary is documented in [SavedAgentManagement.md](SavedAgentManagement.md).
* `StartupConfigDTO` currently retains the sharing flags but still only a small
  subset of the complete authenticated policy envelope:
  `Packages/LibreChatCore/Sources/LibreChatProtocol/DTOs.swift`.
* Repository discovery chooses anonymous or bearer authorization explicitly;
  sign-in/session activation invokes the authenticated form before sharing is
  exposed: `LibreChat/Data/Repositories/LibreChatRepository.swift:51-79`.
* Generation sends v2 through deployment-subpath-safe URL components, carries
  target IDs/spec, rejects Assistant/unknown/reserved route families, and
  accepts arbitrary custom names only with authenticated custom-type evidence:
  `LibreChatRepository.swift:2101-2173`.
* The app already persists/reconnects generation and models tool approvals/
  usage in its domain: `Packages/LibreChatCore/Sources/LibreChatDomain/Generation.swift:43-181`.
* Bounded Projects uses `LibreChatDomain/Projects.swift`, the exact request
  builders in `LibreChatProtocol/Projects.swift`, repository methods in
  `LibreChatRepository.swift`, and native models/views under
  `LibreChat/Features/Projects/`. This is fixture/simulator evidence; no
  authenticated live Projects flow has been captured.
* Shared-link owner contracts are in `LibreChatDomain/SharedLinks.swift` and
  `LibreChatProtocol/SharedLinks.swift`; public snapshot/fork contracts are in
  the corresponding `SharedSnapshots.swift` files. Repository integration is
  in `LibreChatRepository.swift`, and the owner plus bounded preview/fork UI is
  under `LibreChat/Features/Sharing/`. External universal-link/standalone entry,
  owner directory, and ACL/public administration are not implemented.
* The SwiftUI chat surface is currently a basic message list/composer with
  uploads and approval widget: `LibreChat/Features/Chat/ChatView.swift:64-225`.
