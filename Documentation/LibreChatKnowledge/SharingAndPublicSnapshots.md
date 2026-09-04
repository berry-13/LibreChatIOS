# Shared links and public snapshots

**Pinned server:** LibreChat commit `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native status:** authenticated owner lifecycle plus signed-in and signed-out paste/share-ID entry and owner-reachable public snapshot preview are implemented and fixture/build tested. Direct-path conversation fork is documented in `ConversationsMessagesAndFiles.md`; shared-link fork remains a separate pending contract. Universal-link entitlement/onOpenURL, authenticated/live acceptance, and administrative surfaces remain pending  
**Latest verification:** 350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks) passed at [`/private/tmp/librechat-visual-audit-core`](/private/tmp/librechat-visual-audit-core). The complete app unit/model/repository target previously passed **371/371** on iPhone 17 Pro, iOS 26.5, at [`/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`](/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult); generic Simulator and iOS 17 device builds also passed at [`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`](/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived) and [`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`](/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived). Forty-six newer app/model/repository tests compile but have not executed. The 7/7 executed deterministic UI suite does not exercise sharing; the two compile-only Temporary Chat/Files flows do not alter that boundary. No live owner/snapshot network acceptance was performed, so this evidence does not promote sharing to authenticated/live acceptance.

The exact test build was installed, launched, and captured at the saved-server login screen in [`/tmp/librechat-ios-public-snapshot-runtime.png`](/tmp/librechat-ios-public-snapshot-runtime.png). That proves startup smoke only. No authenticated owner operation, anonymous snapshot read, shared-file access, direct-path fork, or shared-link fork was exercised against the live deployment.

Focused hardening verification is recorded as **4/4 iOS tests** in [`/tmp/LibreChatIOS-SharedSnapshotHardening2.xcresult`](/tmp/LibreChatIOS-SharedSnapshotHardening2.xcresult). Focused profile-selection race coverage passed in [`/tmp/LibreChatIOS-AppModelSelectionFocused7.xcresult`](/tmp/LibreChatIOS-AppModelSelectionFocused7.xcresult), and mutation ambiguity coverage passed 10/10 in [`/tmp/LibreChatIOS-ConversationMutationAmbiguityFocused2.xcresult`](/tmp/LibreChatIOS-ConversationMutationAmbiguityFocused2.xcresult). These are historical focused artifacts alongside the current full-suite result above.

## Scope and terminology

LibreChat sharing has at least four distinct surfaces:

1. **Authenticated owner lifecycle** — inspect whether one conversation has a shared link, publish or refresh its stored snapshot, distribute its URL, and revoke it.
2. **Public/scope-checked snapshot resource** — load pseudonymized messages through a share ID and resolve only share-scoped files.
3. **Authenticated derivative action** — fork a chosen snapshot boundary into the viewer's account.
4. **Entry and administration** — open external/universal links, navigate anonymously outside the owner flow, list owned links, and manage ACL/public grants.

The current native slice implements the owner lifecycle and public/scope-checked snapshot read within a deliberately bounded flow, plus a separate direct-path conversation fork over the owned-conversation API. A signed-out or signed-in user can explicitly paste a same-server shared URL or share ID into the entry screen, and the owner sheet can navigate to a native read-only preview of that stored snapshot. System `ShareLink` still distributes a URL. The shared-link derivative fork remains a separate pending contract; the app does not yet claim universal-link entitlement/onOpenURL delivery, list all owned links, or grant/edit ACL/public permissions.

Two server identifiers must remain separate:

- `_id` is the shared-link resource identifier used by the permission/ACL system.
- `shareId` is the URL-safe public identifier used in `/share/:shareId` and owner update/revoke routes.

`SharedLinkID` models only `shareId`. The optional resource `_id` is retained separately and must never be placed into the public URL. Public snapshot payloads also use strict `SharedConversationID`, `SharedMessageID`, and `SharedFileID` types; these cannot be silently substituted for canonical authenticated conversation, message, or file IDs.

## Authenticated capability discovery

The three relevant fields are post-login configuration evidence:

| Authenticated `/api/config` field | Meaning for native UI |
|---|---|
| `sharedLinksEnabled` | Owner shared-link lifecycle may be offered, subject to the authenticated route's authorization result. |
| `publicSharedLinksEnabled` | Server policy permits public-link behavior. Detection does not mean native public/ACL management exists. |
| `sharedLinksSnapshotFilesEnabled` | Server policy permits shared file snapshots. The native owner UI may expose its explicit file opt-in only when this authenticated value maps to `supportsSharedLinkFileSnapshots == true`; snapshot file access still uses only share-scoped paths and remains subject to the snapshot route's authority. |

The app now refreshes capabilities with bearer authentication after login and maps these values into `ServerCapabilities`. Anonymous startup configuration must not enable the Chat share control or file opt-in. The share entry is available only for a server-backed conversation while online and when authenticated capability evidence advertises owner sharing; it is unavailable during generation. Capability evidence is feature-level gating, not authorization: every owner request still goes to the server, and its 401/403/404 result is authoritative.

Source evidence: `api/server/routes/config.js:27-31,130-151,270-289`. The pinned server intentionally appends the sharing flags only in the authenticated payload.

## Exact owner lifecycle contract

All API paths are relative to the configured deployment base URL. The URL builder must therefore preserve reverse-proxy/deployment subpaths.

| Operation | Exact request | Important response/behavior | Native behavior |
|---|---|---|---|
| Lookup by conversation | `GET /api/share/link/:conversationId` | `{ success:false, shareId:null, conversationId }` means no link. A live result includes `_id`, `shareId`, `conversationId`, optional `targetMessageId`, and optional `snapshotFiles`. | Idempotent lookup; maps absent and live states without conflating identifiers. |
| Publish snapshot | `POST /api/share/:conversationId` | Optional protocol fields are `targetMessageId` and `snapshotFiles`; omission of `snapshotFiles` currently defaults to file inclusion when server file snapshots are enabled. | Owner flow explicitly sends `snapshotFiles:false` by default and never blindly retries. A capability-gated user opt-in may send `true`. A `409` triggers authoritative lookup because another client may have created the link. A `403` produces a role-permission explanation. |
| Refresh snapshot | `PATCH /api/share/:shareId` | Re-publishes through the requested target while retaining the same `shareId`; requires the server's create/share authorization. | Sends the explicit owner file choice and never blindly retries. A `404` clears the known-dead link and URL instead of preserving stale state. A `403` retains the current link but explains the active role cannot create/update shared links. |
| Revoke | `DELETE /api/share/:shareId` | Deletes the link and associated server-managed snapshot/permissions. | Requires confirmation and never blindly retries. A confirmed revoke followed by `404` is treated as authoritative already-absent state. |

`SharedLinkPublishRequest` remains a general protocol type and uses `encodeIfPresent`, so a caller can intentionally preserve a server default. The privacy-sensitive native owner flow does not do that for files: the pinned server interprets an omitted `snapshotFiles` as enabled whenever file snapshots are enabled. Owner create and refresh therefore send `snapshotFiles:false` unless the user explicitly enables **Include attached files**. That toggle is rendered only when the bearer-authenticated capability refresh reports `supportsSharedLinkFileSnapshots == true`; otherwise the sheet says files will not be included and still sends `false`.

Pinned source evidence: owner routes and validation are in `api/server/routes/share.js:475-630`; endpoint builders are in `packages/data-provider/src/api-endpoints.ts:67-102`. Native request/DTO code is in `Packages/LibreChatCore/Sources/LibreChatProtocol/SharedLinks.swift`; stable models and repository protocol are in `LibreChatDomain/SharedLinks.swift`, `Identifiers.swift`, and `Repositories.swift`.

## Implemented native owner experience

The Chat toolbar opens an owner sheet for a persisted, nonlocal conversation only when the app is online and authenticated capability discovery advertises shared links. The control is disabled while a response is streaming.

The sheet supports:

- authoritative link lookup;
- creation through the current last message;
- explicit exclusion of attached-file snapshots by default;
- an **Include attached files** opt-in only when authenticated capability evidence advertises file snapshots;
- URL construction that preserves a deployment subpath, such as `https://host.example/librechat/share/:shareId`;
- system `ShareLink` distribution;
- a confirmation before refreshing the stored snapshot through the latest message;
- a confirmation before revocation;
- explicit disclosure that the snapshot is stored, not a live mirror of future messages;
- privacy-focused file inclusion disclosure in the create and refresh confirmation paths;
- stale URL/state removal when refresh returns `404`;
- a specific `403` explanation that the active LibreChat role cannot create or update shared links;
- loading, retry, operation-error, and unauthorized-session handling.

The native owner model deliberately does not place public snapshot messages into the authoritative conversation cache. The public representation may contain pseudonymous identities and is a distinct server resource.

## Implemented public snapshot boundary; shared-link fork separate

The owner sheet exposes **Preview published snapshot**, which pushes a native, read-only snapshot view. That path is app-wired and fixture/simulator tested; it is not evidence that the app can yet open an externally received share URL.

| Surface | Exact request | Native behavior |
|---|---|---|
| Snapshot read | Anonymous `GET /api/share/:shareId` | Sends no bearer authorization. Permissive DTOs map into strict shared-resource IDs and reject missing/mismatched identities. The result remains ephemeral view state and never enters the profile/account canonical conversation cache. |
| Shared file inline/preview/download | `GET /api/share/:shareId/files/:fileId`, `/preview`, `/download` | `SharedFileAccess` derives all paths from the share ID plus `SharedFileID`; owner-private file paths from the payload are ignored. The preview provides share-scoped file links and never falls back to authenticated `/api/files` routes. |
| Fork snapshot | Authenticated `POST /api/share/:shareId/fork` with `targetMessageIndex` and exact snapshot revision | Separate shared-link contract; native direct-path fork over `POST /api/convos/fork` does not implement this surface. Do not conflate the two fork types or claim shared-link fork integration. |

`SharedSnapshotRepository` is intentionally separate from the normal conversation repository boundary. The anonymous snapshot model is not an owned conversation; shared-link fork integration and any canonical shared-snapshot fork result crossing into normal history remain separate. Direct-path conversation fork is covered by the conversation repository boundary.

Native source evidence: stable shared types are in `Packages/LibreChatCore/Sources/LibreChatDomain/SharedSnapshots.swift` and `Identifiers.swift`; anonymous/fork request factories and DTO mapping are in `LibreChatProtocol/SharedSnapshots.swift`; repository/cache integration is in `LibreChat/Data/Repositories/LibreChatRepository.swift`; owner-reachable UI is in `LibreChat/Features/Sharing/SharedSnapshotView.swift` and `SharedLinkOwnerView.swift`.

## Remaining public-entry and administrative contracts

The following pinned surfaces remain future work or are only partially represented:

| Surface | Pinned route | Current native status |
|---|---|---|
| Owner link directory | `GET /api/share` with cursor/search/sort | Unimplemented. |
| Public/scope-checked config | `GET /api/share/:shareId/config` | Unimplemented. |
| External link / standalone anonymous entry | public `/share/:shareId` URL or future universal-link routing into the native snapshot surface | Explicit signed-out and signed-in paste/share-ID entry is implemented. Universal-link entitlement and `onOpenURL` routing remain pending; system-distributed URLs are not yet claimed to open natively. |
| Public/scope-checked snapshot | `GET /api/share/:shareId` | Implemented only behind the owner-reachable native preview; anonymous standalone entry and live acceptance remain pending. |
| Shared file inline/preview/download | `GET /api/share/:shareId/files/:fileId`, `/preview`, `/download` | Share-scoped path modeling and preview links are implemented; live bytes/preview behavior and a fuller native download experience remain unproven. |
| Fork snapshot | `POST /api/share/:shareId/fork` | Separate shared-link fork contract; direct-path `/api/convos/fork` implementation does not promote this surface. Exact revision/index, conflict, and identity behavior remain pending here. |
| ACL/public grant management | `/api/permissions` for `SHARED_LINK` plus public-share policy | Unimplemented; detecting `publicSharedLinksEnabled` must not expose an ACL editor. |

The server's public reads use optional authentication plus `canAccessSharedLink`, return private/no-store responses, and scope file access to the share. The native implementation preserves that authority boundary: it never falls back to owner `/api/files` routes or merges the snapshot into normal cached history. Shared-link fork remains a documented separate server mutation; it is not the direct-path conversation fork.

## Reliability and security invariants

- Owner operations require the active authenticated profile/account and must follow normal 401 sign-out handling.
- Authenticated capability flags are feature-level availability hints, not authorization; 401/403/404/409 remain authoritative.
- Share URLs are derived from the configured server base URL plus `share/:shareId`; deployment subpaths are preserved.
- No prompt, message body, file content, cookie, token, or share payload belongs in logs.
- Create/update/delete are not automatically retried. Create ambiguity is resolved by owner lookup, not a second publication.
- Owner create/refresh explicitly send `snapshotFiles:false` by default because omission means enabled on the pinned server when file snapshots are available. Only a visible authenticated-capability-gated user opt-in can send `true`.
- PATCH `404` removes the stale local link/URL. PATCH/POST `403` explains role permission rather than claiming the feature is unavailable globally.
- A refresh keeps the same `shareId`; it is not a rotate-link operation.
- Requested and response share IDs are validated for equality before a snapshot is installed or forked; share IDs are path-safe opaque identifiers and traversal/separator input is rejected.
- Inline image/video/audio media is resolved only relative to the configured server base and share-scoped paths; owner-relative/private paths are sanitized rather than followed. VoiceOver keeps message children contained so inline media/file links do not escape their message boundary.
- Shared-link fork integration must require a response-provided revision. Missing revision, canonical fork identity mismatch, or transport ambiguity must fail closed; transport ambiguity must block a blind repeat. The direct-path `/api/convos/fork` result is a separate native slice and is not covered by this shared-link contract.
- Snapshot reloads are fenced by a load epoch, so a stale response cannot overwrite a newer reload or post-conflict state. `403` fork responses retain read-only access with a permission explanation; `404` read/fork responses clear the snapshot and report it unavailable.
- External-link entry, owner-directory, ACL/admin, and shared-link fork controls remain hidden until their exact contracts and permissions are implemented. The bounded preview surface must not be generalized into those capabilities.

## Acceptance still required

Fixture and simulator coverage proves DTO mapping, requested-vs-response share-ID validation, missing-field and identifier-mismatch failure, path-safe IDs, the general owner request type's optional-field omission, exact methods/paths/retry policies, authenticated capability refresh, signed-out/signed-in paste entry, privacy-default `snapshotFiles:false`, capability-gated file opt-in, owner-relative inline-media sanitization, 403 role guidance/read-only behavior, PATCH-404 stale-state clearing, stale reload fencing, owner create-409 reconciliation, deployment-subpath URL construction, anonymous no-bearer snapshot read, strict shared identities, derived share-scoped file paths, contained VoiceOver child links, snapshot non-caching, and the owner/preview UI path. Shared-link fork revision/index/conflict/identity integration remains a follow-up slice; direct-path fork has separate compile-only coverage documented in the conversation contract. Promotion to live-proven requires:

1. authenticated lookup → create → external read → refresh same URL → external reread → revoke → external denial;
2. 401/403/404/409 and permission-revocation runs against the pinned deployment;
3. snapshot target boundaries, default file exclusion, explicit opt-in, capability-disabled UI, and real share-scoped file behavior;
4. two profiles/accounts on the same host proving no shared-link state crosses identity boundaries;
5. reverse-proxy subpath verification on the real deployment;
6. VoiceOver, Dynamic Type, confirmation focus return, Reduce Motion, and system share-sheet acceptance;
7. universal-link entitlement/`onOpenURL` and standalone anonymous navigation before describing the native reader as externally reachable; and
8. separate future implementation and acceptance for owner directory and public/ACL/admin management.

Passing 68 core tests and 55 iOS tests does not satisfy these authenticated or anonymous live gates.
