# LibreChat Skills and manual invocation

**Pinned server:** LibreChat `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native slice:** Core DTOs, request factories, scope mapper, selection validation, account activation management, and generation wiring in this workspace.  
**Evidence date:** 2026-08-19

This document is the living contract for native Skills. The server remains authoritative for ACLs, active overrides, target scope, and invocation resolution. A cached row is presentation data, never authorization evidence.

## Wire contract

All listed routes require the authenticated bearer session.

```text
GET /api/skills?category=&search=&limit=&cursor=
GET /api/user/settings/skills/active
POST /api/user/settings/skills/active
```

`GET /api/skills` defaults `limit` to 20 and clamps it to 1...100. The response is:

```json
{
  "skills": [
    {
      "_id": "...",
      "name": "review-code",
      "displayTitle": "Review code",
      "description": "...",
      "category": "...",
      "source": "inline|deployment|github|notion",
      "version": 1,
      "fileCount": 0,
      "alwaysApply": false,
      "isPublic": false,
      "disableModelInvocation": false,
      "userInvocable": true
    }
  ],
  "has_more": false,
  "after": null
}
```

The native list DTO intentionally ignores evolving/private fields and maps only safe presentation metadata. `body` and `frontmatter` are not list fields. Active state is a plain map of skill ID to explicit boolean:

```json
{ "507f1f77bcf86cd799439011": false }
```

Absent state entries use server defaults. The two GET factories use bearer
authorization and idempotent retry. The POST replaces the complete explicit
override map using `{ "skillStates": { "<ObjectId>": true|false } }`; it is a
one-shot mutation with automatic retry disabled. Native validates ObjectId
keys and the server's raw 400-entry input bound before transport. The server
prunes inaccessible/deleted IDs, enforces its 200 stored-override bound, and
returns the complete stored map.

The repository serializes account activation writes, refreshes capability,
role, ACL-visible catalog, and current overrides before dispatch, and submits
the reviewed full map once. A transport/5xx/malformed-success ambiguity causes
one bounded GET reconciliation, never another POST. Exact profile/account and
Skill identity remain fenced throughout; 401 expires the session, 403 is
presented as authorization loss, and an unprovable result locks management
until an explicit reload.

## Capability, role, ACL, and target gates

The runtime requires both:

1. the agents endpoint advertises `AgentCapabilities.skills`; and
2. the account has `SKILLS.USE` plus `VIEW` access to the specific resource.

The role bits are not treated as sufficient resource authorization. The server intersects account ACL-visible IDs with target scope before injecting or resolving a Skill.

Persisted saved agent scope:

```text
skills_enabled != true                 → disabled
skills_enabled == true, skills absent  → all ACL-visible skills
skills_enabled == true, skills == []   → all ACL-visible skills
skills_enabled == true, skills != []   → ID allowlist ∩ ACL-visible IDs
```

Ephemeral/model-spec scope:

```text
skills: true       → all ACL-visible skills
skills: false      → disabled
skills: []         → explicitly disabled
skills: [names]    → name allowlist ∩ ACL-visible skills
skills absent     → per-conversation `ephemeralAgent.skills` badge controls all/none
```

An explicit model-spec value wins over the badge. The native `SkillInvocationTargetScope` carries this reviewed evidence into the mapper; it does not infer it from a target label or stale conversation.

## Active defaults and selection states

The server’s active override map is an exception map:

- deployment skills default active;
- skills owned by the current user default active;
- shared skills default to `interface.skills.defaultActiveOnShare` (otherwise false);
- explicit map entries override the default;
- the server prunes inaccessible/deleted IDs and caps overrides at 200.

Native catalog rows preserve truthful non-selectable states:

```text
available       selectable manual `$` invocation
inactive        account override is false
modelOnly       userInvocable=false; model may still invoke when permitted
excludedByTarget outside the reviewed model-spec/saved-agent scope
targetDisabled  capability or explicit target scope is disabled
ambiguousName   multiple invocable rows share the same name
```

The entire row is not silently removed when it is unavailable; the UI can explain the server policy. Duplicate invocable names are quarantined and cannot be selected.

## Manual invocation and generation

Fresh generation sends selected names as the top-level request field:

```json
{ "manualSkills": ["review-code", "write-tests"] }
```

The native picker validates the exact reviewed catalog immediately before send. It requires unique valid kebab-case names, one-to-one selectable rows, unchanged target/profile/account evidence, and at most 10 selected Skills. Invalid, unavailable, duplicate, or target-drifted selections fail closed without a generation POST.

The server additionally filters malformed names, bounds name length, deduplicates, and caps manual resolution at 10. The native queue blocks selected Skills until the exact fresh preflight succeeds. Regeneration replays the persisted source user message’s selection; it does not drain a new compose selection. Response regeneration does so only after the exact source user-message identity matches and fresh target/policy evidence is revalidated; it never copies a compose-time selection merely because the names look equal. The generation request includes the existing `clientRequestId`, target routing, `spec`, and request-scoped `ephemeralAgent` fields, with `manualSkills` added only when meaningful.

Manual selection is primary-agent scoped. Handoff/sub-agent turns do not inherit the user’s per-submit `$` picks. `userInvocable=false` is never made selectable by a crafted request. `disableModelInvocation=true` affects model catalog/tool invocation, not explicit manual invocation, provided the row is user-invocable and ACL/target active.

## Implemented, deferred, and unproven

Implemented and package/build evidenced:

- permissive paginated catalog and active-state DTOs;
- exact authenticated request factories;
- capability/role-aware domain scope types;
- active defaults and target-scoped availability projection;
- model-spec and saved-agent scope handling;
- duplicate-name quarantine and exact selection validation;
- picker cancel/no-send semantics;
- fresh preflight before generation;
- `manualSkills` generation wire field;
- ephemeral model-spec/badge opt-in;
- regeneration replay of persisted selections;
- selected-Skill queue blocking until reviewed preflight.
- native Settings catalog with search plus active/inactive filters;
- account activation basis (`explicit`, deployment, owner, shared, inactive)
  shown separately from the current boolean state;
- exact whole-map account activation POST with single-operation admission;
- confirmed, not-confirmed, and outcome-unknown reconciliation states without
  blind reposting;
- offline/private-state clearing and 401 session-expiry handling.

Picker hardening now removes revoked selected rows, keeps selection chips at a
44-point minimum target, disables Done while catalog refresh is active, and
shows an inline stale-policy warning when target or account evidence changes.
These are source/build changes only; no runtime acceptance is claimed.

Deferred:

- Skill authoring, editing, import, bundled-file browsing/upload/download;
- persisted queue ownership for pending Skill selections;
- always-apply display/history reconciliation beyond the current bounded contract.

Unproven:

- authenticated live catalog/active-state reads and writes;
- live role/ACL/model-spec/saved-agent combinations;
- live generation with manual Skills;
- app-level picker and Settings-management accessibility/Simulator execution;
- restart/background recovery with selected Skills against a real server.

## Source and test anchors

Pinned server sources: `packages/api/src/agents/skills.ts`, `api/server/services/Endpoints/agents/initialize.js`, `api/server/routes/skills.js`, `api/server/routes/settings.js`, `api/server/controllers/SkillStatesController.js`, and `packages/data-provider/src/types/skills.ts`.

Native sources: `Packages/LibreChatCore/Sources/LibreChatProtocol/Skills.swift`,
`LibreChatDomain/Skills.swift`, generation and account-state coordination in
`LibreChat/Data/Repositories/LibreChatRepository.swift`, and
`LibreChat/Features/Settings/SkillsManagementView.swift`.

Focused `SkillsContractTests` cover exact GET/POST routes, whole-map body and
no-retry policy, permissive DTOs, account defaults, scope,
active/user-invocable gating, duplicate names, and selection limits. Repository
and model tests additionally cover exact account wire, confirmed/lost-response
reconciliation, no-repost failure, offline behavior, search/filtering,
single-mutation admission, 401 clearing, and unknown-outcome lockout. The full
Core result on 2026-08-19 was **367 Swift Testing tests + 4 XCTest checks = 371
checks across 44 suites** at
[`/private/tmp/librechat-skill-management-core`](/private/tmp/librechat-skill-management-core).
The latest generic physical-device and Simulator build-for-testing passed at
[`/private/tmp/LibreChatIOS-SkillManagement-Device-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Device-Derived)
and
[`/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived),
compiling **126 newer app/model/repository tests** without executing them. No
Simulator was booted, no UI tests ran, and no live server call occurred.
