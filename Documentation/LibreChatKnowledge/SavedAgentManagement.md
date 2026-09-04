# Saved-agent management

**Pinned server:** LibreChat `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native slice:** 2026-08-19

LibreChat saved agents are versioned, permissioned resources whose expanded representation can contain instructions, provider parameters, tools, actions, files, graph edges, and other sensitive configuration. The native app therefore keeps browsing, bounded management, a deliberately small private-create path, deletion, and future full authoring behind separate contracts. This slice implements safe metadata editing, server-side duplication, privacy-bounded version history/revert, ACL-proven deletion, and basic private agent creation.

## Authorization model

Role permission and resource permission are independent:

```text
Browse agent directory/detail
  role: AGENTS.USE
  resource: VIEW

Edit safe metadata, inspect/revert versions, or duplicate
  role: AGENTS.USE + AGENTS.CREATE
  resource: EDIT

Delete
  role: AGENTS.USE + AGENTS.CREATE
  resource: DELETE
```

The pinned router proves those combinations in [the agent route middleware](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/agents/v1.js#L11-L143). `isEditable` in a directory row proves EDIT, not DELETE. The native app never infers delete authority from it.

LibreChat has two different agent coordinates. Agent CRUD routes use public `id`; ACL routes require Mongo `_id`. The web client explicitly reads the basic agent `_id` before calling effective permissions. Native models therefore keep `AgentID` and `AgentResourceID` as separate strong types. The delete path fetches the view-safe basic agent (so DELETE-only access does not require EDIT), requires a valid 24-hex `_id`, and sends that value only to:

```text
GET /api/permissions/agent/:mongoResourceId/effective
```

Missing or malformed resource identity fails closed before an ACL check or DELETE.

Authenticated role discovery now decodes `AGENTS.USE`, `CREATE`, `SHARE`, and `SHARE_PUBLIC` into optional `AgentPermissions`. Missing role evidence fails closed. The Agents entry requires verified authenticated policy, endpoint availability, `AGENTS.USE`, and an online session. The Manage menu additionally requires `CREATE` and the selected row's EDIT evidence; every route still rechecks server authorization.

## Basic private creation contract

Creation is not a client-side serialization of LibreChat's full agent object. It is available only when the session is authenticated and online, the capability exposes Agents, and fresh role evidence grants both `AGENTS.USE` and `AGENTS.CREATE`.

Before the confirmation sheet can submit, the repository refreshes:

```text
GET /api/models
```

The selected provider/model must exactly match the freshly reviewed catalog. A stale, unavailable, cross-profile, or changed selection performs no mutation. The create request is a one-shot, `retryPolicy: .never` allowlist to:

```text
POST /api/agents
Authorization: Bearer …
Content-Type: application/json
```

It sends only the bounded private-agent fields reviewed by the native form. It does not carry tools, actions, files, MCP, skills, subagents, credentials, avatar data, sharing/ACL settings, or arbitrary provider parameters. The response confirms creation only when HTTP `201` contains a newly generated valid agent ID and echoes the submitted bounded request identity; a message-only or otherwise malformed `201` is rejected.

The server provides no native idempotency or caller-owned creation lookup. After dispatch, cancellation, transport loss, 5xx, malformed success, mismatched echo, or a post-response authentication/browser-redirect result is ambiguous. The repository makes exactly one owner-scoped `GET /api/agents` reconciliation attempt. It returns a finite `outcomeUnknown` lock if that read cannot prove the result, and never posts again automatically. Definite 4xx results remain errors. A post-response 401 or browser redirect from this `.never` mutation is never replayed; GET and other idempotent requests may still use ordinary authentication recovery.

## Read and privacy boundary

Browsing continues to use only:

```text
GET /api/agents?requiredPermission=1&limit=…&search=…&cursor=…
GET /api/agents/:id
```

The ordinary detail route intentionally returns a safe projection; the server removes expanded instructions/tools/actions. Its implementation is visible in [the basic-versus-expanded response handler](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/agents/v1.js#L566-L650).

Opening the metadata editor performs a fresh EDIT-gated read:

```text
GET /api/agents/:id/expanded
```

The transport DTO decodes the evolving response permissively, then immediately maps it to `ManagedAgentMetadata`:

```text
id
resourceID (_id; live ACL coordinate only)
name
description
category
isPublic
version
```

Instructions, model parameters, tools, actions, files, credentials, edges, and unknown fields never cross the repository boundary, enter SwiftUI state, or reach the offline cache.

Version history uses a separate live EDIT-gated read:

```text
GET /api/agents/:id/versions
```

The server returns its raw historical array, whose records can contain the same sensitive expanded configuration. Native decodes the evolving array permissively, immediately projects each raw position to `AgentVersionSummary`, and retains only name, description, category, and creation/update dates. Every raw position keeps its original `serverIndex`; malformed or non-object entries become visible non-restorable placeholders rather than being removed and shifting later mutation coordinates. The history is live-only and is not cached or logged.

## Metadata edit contract

The native editor changes exactly three fields:

```text
PATCH /api/agents/:id
Authorization: Bearer …
Content-Type: application/json

{
  "name": "…",
  "description": "…",
  "category": "…"
}
```

Blank description and category are transmitted as empty strings so clearing is explicit. The app trims outer whitespace and applies bounded native input limits before dispatch: name 1…1,000 UTF-16 units, description at most 10,000, category at most 200. These bounds protect native UI/memory; the pinned server's update schema accepts optional strings and remains authoritative ([agent update schema](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/validation.ts#L567-L732)).

The PATCH uses `retryPolicy: .never`. The repository:

1. validates the input and safe path identity before network access;
2. preflights the exact expanded agent, proving current EDIT access;
3. serializes mutations per agent identity;
4. sends only the metadata body;
5. accepts a response only when agent identity and all three normalized fields match;
6. after transport failure, 5xx, cancellation, malformed 2xx, or a mismatched 2xx, performs a GET-only expanded reconciliation;
7. returns success only if server truth exactly matches the requested fields; otherwise it raises `outcomeUnknown` and the editor refuses another PATCH until it is closed and refreshed.

Definite 4xx responses are not converted into ambiguity. A 401 flows through the existing session-expiry path.

## Duplicate contract

Duplication uses the server's reviewed operation:

```text
POST /api/agents/:id/duplicate
Authorization: Bearer …
body: none
automatic retry: never
```

The server creates a fresh agent ID, rebinds graph source identities, revalidates referenced agents, filters tools against current authorization, prunes inaccessible file resources, and removes sensitive action credential fields before creating copied actions ([duplicate handler](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/agents/v1.js#L915-L1124)). This is safer than reconstructing a full agent payload in Swift.

The native repository preflights exact EDIT access and accepts only a well-formed response containing a different agent ID. The server attempts the new owner ACL grant after creation but still returns the created resource if that grant fails, so the immediate native acknowledgement deliberately does **not** claim EDIT; only the refreshed directory may set `canEdit`. The endpoint exposes no idempotency key or reliable lookup coordinate. Cancellation, transport loss, 5xx, malformed 2xx, a missing agent, or a repeated source identity therefore becomes `outcomeUnknown`; the sheet locks and instructs the user to refresh instead of issuing a second POST.

## Version history and revert contract

The pinned server appends historical snapshots in array order. Its revert endpoint accepts the raw array index rather than a version object or stable version ID:

```text
POST /api/agents/:id/revert
Authorization: Bearer …
Content-Type: application/json

{
  "version_index": 7
}
```

The native history displays newest indices first as “Server version N,” while preserving the exact original zero-based coordinate internally. It deliberately does not label a row as active: the safe metadata projection cannot compare the hidden instructions, tools, files, actions, edges, and parameters required to prove that claim.

Before POST, the repository serializes the mutation with all other operations for that agent, refetches the live version array, and requires an exactly matching safe summary at the selected raw index. A fabricated, compacted, stale, malformed, negative, or cross-agent coordinate dispatches no mutation. The server then restores the complete hidden configuration, revalidates handoff-agent references, filters unauthorized tools/MCP resources, and prunes inaccessible files. Native accepts success only from a well-formed same-agent response projected immediately to `ManagedAgentMetadata`.

The POST uses `retryPolicy: .never`. Unlike bounded metadata PATCH, safe GET reconciliation cannot prove whether the complete hidden version was restored: names and descriptions can repeat while instructions or tools differ. Cancellation, transport loss, 5xx, malformed/mismatched 2xx, or account/profile change after dispatch therefore becomes `outcomeUnknown`; the restore sheet locks and requires a refresh instead of issuing another POST. Definite pre-mutation 4xx errors remain retryable only after the user reviews the server response, and 401 follows normal session expiry.

## Delete contract

Delete appears only after fresh authenticated `AGENTS.USE + CREATE` role evidence, a fresh basic-detail identity read, and a live effective-permissions response containing the DELETE bit. It does not require EDIT. It uses the public agent ID for the mutation:

```text
DELETE /api/agents/:publicAgentId
Authorization: Bearer …
body: none
automatic retry: never
```

The repository accepts the pinned `{"message":"Agent deleted"}` acknowledgement or an initial 404. Cancellation, transport loss, 5xx, malformed 2xx, and mismatched acknowledgement are ambiguous and trigger one read-only `GET /api/agents/:id` reconciliation. A 404 proves deletion. An exact surviving agent proves that the DELETE was not applied and permits an explicit user retry. Any other result remains `outcomeUnknown` and locks the sheet; the app never issues a second DELETE automatically. A 401 follows normal session expiry and a missing DELETE bit dispatches no mutation.

## Native presentation

The existing agent detail keeps Start Chat as the primary action. Eligible agents gain a compact Manage menu with:

- **Edit details** — fetches fresh metadata before presenting an item-identified native sheet;
- **Version history** — loads a live newest-first safe projection, keeps exact server coordinates, and presents an item-identified restore review sheet;
- **Duplicate agent** — presents a one-shot confirmation sheet explaining server-side access revalidation;
- **Delete agent** — appears only after live resource DELETE proof and presents a destructive confirmation with ambiguity-aware recovery copy.

The sheets own their drafts or confirmation state, progress, failure state, and dismissal. Offline, stale role evidence, noneditable rows, and in-flight same-agent mutations disable management without weakening browsing. No mutation is optimistic; successful edits replace visible safe detail only after authoritative verification, while successful duplicate/delete operations refresh the directory from the server.

## Explicitly deferred surfaces

This slice does not claim:

- advanced/full agent authoring beyond the bounded private-create form;
- expanded instructions/model/tool/file/action/graph editing;
- avatar upload;
- sharing, public grants, people picker, or ACL administration;
- Assistant or remote-agent management.

Each requires a separate permission, privacy, ambiguity, and acceptance contract.

## Verification and remaining acceptance

Automated package coverage verifies role-bit decoding and legacy capability decoding, safe expanded/history projection, preservation of raw indices through malformed entries, distinct public/Mongo identities, exact routes/path components/body/retry policy, input validation, duplicate/revert mapping, effective ACL-bit mapping, and exact deletion acknowledgement. The newer compile-only app/model/repository coverage includes basic-create role/capability gating, fresh reviewed model rejection, exact allowlisted POST body, strict generated-ID/request-echo mapping, and ambiguity reconciliation/no-repost behavior. Repository tests also compile for metadata 5xx→GET reconciliation, one-shot lost duplicate response, exact fresh duplicate identity, exact live version preflight and revert body, stale-version no-POST rejection, lost-revert outcome lock, live DELETE permission proof, missing-resource fail-closed behavior, exact acknowledgement, ambiguous-delete absence reconciliation, surviving-resource retry classification, and no DELETE without the exact bit.

The 2026-08-19 full package run passed **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at `/private/tmp/librechat-visual-audit-core`. Generic Simulator build-for-testing passed at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`, and the iOS 17-baseline device build passed at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`. **One hundred eight** newer app/model/repository cases compile but did not execute because no Simulator was booted, including the bounded agent-create cases above. Twelve deterministic UI methods exist; only the historical seven executed, while five newer methods—including basic agent creation—are compile-only. This is not live mutation acceptance.

Authenticated acceptance remains required for role changes, shared editable agents, 401/403/404/409, reverse-proxy subpaths, exact metadata clearing, version ordering/restoration, lost-response reconciliation, duplicate filtering, profile/account switching, VoiceOver, Dynamic Type, and refresh visibility. None of the build evidence proves a live server mutation.
