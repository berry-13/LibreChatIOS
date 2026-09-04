# LibreChat source and capability baseline

## Pinned deployment

| Item | Value |
|---|---|
| Server used for integration | `https://chat.berry13.com` |
| Reported commit | `b2128a7d189ac020ebb6e49a57ee986e98326b77` |
| Commit subject | `fix: Preserve Redis Abort Terminal Delivery (#14749)` |
| Audit date | 2026-08-18 |
| Native minimum | iOS 17, Swift 6 complete concurrency |
| Generation client target | LibreChat generation protocol v2 |

The official repository was cloned and checked out detached at the reported commit. Permalinks should use:

```text
https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/<path>#L<line>
```

The temporary clone is a research input, not a build dependency. The iOS project must remain able to build without Node, MongoDB, Redis, or the LibreChat checkout.

## Latest native verification snapshot

The current verification passed **367 Swift Testing tests across 44 suites plus 4 XCTest checks (371 package checks)** with generic physical-device and Simulator build-for-testing passing at [`/private/tmp/LibreChatIOS-SkillManagement-Device-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Device-Derived) and [`/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived). **126 newer app/model/repository tests** compile but have not executed because no Simulator was booted; no UI tests ran and no authenticated live server call occurred. The newest slice adds live-only native account Skill activation with exact whole-map mutation and no-repost reconciliation. This proves the builds, not authenticated Skills/generation, artifact, or other live-provider interaction. Use the [live acceptance runbook](../LiveAcceptanceRunbook.md) for those remaining gates.

The bounded native Preset-create contract treats the broad owner-scoped
`POST /api/presets` upsert as a one-shot safe subset. A caller supplies a UUID,
title, profile/account, reviewed target option, and optional prompt prefix; the
repository refetches the live target catalog and exact-matches the reviewed
option/fingerprint before dispatch. The body contains only the stable native
routing fields and retry is disabled. The current route may return HTTP 201
with a message-only failure envelope, so success requires an exact echoed,
native-representable preset. Post-dispatch uncertainty locks creation pending
one `GET /api/presets` reconciliation; 401 and definite 4xx responses remain
errors. Default/edit/delete/import/export are deliberately outside this slice.
The library and create controls also require fresh authenticated
`interface.presets` evidence: only explicit `true`, or the server's absent-key
default after authenticated config, enables them; anonymous, failed, malformed,
explicit-false, and offline policy fail closed without preset traffic.

The bounded native Agent-create contract is separate from the server's broad
`POST /api/agents` authoring surface. Authenticated-online `AGENTS.USE +
AGENTS.CREATE` evidence is required, and the app refreshes `/api/models` then
exact-matches the reviewed provider/model before dispatch. Its one-shot
allowlisted body is strictly private and basic: it excludes tools, actions,
files, MCP, skills, subagents, credentials, avatar, and sharing/ACL data. Only
a generated-ID/request-echo `201` confirms creation. One owner-scoped GET may
reconcile a post-dispatch ambiguity; otherwise the operation becomes finite
`outcomeUnknown` and is never reposted. A post-response 401 or browser redirect
from this `.never` mutation is not replayed automatically, while GET/idempotent
authentication recovery remains available. Advanced/full authoring remains a
separate future contract.

The native Skills protocol slice is recorded in
[SkillsAndManualInvocation.md](SkillsAndManualInvocation.md). It implements
the authenticated paginated catalog and active-state reads, role plus
`AgentCapabilities.skills` gates, account active defaults, model-spec and
saved-agent scope, duplicate-name quarantine, exact picker cancellation,
max-ten fresh preflight, and `manualSkills`/regeneration replay wiring. Settings
now provides a live-only account catalog and serialized exact whole-map active
state mutation. It accepts only fresh profile/account/role/capability/ACL
evidence and uses one bounded GET reconciliation after ambiguous delivery,
never a second POST. Authoring/files/import, durable pending-selection
persistence, and authenticated live Skills/generation acceptance remain
deferred or unproven.

The account/profile slice consumes only authenticated server truth. `GET /api/user` must return the exact active account, avatar upload obeys fresh `/api/files/config.avatarSizeLimit` when available and treats an explicit zero as disabled, and `allowAccountDeletion` is accepted only from authenticated configuration. Avatar upload and self-deletion are one-shot `.never` mutations. Avatar success and ambiguity reconcile through authoritative `GET /api/user`; state/cache commits only for that proven account, signed-URL query parameters do not define identity, and profile/selection epochs fence stale upload/reconciliation results. An unresolved avatar outcome stays finite and is never replayed. Only the pinned `User deleted` acknowledgement purges the exact account namespace and signs out; an ambiguous destructive outcome is locked rather than reposted. The profile UI keeps name, username, email, password, and role read-only because the pinned server exposes no self-service identity-edit mutation. Exact behavior and live gaps are recorded in [AccountProfileAndDeletion.md](AccountProfileAndDeletion.md).

The first native MCP surface is intentionally narrower than the route inventory below. It reads only the permission-gated server catalog and aggregate connection status, projects redacted presentation metadata and finite status values, and keeps that catalog out of offline persistence. It does not decode or present server URLs, headers, custom variables, credentials, OAuth tokens, or tool payloads. Selection, tools, auth-value entry, management, and OAuth remain unimplemented until their account-bound security contracts and live behavior are proven.

Child-agent evidence is pinned to `packages/data-provider/src/types/runs.ts:300-328`, `api/server/controllers/agents/callbacks.js:270-319,531-578`, `api/server/controllers/agents/client.js:256-290`, and `packages/api/src/stream/GenerationJobManager.ts:5970-6130,6520-6650`. Those sources prove the live envelope phases, parent-tool correlation, final `subagent_content` attachment, and the important absence of arbitrary child envelopes from resumable replay storage. The native boundary therefore supports finite live child-agent phases and a lossy finalized semantic trace, not a promised lossless child transcript or cross-replica mid-run timeline.

Message feedback is now a first-class typed contract rather than an unmodeled message field. The native client preserves valid historical feedback, offers set/edit/clear only on the selected authoritative finished assistant response, and reconciles outcome-unknown PUTs through a GET rather than reposting. This is package/build evidence only; the deployment's best-effort observability forwarding and the native interaction still require authenticated live and accessibility acceptance. Exact behavior is in [MessageFeedback.md](MessageFeedback.md).

Whole-conversation duplication is now a distinct one-shot mutation rather than an alias for message-level fork. The native client validates the active profile/account, authoritative nonempty source graph, fresh returned conversation/message identities, and remapped response tree around `POST /api/convos/duplicate`; successful results are cached and selected through the visible row overflow menu. Because the pinned route has no idempotency key, transport/5xx/cancellation/malformed-2xx outcomes lock the source until explicit list refresh and are never reposted automatically. This remains package/build evidence only; see [ConversationsMessagesAndFiles.md](ConversationsMessagesAndFiles.md) and the live runbook.

The verified generation read/recovery boundary treats `resumeState.pendingSteers` as the authoritative pending list and ignores the ambiguous legacy wire `steers`. It decodes applied text from nested `part.steer`, maintains separate pending/applied/recoverable collections, accepts only monotonic `preemptRevision` updates, replaces/clears/deduplicates pending state at authoritative sync, and types FINAL/status/abort leftovers. The app-wired mutation boundary sends exact v2 steer/cancel/arm routes with stable `clientSteerId`, full profile/account/conversation/stream/epoch/protocol fences, no automatic retries, finite ambiguity lockout, and authoritative preempt downgrade. Pending chips expose cancel/apply-sooner; durable terminal leftovers remain outside active recovery; a one-shot Guide Response sheet and uncertain-operation lock have executed model/presentation coverage. Missing terminal projections preserve existing local ownership; explicit empty projections clear it. Legacy cached snapshot/sync records decode with safe empty defaults. Phase C adds the V2 SwiftData queue journal/migration plus a bounded drain coordinator with exact completed-signal/authoritative-graph/target/file proof, reserve-before-POST, durable reserve/commit transitions without synthetic handles, ambiguity lock/no repost, and atomic blocking on 4xx/429/conflict/handoff. Its read-only reconciliation step accepts only exact retained v2 stream/epoch/resume-user proof; exact jobless durable user plus one clean assistant transitions to delivered-without-epoch and blocks followers. AppModel invokes this before generation discovery during restoration, foreground, and connectivity recovery. ChatModel exposes enqueue/status/remove for text and completed same-target attachments, transfers/restores queued upload ownership, renews holds, drains one follower after exact completion, blocks unsafe followers, and presents keep/send-next/confirmed-dismiss terminal-leftover choices. File-bearing terminal recovery, quotes, skills, new-chat queueing, background initiation, and authenticated live acceptance remain absent.

The composer presents the effective generation target, attachment count, and selected server as one semantic execution summary. A hydrated model-spec companion adds a second bounded line for its effective web/file search, code execution, Memory, MCP server count, and artifact scope. It never includes the server-owned connector names or named artifact identifier; unknown scope is omitted, while a verified empty companion renders “Tools: None.” When attachment count is zero, the visible summary omits redundant “No attachments” text while the accessibility value still announces it. The draft remains editable when remote generation is unavailable, while sending is capability/offline gated; attachment and send controls have 44-point targets. Package DesignKit coverage executed and the app disclosure regression compile-verified; earlier app/XCUITest envelope assertions executed without the new scope state. Cache initialization exposes typed `healthy`, `ephemeral`, or `degraded(.persistentStoreUnavailable)` state. Persistent-store failure shows a redacted repair notice and falls back to memory without destructive deletion or repair; Clear Cache is disabled in both Settings and the account menu while degraded. A healthy clear truly purges the exact active profile/account namespace without immediately recreating its `AccountRecord`, leaving verified session identity memory-only until ordinary restoration/login persists it again. Full-profile discovery cannot yet purge a child namespace whose ownership records are already entirely orphaned. Terminal/nonterminal classification remains authoritative inside the Codable `GenerationSnapshot`; the shipped V1 `GenerationRecoveryRecord.isTerminal` column is retained only to preserve the deployed model checksum and is updated consistently on writes. Removing it prevents existing stores from entering the V1-to-V2 migration. Active and terminal queries still decode and filter `snapshot.state`.

The authenticated target catalog is now a first-class account-scoped snapshot rather than a UI guess. Each refresh obtains fresh `/api/config`, `/api/endpoints`, and `/api/models` responses, saved-agent permission evidence, and non-secret `/api/keys` availability/expiry evidence before constructing options. `TargetCatalogMapper` applies `modelSpecs.enforce`, `interface.modelSelect`, `modelSpecs.addedEndpoints`, endpoint/model validity, saved-agent ACLs, credential requirements, supported target kinds, ordering, and explicit/default/soft/recent precedence. It also validates and preserves the exact public model-spec companion configuration used by LibreChat's web client (`mcp`, search, file search, code, memory, and artifacts). Generation emits that object under `ephemeralAgent`, canonical visible-spec conversations restore it from the authenticated startup policy, and durable follow-ups include it in the target fingerprint; malformed policy is quarantined. This closes the artifact-mode mismatch caused by sending only `spec`, while private prompt/skill/subagent policy remains server-owned. A failed authenticated policy refresh returns no stale authorization; warnings become compatibility notices. Ordinary/project-scoped New Chat and saved-chat target transitions share a native selector grouped into configured specs, agents, and models, preserving authoritative catalog order. Its local multi-term search uses only safe display metadata and excludes raw agent IDs. A saved-chat selection creates a fresh local conversation, preserves project scope, and leaves current history unchanged; active generation/actions and staged attachments block the transition rather than being abandoned or retargeted. The recent choice is stored as a validated, trimmed option ID under the existing configuration payload and exact profile/account namespace only after successful local-draft creation. Native provider-credential management now refreshes that same authenticated policy, exposes expiry metadata only, writes the exact web-compatible provider envelopes with no automatic retry, and reconciles revocation without ever reading or caching a secret; see [UserProvidedProviderCredentials.md](UserProvidedProviderCredentials.md). This reuses the existing server/account boundary and adds no SwiftData column or migration. Modular multi-chat, assistants, user-controlled ephemeral tool overrides, authenticated provider-key acceptance, and scoped icon loading/rendering remain absent or unproven.

Post-login policy provenance is explicit. Anonymous discovery writes
`authenticatedPolicyVerified == false`; only a successful bearer-authenticated
config refresh marks it true. That refresh joins the separately authenticated
endpoint catalog, current-role permissions, and speech configuration. A
transient failure keeps an otherwise valid session but clears Agents, MCP,
Memory, Prompt, speech, Projects, Bookmarks, and sharing evidence, then exposes
an explicit Settings retry; a retry 401 signs out. This prevents anonymous or
cached feature flags from becoming current authorization. It does not yet turn
the entire interface/model-spec JSON envelope into a typed `ServerPolicy`.

Temporary Chat is now an explicit retention boundary rather than a loose
generation Boolean. Fresh authenticated interface policy and exact
`TEMPORARY_CHAT.USE` role permission jointly gate New Chat. The selected mode
survives target changes and local-to-canonical promotion, and it propagates to
generation and file uploads. Temporary rows stay out of the library, while
conversation/message/draft/generation/HITL/queue/recoverable-steer/upload
recovery content is excluded from or purged out of the exact local namespace.
The active screen discloses both local offline exclusion and bounded server
retention. This is package/build evidence only; full pinned behavior and
remaining live gates are in [TemporaryChat.md](TemporaryChat.md).

The account Files library is a separate live-only owner catalog over exact
authenticated `GET /api/files`. Its mapping drops malformed rows, collapses
identical duplicates, quarantines conflicting duplicate identities, and shows
only finite user-facing type/source/context/status projections. Search, sort,
pull-to-refresh, and safe metadata detail are native; the raw file path, server
source value, IDs, extracted text, and metadata envelopes are never rendered.
Generated-file preview responses require the exact echoed file identity and a
valid pending/ready/failed shape; text is bounded and HTML remains inert. The
active chat immediately polls each distinct visible pending file through one
profile/account-scoped coordinator at 2.5-second cadence, one request per file,
with terminal/scene/navigation/session cancellation and a five-error transient
cap. Authenticated per-file state fans out without overwriting card provenance,
and replayed pending or ambiguous bare SSE updates cannot regress or arbitrarily
retarget terminal cards. Explicit download uses LibreChat's authenticated
proxied byte route, writes directly to a private profile/account cache, and
hands only a local URL to system Share/Save; signed URLs never enter UI state.
No owner catalog is persisted for offline use. A confirmed single-owner-file
delete uses exact `.never`-retry mutation metadata and never trusts the HTTP
acknowledgement: a fresh raw owner catalog must prove the identity absent before
the list changes or detail dismisses. Retained and verification-required states
remain visible. Reattach, bulk cleanup, and agent/assistant unlinking remain
absent as separate authority/ambiguity contracts. The contract and live gates are in
[FileCatalogAndLibrary.md](FileCatalogAndLibrary.md).

Saved agents also have a bounded native library and management surface. It uses `requiredPermission=1`, the server's opaque `after` cursor and server-side name/description search, drops malformed or duplicate IDs, and accepts `GET /api/agents/:id` only when the returned stable ID matches the request. The detail domain intentionally excludes expanded instructions, tools, actions, model parameters, and owner configuration. Starting a chat performs a fresh target-catalog authorization pass; a direct target or one unambiguous configured spec may proceed, while multiple matching specs require explicit selection in New Chat. Fresh role/resource proof additionally enables metadata-only edit, server duplicate, version history/revert, and ACL-proven delete. Historical records are immediately reduced to bounded safe metadata while retaining each raw server array index; malformed entries remain non-restorable placeholders. Revert refetches and exact-matches the selected index, never automatically retries, and treats any ambiguous acknowledgement as outcome unknown because safe metadata cannot prove which hidden configuration is active. This surface is package- and compile-verified, but not authenticated live-proven.

Memory management is a live-only private-data boundary. The app requests the authenticated `/api/memories` snapshot only when both feature evidence and exact READ/USE role permissions allow it, models personal and agent-specific partitions without exposing a raw agent-ID fallback, and gates create/update/delete/preference controls with CREATE/UPDATE/OPT_OUT evidence. Create, update, delete, and preference mutations use the pinned routes with `.never` retry and require explicit, identity-matching acknowledgements; confirmed rows are installed before an opportunistic usage refresh. Server character limits are enforced in JavaScript-equivalent UTF-16 units. Memory values are not written to SwiftData, configuration snapshots, logs, or the offline cache; only the user's memory-enabled preference is retained with the verified account record. This slice has package and executed repository/model/UI tests, but not authenticated live or accessibility evidence.

Prompt handling is also a live-only permission boundary. The composer library requires authenticated `PROMPTS.USE`, lets the server apply prompt-group VIEW ACLs, expands reviewed variables, and appends without sending. A separate Settings manager requires USE+CREATE, lists the owned category, loads exact group/version truth, and supports create, add version, metadata edit, and explicit production promotion. It never auto-promotes a version, caches/logs prompt text, or automatically retries a mutation; ambiguous operations lock or reconcile through GET-only server truth. Delete, labels, sharing, and ACL administration remain absent; see [Prompts and templates](PromptsAndTemplates.md).

Local transcript sharing is intentionally client-only and narrower than LibreChat shared links or a lossless export. The domain formatter receives only the currently projected branch and produces fixed-role Markdown from cleaned visible text. It omits nontext-only rows and never serializes profile/account/message IDs, model or endpoint metadata, attachments, or tool payloads. SwiftUI hands that bounded string to the system share sheet or clipboard; no transcript is cached or uploaded by this feature.

`ChatModel` now treats conversation routing and message history as two authoritative hydration gates. For a server conversation it fetches both before enabling send; uploads require authoritative routing. Cached history remains browsable and the cached/local draft remains editable and persistable after network failure, while send/uploads fail closed. A local draft can send with its explicitly selected target, but after server identity promotion it drops inferred local routing and refetches the canonical conversation plus history before permitting later mutations. Same-ID authoritative installs update navigation/list ownership without pretending to be a promotion. Focused target-catalog and chat-hydration app tests passed in the 371/371 Simulator result; authenticated live proof is pending.

Camera and upload hardening is now native and capability-aware. The composer exposes one attachment menu for Photo Library, full-screen `UIImagePickerController` capture, and Files. Camera availability and authorization are checked before presentation; denied access offers the Settings path, while unavailable/restricted devices retain library selection. Camera and Photo Library images always pass through orientation-normalized, metadata-free JPEG encoding capped at 4096 pixels on the longest side with `.88` quality; arbitrary HEIC/PNG bytes are never relabelled as JPEG. The server's decoded `clientImageResize` policy may apply an additional configured resize/quality step. Dimensioned non-Assistants images use `POST /api/files/images`; Assistants and non-image files use `POST /api/files`. Multipart `file_id` is the client UUID, the acknowledgement must bind it to `temp_file_id`, and the server `file_id` is retained. Lost/5xx/malformed acknowledgements perform one owner-scoped `GET /api/files` reconciliation; unresolved delivery becomes `deliveryUncertain` and blind retry is disabled. The UI offers a user-triggered GET-only Check for this state, never reposting the bytes. Package and app fixtures execute, but live camera, upload, image-detail, and background URLSession proof remain pending.

Native dictation and Read Aloud are separate authenticated capability boundaries. `GET /api/files/speech/config/get` must prove external STT/TTS before the composer exposes the corresponding action. Dictation records temporary mono 16 kHz AAC `.m4a`, uses exact no-retry multipart `POST /api/files/speech/stt`, and inserts the transcript into the editable draft without auto-send. Read Aloud projects finished visible assistant prose into exact no-retry multipart `POST /api/files/speech/tts/manual`, validates MPEG audio in memory, and uses one process-wide foreground recording/playback lease. Authenticated `GET /api/files/speech/tts/voices` feeds a native opaque-ID picker whose Server default/named choice persists only inside the exact profile/account cache namespace and is removed by purge. Lifecycle, content-revision, and operation fences prevent stale draft or playback mutation. No audio, transcript, source text, token, or multipart body is logged or cached. This is package/build evidence only: microphone permission/interruption, M4A/MPEG interoperability, provider responses, audible playback, voice-list/picker runtime, VoiceOver/Dynamic Type, and authenticated live STT/TTS remain unproven; automatic/background/full-duplex voice and captions remain absent. See [SpeechAndVoice.md](SpeechAndVoice.md).

Message search now retains an exact message identity across the navigation boundary. A sequence-fenced focus request can restart for the same result without stacking a duplicate iPhone destination or recreating an unchanged iPad detail. After authoritative history loads, `MessageTree.selections(focusing:)` reconstructs only the matching ancestor path; `ChatView` suspends streaming bottom-follow, waits for the stable message row, then scrolls once and announces a concise result boundary. Foreign, missing, cached-only, or structurally invalid coordinates fail closed and never guess a sibling. The app model tests executed in the 371/371 result. The deterministic XCUITest fixture returned a hit on a nondefault branch and proved that the matched row replaces the default projected tail; live authenticated iPhone/iPad, VoiceOver, Dynamic Type, and pointer behavior remain pending.

`ChatModel` now owns an immutable cached `MessageTree`/`ChatRenderProjection`, rebuilding it only when authoritative messages or branch selection actually changes. Invalid graphs fail closed rather than yielding a speculative projection, and `ChatView` consumes that projection instead of rebuilding the message tree during rendering. This is a code-only rendering-performance improvement with compile-only projection coverage; no runtime trace or performance claim is made.

The latest HITL hardening treats a `GenerationHandle` as an ownership capability, not just coordinates. Repository response, Stop, and stream attachment reject a handle whose profile/account does not match the active runtime before issuing network traffic. A tool/question resume uses `.never` retry policy and accepts only an acknowledgement with `status:"resuming"`, the exact conversation and stream, and the same negotiated protocol; missing or foreign proof is a definite invalid response. Fatal stream errors—including invalid/unauthorized/decoding/conflict/unsupported and non-429 client failures—end that connection without reconnect retry while preserving the handle for explicit recovery. External-auth actions enter domain state only for HTTPS URLs or loopback HTTP, with credentials, fragments, custom schemes, and non-loopback cleartext rejected. Package URL-safety and direct tool-approval body, ownership, and acknowledgement app tests executed; live approval/question/external-auth and race acceptance remains pending.

The first accessibility hardening slice now treats each full generation handle plus authoritative pending-interaction payload as the identity of an actionable pause. A newly introduced or revised approval, question, or external-auth request moves accessibility focus to its native form and emits one privacy-bounded announcement; an unchanged payload is deduplicated, and prompts, tool arguments, URLs, and server identifiers are not repeated in that announcement. Newly set login, registration, password-reset, terms, server-onboarding, and chat errors use the same reset-aware deduplicated native-announcement policy. Root phase transitions disable animation under Reduce Motion, sensitive tool decisions and branch navigation have source-guaranteed 44-point targets, conversation rows retain a 44-point minimum, and target choices expose the selected trait. Semantic app surfaces, composer chrome, and glass buttons now observe Reduce Transparency and replace glass/material/blur with an opaque system background, visible border, or standard bordered button; the app background also removes its blurred decoration. The pure projection/dedup tests executed in the 371/371 app result; focused target-switch and exact-branch UI regressions passed. The final Core suite has 371 checks, and current generic physical-device and Simulator build-for-testing succeeded. Manual VoiceOver focus/speech, Switch Control, accessibility Dynamic Type, Reduce Transparency/contrast visual acceptance, account-deletion confirmation, prompt/preset/agent-management review, keyboard, and iOS 17 runtime interaction remain pending.

The reliability evidence specifically covers the profile-selection epoch fence, unique local draft identity, preservation of older conversations during partial page refresh, compact unavailable-conversation fallback, exact rename/pin/archive routes with archived cursor paging, confirmed deletion behavior, the completed tags/bookmarks slice, and the native citation slice. Citation coverage includes lossless history/live attachment mapping, standard/resumable and Open Responses wrappers, literal/Unicode marker cleanup, safe inline web links, composite source sheets, a deduplicated full source directory, file metadata without unsafe positional linking, unsafe URL rejection, and cleaned accessibility text. Tags/bookmarks cover exact directory CRUD and atomic conversation replacement, raw path encoding, role lookup with fail-closed `BOOKMARKS.USE`, repeated-tag OR filtering, account-menu access, context-menu assignment, cache updates, and offline hidden/disabled mutations. Their mutation requests are not retried automatically and reconcile authoritative state before surfacing ambiguity. These are fixture/simulator guarantees; no authenticated live conversation-management, tags/bookmarks, citation stream/history, or authorized file-preview run is claimed.

The start-outcome and predecessor-handoff safety slice adds an explicit `ChatSendOutcome` boundary: only a `streaming` outcome contains a `GenerationHandle`; `settled`, `aborted`, and `failed` outcomes remain non-attachable and require authoritative history. Local drafts can promote to the canonical conversation ID after a valid receipt, but a transient history failure retains the claimed submission and optimistic state, leaves the editable draft cleared, and never reposts it. Bounded retries reuse the same `clientRequestID`. `expectedPredecessorCreatedAt` is carried through completed/aborted/failed terminal snapshots and never superseded; typed 409 replacement/predecessor-mismatch proof is preserved and never attached. Handoff requires exact active v2 stream/epoch/protocol proof and a different expected predecessor epoch; losing optimistic rows are removed, unsent draft text is restored and persisted, and a terminal/superseded winner never opens SSE. Active reconcile requires exact stream/protocol/non-negative epoch proof, marks a verified different epoch superseded, rejects other missing/mismatched proof before sync, and propagates proof-status 401. This remains package/build evidence only, not live proof.

As of 2026-08-18, the complete core run passed **68/68 tests in 13 suites** using `swift test --package-path Packages/LibreChatCore --scratch-path /tmp/LibreChatCore-PublicSnapshot-Full`, and the complete iOS run passed **55/55 tests** on an iPhone 17 Pro simulator running iOS 26.5. The iOS result bundle is [`/tmp/LibreChatIOS-PublicSnapshotFull.xcresult`](/tmp/LibreChatIOS-PublicSnapshotFull.xcresult). The exact test build was installed, launched, and captured at the saved-server login screen in [`/tmp/librechat-ios-public-snapshot-runtime.png`](/tmp/librechat-ios-public-snapshot-runtime.png); that is startup-smoke evidence only.

An earlier focused conversation-management verification passed **73/73 LibreChatCore tests across 14 suites** and **62/62 iOS Simulator tests** from [`/tmp/LibreChatIOS-ConversationManagementFull.xcresult`](/tmp/LibreChatIOS-ConversationManagementFull.xcresult), alongside **4/4 focused sharing-hardening tests** from [`/tmp/LibreChatIOS-SharedSnapshotHardening2.xcresult`](/tmp/LibreChatIOS-SharedSnapshotHardening2.xcresult). These artifacts are historical comparison evidence only. Authenticated live acceptance and universal-link entry remain pending.

The bounded native Projects slice is fixture- and simulator-tested: project identities and metadata, list options/pages, create/update/delete, nullable conversation assignment, `chatProjectId` conversation mapping, the pinned REST routes, repository methods, browser/detail search/sort/paging, project-scoped New Chat, and assignment/unassignment are implemented. Reliability coverage proves explicit empty-string description clearing, server-equivalent name-only search, stale-pagination fencing, deletion cleanup limited to matching cached memberships, and revision fencing that prevents an obsolete page's 401 from expiring the current session after the query changes. No authenticated live Projects flow was exercised, so live interoperability, permissions, and server error behavior remain acceptance work. The pinned server exposes only project metadata and conversation membership; these results do not support project-owned files, instructions, or sources.

The shared-link owner slice plus an owner-reachable public-snapshot preview are fixture/build-tested. Bearer-authenticated refresh maps `sharedLinksEnabled`, `publicSharedLinksEnabled`, and `sharedLinksSnapshotFilesEnabled`; owner models/DTOs and exact lookup/publish/refresh/revoke requests preserve the privacy-default `snapshotFiles:false`, capability-gated opt-in, 403 role guidance, PATCH-404 stale clearing, create-409 reread, and deployment subpaths. The native preview uses anonymous `GET /api/share/:shareId` with no bearer, strict `SharedConversationID`/`SharedMessageID`/`SharedFileID`, and share-scoped file preview/download paths; the pseudonymous snapshot never enters canonical cache. Direct-path conversation fork now uses `POST /api/convos/fork` behind authoritative source-conversation/message preflight and graph validation, `.never` retry, typed preflight-vs-ambiguous handling, fresh fork identities, unchanged original history, and cache-after-success failure classification. A one-shot native review sheet navigates to the fork only on dismissal when the direct-path result is authoritative. `includeBranches`, `targetLevel`, and `splitAtTarget` remain unimplemented/unproven; no live sharing/fork flow was exercised. External universal-link/standalone anonymous entry, owner directory, public/ACL/admin management remain unimplemented; see [SharingAndPublicSnapshots.md](SharingAndPublicSnapshots.md).

Generation reliability is also tightened in this snapshot. Reconciliation attributes an answer only through the exact `responseMessageId`, with no latest-assistant fallback. Active ambiguous recovery for a deterministic new chat requires exact stream/conversation/epoch/protocol/status proof; an existing-conversation active ambiguity fails closed. Aborted/error outcomes remain terminal rather than completed, malformed/unknown/identity-mismatched start receipts are rejected, and the UI model now depends on the narrow `ChatFeatureRepository`; conflict rollback is simulator-tested. These are fixture/simulator guarantees, not live generation evidence.

## How LibreChat is shaped

LibreChat is not one static REST contract. It is a configurable application whose visible product is assembled from five evidence layers:

1. **Pre-auth startup configuration** — login and registration modes, branding/build metadata, terms/privacy, Turnstile, and tenant-sensitive public configuration.
2. **Authenticated startup configuration** — model specifications, interface switches, feature configurations, balance, upload behavior, web search, sharing, and account-dependent options.
3. **Authenticated endpoint/model discovery** — `/api/endpoints` returns endpoint configuration; `/api/models` returns endpoint-to-model arrays. Neither is safely derivable from build number alone.
4. **Permission- and resource-scoped discovery** — agents, assistants, MCP servers, prompts, skills, memories, projects, actions, keys, and shared resources are additionally filtered by user, role, group, tenant, and resource permissions.
5. **Per-operation protocol negotiation** — generation v2 is negotiated and echoed on start/control/status/stream surfaces. A successful `/api/config` response does not prove resumable generation.

The native compatibility layer must combine those layers into `ServerCapabilities` plus finer feature catalogs. A single `serverVersion >= x` check cannot represent this system.

Generation routing is also a capability boundary. The dynamic
`/api/agents/chat/:endpoint` route shares a namespace with the pinned
`abort`, `resume`, and `steer` control paths, while Assistants use separate
protocols and arbitrary custom endpoint names are trustworthy only when fresh
authenticated endpoint configuration identifies them as `type: custom`.
`GenerationEndpointPolicy` is the single native admission rule used by target
discovery, send, follow-up queue fingerprints, composer availability, and
upload staging. It rejects malformed, unknown, inconsistent, Assistant, and
reserved-control names before mutation; permitted custom names remain one URL
path component. This is package- and compile-verified, not authenticated live
proof.

Generation-control capability is equally granular. The pinned source supports server-backed steer, steer cancel, and steer arm routes when the exact active Agents job negotiates protocol v2; source presence alone does not prove that a live deployment enables them. The native mutation slice now sends those exact routes with stable `clientSteerId`, full-handle/profile/account/epoch fencing, no automatic retries, finite ambiguity lockout, queued/replayed/settled/leftover reconciliation, FIFO exact-handle serialization, and authoritative preempt downgrade. Pending chips and a one-shot Guide Response sheet have executed app coverage. Phase C adds a V2 SwiftData queue journal/migration, text-only enqueue/status/remove UI, lifecycle reconciliation, and exact completed-signal drain coordinator with reserve-before-POST, durable reserve/commit transitions, ambiguity lock/no repost, target/history proof, and terminal leftover decisions; attachments and background initiation remain excluded. The web product's normal after-run queue and interrupt-and-send drain remain client-local orchestration around abort and ordinary generation, not server queue endpoints. Direct-path conversation fork now uses `POST /api/convos/fork` with authoritative source-conversation/message preflight and graph validation, `.never` retry, typed preflight-vs-ambiguous handling, fresh IDs, unchanged original history, cache-after-success failure classification, and one-shot review/navigation on authoritative dismissal. `includeBranches`, `targetLevel`, and `splitAtTarget` remain unimplemented/unproven. Regenerate and safe user/structured-part edit-resubmit are ordinary message-tree generation variants; save-only edit is a separate non-automatically-retried message PUT. Pinned Continue is internally inconsistent/regeneration-like, and legacy assistant-text Save & Submit drops the edit, so both remain blocked. Parallel-agent `/api/messages/branch` remains distinct and unimplemented. The native client implements client-local MessageTree branch projection, save-only message editing with exact raw coordinates and ambiguity reconciliation, guarded text-only user-prompt edit-and-resubmit from the selected persisted single-primary-text user prompt, and bounded response regeneration from a selected persisted finished plain-text assistant that is the direct child of the exact user source. The prompt action requires verified resumable v2 and authoritative idle preflight and creates an ordinary-generation sibling under the exact original parent. Response regeneration requires exact branch/target fingerprint, verified v2 and idle status, exact source/override-parent/preliminary-response coordinates, stable caller identity, original-subtree preservation, exact new-sibling proof, no attachments/skills/quotes/rich/artifact/citation content, no blind repost or losing-handoff attribution, and 401 history hiding. Assistant resubmit, Continue, message deletion, and specialized server branch actions remain unavailable or distinct. See [Steering, queued follow-ups, and branch actions](SteeringQueuesAndBranchActions.md) before mapping any composer action to a capability flag.

## Route mounts at the pinned commit

The application mounts these major surfaces under `api/server/index.js:287-328`:

| Base path | Product responsibility | Authentication shape |
|---|---|---|
| `/oauth` | Browser-oriented provider entry/callbacks | provider/session dependent |
| `/api/auth` | local login, refresh, logout, registration, password reset, 2FA | mixed public/JWT/cookie |
| `/api/user` | current user, terms, verification, account management | mostly JWT |
| `/api/config` | startup/discovery configuration | optional JWT, tenant-aware |
| `/api/endpoints`, `/api/models` | target discovery | JWT |
| `/api/convos`, `/api/messages` | conversation and message records | JWT |
| `/api/agents` | generation v2 control/stream, agents, tools, OpenAI-compatible surfaces | JWT or API key on selected v1 routes |
| `/api/keys` | expiry-only user-key status plus account-scoped save/revoke | JWT; secret values are write-only to clients |
| `/api/assistants` | assistants CRUD and assistant chat variants | JWT |
| `/api/files` | files, images, previews, usage, uploads, speech | JWT and upload middleware |
| `/api/projects` | project CRUD and conversation assignment | JWT |
| `/api/prompts`, `/api/presets`, `/api/skills` | reusable instruction/tool resources | JWT plus capability checks |
| `/api/memories` | user memory and preferences | JWT plus permission/config checks |
| `/api/mcp` | MCP tools, server management, OAuth, auth values/status | JWT plus MCP permission checks |
| `/api/share` | public/private shared links and file snapshots | mixed optional/JWT with share policy |
| `/api/permissions`, `/api/roles` | resource access and role capabilities | JWT/administrative checks |
| `/api/search` | conversation/message search availability probe only; retrieval remains under `/api/convos` and `/api/messages` | JWT |
| `/api/tags` | tag CRUD and conversation assignment | JWT |
| `/api/balance` | account balance/usage configuration | JWT |

The route inventory is intentionally broader than the first native release. Capability gating should let the app grow into these features without letting unavailable navigation leak into the UI.

## Stable native concepts versus server records

| Native domain concept | Server representations that may feed it | Rule |
|---|---|---|
| `ServerProfile` | base URL, tenant host/path, build info, trust policy | profile is an installation/account boundary, not only a hostname |
| `UserAccount` | user `id` or Mongo `_id`, role, tenant metadata | never use email as cache namespace identity |
| `Conversation` | conversation record plus selected model/agent/assistant/spec/project/tags | retain routing fields separately from display title/model label |
| `ChatMessage` | legacy `text`, structured `content`, files/attachments, metadata | preserve unknown content parts without rendering unsafe raw payloads |
| `MessageAttachment` | web/file search result sets, generated files, memory artifacts, MCP UI resources | retain message/tool/run provenance and unknown fields; replay/upsert by the attachment's real identity |
| `ConversationTarget` | endpoint config, model list, model spec, agent, assistant, ephemeral agent | target is a discriminated capability, not a model-name string |
| `GenerationHandle` | stream/conversation id, generation creation epoch, protocol, client request id | all coordinates are required for safe resume/abort/replacement handling |
| `PendingInteraction` | tool approval, ask-user question, external auth/pending action | a paused run remains active and recoverable |
| `Artifact` | tagged message content, artifact update route, code/Mermaid/sandbox output | provenance and version relationship to the message must remain visible |
| `Project` | project metadata and assigned conversations at this pinned revision | preserve membership without inventing project-owned files/instructions/sources |
| `SharedLink` | owner resource `_id`, URL `shareId`, conversation/target boundary, file-snapshot policy | keep ACL resource identity separate from public URL identity; a stored snapshot is not authoritative/live conversation history |
| `SharedConversationSnapshot` | pseudonymous shared conversation/messages/files plus exact server revision | keep shared IDs distinct from canonical IDs; never merge the snapshot into owned cache; only a canonical fork result may enter the active account namespace |

The exact rich-content mechanisms are documented separately in [CitationsArtifactsAndInteractiveContent.md](CitationsArtifactsAndInteractiveContent.md). In particular, conversation/message retrieval search must not be conflated with the `web_search` agent tool.

## Compatibility decisions

### Sending policy

- `.unknown` generation support **allows one negotiated start attempt**.
- an exact echoed v2 enables live/resumable sending;
- an explicit unsupported/mismatched protocol disables sending and leaves browsing available;
- transport failure does not permanently mark a server unsupported;
- a contract mismatch triggers refreshed discovery before degrading.

### Authentication policy

- bearer access tokens remain memory-only;
- refresh semantics remain cookie-backed and profile-isolated;
- browser provider flags do not imply native OAuth support;
- native browser sign-in requires the optional one-time PKCE mobile-code extension;
- invalid refresh/401 hides retained cache; transient transport failure may expose last-verified cache read-only.
- post-login feature controls use authenticated configuration, but configuration is feature-level gating rather than authorization; the implemented sharing slice must not be enabled from anonymous config, and file snapshots remain explicitly off unless authenticated capability permits a user opt-in and the server accepts the request.

### Persistence policy

- every record is namespaced by profile and account;
- partial pages never imply deletion;
- explicit delete/404 or a documented complete synchronization boundary can remove cached records;
- anonymous/shared snapshot data never enters canonical conversation/message cache; the authenticated direct-path fork stores only its server-returned canonical conversation and messages under the active profile/account after cache-after-success classification; branch-inclusive fork modes remain unavailable/unproven;
- streaming text is coalesced in memory and checkpointed periodically, at lifecycle boundaries, and at terminal state;
- logout hides but retains cache, while clear-cache/profile removal purges the namespace.

## Verification ladder

1. DTO and mapper fixtures from the pinned source contract.
2. Parser/reducer fixtures for event ordering, replay, synchronization, and terminal races.
3. `URLProtocol` tests for headers, cookies, retry, and one-refresh behavior.
4. repository/cache tests for namespaces and reconciliation.
5. simulator interaction checks for navigation, state, and accessibility semantics.
6. real deployment checks for auth, generation, disconnect/background/relaunch, pending actions, and uploads.
7. a compatibility run against at least one older/unsupported deployment.
