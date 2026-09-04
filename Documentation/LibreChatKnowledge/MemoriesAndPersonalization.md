# Memories and personalization

This document records the pinned LibreChat Memory contract and the native iOS safety boundary. It is based on the detached LibreChat source at commit `b2128a7d189ac020ebb6e49a57ee986e98326b77`; the clone is research evidence, not an app dependency.

Memory values are private server-owned account data. The native app deliberately treats them differently from conversation cache: values are loaded on demand for the active authenticated account, held in memory while the feature is open, and discarded when access becomes unauthorized or offline. They are not written to SwiftData, configuration snapshots, logs, analytics, notifications, or crash breadcrumbs.

## Capability and authorization boundary

The surface is available only when all of the following are true:

1. authenticated capability discovery advertises Memory support;
2. the active role exposes both `MEMORIES/USE` and `MEMORIES/READ`;
3. the active profile/account runtime is online; and
4. the repository belongs to that exact selected profile/account.

Individual actions require additional role bits:

| Action | Required evidence |
| --- | --- |
| Read/list | `USE` + `READ` |
| Create | `USE` + `CREATE` |
| Update/rename | `USE` + `UPDATE` |
| Delete | `USE` + `UPDATE` |
| Change opt-out preference | `USE` + `OPT_OUT` |

Delete deliberately uses UPDATE at this pinned server baseline. The client must not substitute a conventional DELETE bit. UI capability checks are only presentation gates; the server remains authoritative and a later 401/403 must still be handled.

Source: `api/server/routes/memories.js:20-57` and the role response mapping under `api/server/routes/roles.js` / the data-provider permission schemas.

## Wire contract

All routes require bearer authentication.

### List

```text
GET /api/memories
```

Response:

```json
{
  "memories": [
    {
      "key": "timezone",
      "value": "Europe/Rome",
      "updated_at": "2026-08-18T12:00:00.000Z",
      "tokenCount": 4,
      "agentId": null,
      "agentName": null
    }
  ],
  "totalTokens": 4,
  "tokenLimit": 2000,
  "charLimit": 10000,
  "usagePercentage": 1
}
```

`totalTokens` and `usagePercentage` describe the shared personal pool. The server excludes agent-partitioned rows from that aggregate. `tokenLimit` may be null; `charLimit` falls back to 10,000 server-side. Rows are returned newest-first according to `updated_at`.

The native mapper requires a non-negative `totalTokens`, a positive optional token limit, a positive character limit, and a usage percentage within 0...100 when present. Unknown fields are ignored. Duplicate `(key, agentId)` coordinates are collapsed rather than rendered as two independently mutable rows. A malformed identity fails closed.

Source: `api/server/routes/memories.js:84-125` and `packages/data-provider/src/types/queries.ts:147-157`.

### Create

```text
POST /api/memories
Content-Type: application/json
```

```json
{
  "key": "timezone",
  "value": "Europe/Rome",
  "agentId": "optional-agent-partition"
}
```

Success is HTTP 201 and must explicitly contain:

```json
{
  "created": true,
  "memory": { "key": "timezone", "value": "Europe/Rome" }
}
```

The native app currently creates personal memories only. It can edit or delete an existing agent-partitioned row while preserving its exact partition; it does not invent an agent selector or move a memory across partitions.

### Update or rename

```text
PATCH /api/memories/:existingKey?agentId=:optionalAgentId
Content-Type: application/json
```

```json
{
  "key": "new-key",
  "value": "new value"
}
```

Success must contain `updated: true` plus the updated row. The server implements rename as create-new then delete-old, so a transport failure can be ambiguous. The client therefore never retries automatically and does not optimistically remove the old row. It accepts the response only when the returned key and partition match the requested destination, then refreshes the authoritative list.

Existing server keys are preserved byte-for-byte when constructing the path. New keys and values are trimmed in the request to match server normalization. Path components are encoded exactly once.

### Delete

```text
DELETE /api/memories/:key?agentId=:optionalAgentId
```

Success must explicitly contain:

```json
{ "deleted": true }
```

The mutation is never retried automatically. Missing/false/malformed acknowledgements do not remove local presentation state.

### Preference

```text
PATCH /api/memories/preferences
Content-Type: application/json
```

```json
{ "memories": false }
```

Success must explicitly contain:

```json
{
  "updated": true,
  "preferences": { "memories": false }
}
```

The switch remains server-authoritative: presentation changes only after that exact response. A failed request leaves the previous value visible. The confirmed boolean may be retained with the verified user account; memory rows and values may not.

Source for all mutations: `api/server/routes/memories.js:127-347`.

## Validation and identity

- Identity is `(key, agentId?)`, never key alone.
- New keys are trimmed, non-empty, and limited to 1,000 UTF-16 code units.
- Values are trimmed, non-empty, and limited to the server-provided `charLimit` in UTF-16 code units. Swift uses `value.utf16.count` to match JavaScript `String.length` behavior.
- An agent coordinate must be a safe single path/query identity. The UI never renders the raw ID as a fallback label.
- `agentName` is optional because the server supplies it only if the requester can VIEW that agent. Missing names render as the non-identifying label “Agent-specific.”
- A mutation response must match the requested destination key and agent partition before it can replace visible state.

The server accepts caller-supplied `agentId` and looks up display names only through view-authorized resources. That makes the absence of `agentName` meaningful privacy evidence, not a reason to reveal the underlying ID.

Source: `api/server/routes/memories.js:59-82, 127-347`.

## Retry, ambiguity, and refresh policy

List is idempotent and may use the bounded normal read retry policy. Create, update, delete, and preference changes use `.never` retry.

After an explicit successful mutation acknowledgement, the native model installs the confirmed row/removal/preference and requests a fresh list for usage totals. If that refresh fails transiently, it keeps the confirmed change and reports that usage details could not be refreshed. If it returns 401, all private rows are cleared and the app expires the session. A 403 preserves the prior authoritative state and explains that the role does not permit the action.

There is intentionally no offline mutation queue for memories. Offline mode shows a privacy explanation and exposes no cached values.

## Native presentation contract

The Settings entry appears only for a server that advertises Memory support. An account without read permission sees an unavailable explanation rather than a misleading empty list.

The Memory center uses native `List`, `Form`, `NavigationLink`, searchable filtering, pull-to-refresh, system confirmation dialogs, and a native editor sheet:

- personal and authorized agent-specific groups;
- key/value search performed only over the current in-memory snapshot;
- personal-pool token usage and server limits;
- role-gated preference, create, edit, and delete controls;
- explicit loading, empty, offline, unauthorized, and recoverable failure states;
- no raw resource IDs, credentials, or hidden agent metadata.

Search is local to the live snapshot and does not imply a server search endpoint. Agent-specific rows remain in their existing partition during edits.

## Persistence and lifecycle

Allowed persisted state:

- authenticated user preference `personalization.memories`;
- feature and role capability evidence attached to the server profile;
- no memory content.

Forbidden persisted state:

- memory keys and values;
- agent-memory membership;
- list results or search query;
- editor drafts after the feature leaves memory;
- mutation bodies or errors containing private content.

Unauthorized responses clear the current snapshot before the sign-in transition. Profile/account switching reconstructs the feature with a different repository runtime and no carried rows.

## Current native implementation

- Domain: `LibreChatDomain/Memories.swift`
- Repository boundary: `MemoryRepository`
- Protocol/DTO/request mapping: `LibreChatProtocol/Memories.swift`
- Role/user mapping: `LibreChatProtocol/Roles.swift`, `DTOs.swift`
- Data adapter: `LibreChatRepository` Memory methods
- Presentation: `MemoryCenterModel.swift`, `MemoriesView.swift`, `SettingsView.swift`
- Contract tests: `MemoriesContractTests.swift`
- Executed app/model/wire tests: `MemoryCenterModelTests.swift`

Latest evidence is **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at `/private/tmp/librechat-visual-audit-core`, plus **371/371** complete app unit/model/repository tests on iPhone 17 Pro, iOS 26.5, at `/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`. Generic Simulator/iOS 17 device builds also passed. The separate 7/7 UI suite does not exercise Memory. No authenticated Memory request was made.

## Required live acceptance

Before promoting Memory to live-proven:

1. preserve the green app model/repository result while exercising the authenticated UI flow;
2. load personal and agent-partitioned rows from an authenticated deployment;
3. create, update, rename, delete, and toggle preference;
4. prove duplicate-key 409, missing-row 404, role 403, and session-expiry 401 behavior;
5. lower `charLimit` and `tokenLimit` server-side and verify UI/server parity;
6. change role permissions during a session and verify the surface fails closed after refresh;
7. switch between two accounts on the same host and verify no row crosses the boundary;
8. inspect the SwiftData store, logs, crash breadcrumbs, app-switcher snapshot, and notifications for memory values;
9. verify VoiceOver, largest Dynamic Type, Reduce Transparency, and keyboard navigation on iPad; and
10. terminate/relaunch offline and confirm no prior memory content is visible.

Until those checks pass, the precise claim is: **native Memory management is app-wired and package/app-tested, but not authenticated-live proven.**
