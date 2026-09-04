# Prompts and templates

**Pinned server:** LibreChat `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Audit and native slice:** 2026-08-19

LibreChat prompts are permissioned server resources, not local snippets. The native app has two deliberately separate surfaces: a read-and-insert library in the composer and a live-only **My templates** management surface in Settings. Library selection never submits a generation or overwrites composer text. Management supports private metadata and version history without caching prompt contents or expanding into sharing/ACL administration.

## Authorization and resource access

Every pinned prompt route first requires JWT authentication and the current role's `PROMPTS.USE` permission. Create, edit, sharing, and deletion routes add role and resource requirements; directory results are also filtered by prompt-group `VIEW` ACLs. Source anchors: [router-wide authorization](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L51-L70), [single-group VIEW gate](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L73-L98), and [role permission schema](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/roles.ts#L44-L64).

The native compatibility result carries an optional `PromptPermissions`. `nil` means the authenticated role has not been proven; `use == true` is required before the composer library appears. The first management surface requires both `use` and `create`, because it offers create, metadata update, and production promotion in one place. Each resource request still relies on the server's VIEW or EDIT ACL; role evidence never replaces route authorization. The pinned route gates are visible at [router authorization and CREATE checks](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L51-L70), [version-add EDIT enforcement](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L337-L348), and [metadata/promotion EDIT enforcement](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L389-L437).

## Implemented directory contract

```text
GET /api/prompts/groups
Authorization: Bearer …

query:
  limit     1...100
  name      optional server-side search
  category  optional
  cursor    optional opaque continuation
```

The server performs cursor-only pagination, computes accessible IDs from the current user and role, and includes public/owned/shared filtering. Its response contains `promptGroups`, `has_more`, and an opaque `after` cursor. Each group may expose `_id`, `name`, `oneliner`, `command`, `category`, `productionPrompt.prompt`, `authorName`, `isPublic`, and `numberOfGenerations`. The authoritative behavior is in [the paginated group handler](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L158-L241).

Native mapping keeps stable view metadata and exact production text, ignores unknown fields, drops malformed or duplicate group IDs, and requires a nonempty bounded `after` whenever `has_more` is true. Raw author IDs and edit configuration never enter the domain model.

Prompt contents are not cached. Offline browsing explicitly requires a connection. A 401 clears live results and expires the session; a transient next-page failure preserves current results and remains retryable. Search requests are revision-fenced so a slow old result cannot replace a newer query.

## Usage acknowledgement

After insertion, the app best-effort records:

```text
POST /api/prompts/groups/:groupId/use
Authorization: Bearer …
body: none
automatic retry: never
```

The server rate-limits this route, rechecks group `VIEW`, validates the ObjectId, increments `numberOfGenerations`, and returns the new count ([source](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/prompts.js#L350-L379)). It is a non-idempotent counter, so native never retries automatically. Failure never removes an inserted draft.

## Implemented private-template management

Settings exposes a native **Manage prompt templates** destination only after fresh authenticated `PROMPTS.USE` plus `PROMPTS.CREATE` evidence. It remains online-only and requests the server-owned category rather than mixing public/shared resources into an authoring list:

```text
GET /api/prompts/groups?category=sys__my__prompts__sys&limit=30
  name    optional nonempty server-side search
  cursor  optional opaque continuation
GET /api/prompts/groups/:groupId
GET /api/prompts?groupId=:groupId
```

The detail response must contain one safe group identity, a safe `productionId`, a duplicate-free version list bound to that exact group, and the referenced production version. Unknown fields are ignored; missing, cross-group, or inconsistent coordinates fail closed. The native UI shows group metadata, exact version text and type, and the current production marker. Prompt text stays live-only and is never copied into SwiftData, configuration snapshots, logs, or offline search.

The first mutation set is:

```text
POST  /api/prompts
POST  /api/prompts/groups/:groupId/prompts
PATCH /api/prompts/groups/:groupId
PATCH /api/prompts/:promptId/tags/production
```

Creation sends `{prompt:{prompt,type},group:{name,category?,oneliner?,command?}}`. Adding a version sends only `{prompt:{prompt,type}}`; it never silently promotes the new version. Metadata update sends only `name`, `oneliner`, `category`, and `command`, including explicit `null` to clear a command. Promotion first proves that the selected version belongs to the freshly fetched group.

Every mutation uses `retryPolicy: .never`. Create and add-version have no server idempotency key, so a lost response, cancellation, malformed success, or 5xx becomes a one-shot `outcomeUnknown` state and the native sheet refuses a second submission. Metadata update and promotion perform a GET-only exact-state reconciliation after an ambiguous PATCH; if proof is unavailable or mismatched, the UI locks that operation and instructs the user to close and refresh instead of reposting. A server 200 error envelope cannot masquerade as a created resource.

## Variables and insertion

The implemented grammar supports `{{name}}` and `{{name:option one|option two}}`. Repeated placeholders share one input identity and retain first-seen order. Suggested options are conveniences; every ordinary variable requires a nonblank value.

The pinned special variables are `current_date`, `current_datetime`, `iso_datetime`, and `current_user`. Upstream behavior is defined in [the data-provider parser](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/parsers.ts#L447-L479). Native resolves them locally using the device timezone and verified display name. Missing user evidence remains visible for review rather than inventing an identity.

The native flow is review-first:

1. Open the permission-gated Prompt Library from the composer.
2. Search or page through the live ACL-filtered directory.
3. Review exact production text.
4. Complete required fields or choose suggestions.
5. Insert expanded text into the editable draft.
6. Review and send separately through ordinary generation.

If the composer already contains text, insertion appends with a blank-line boundary. It never replaces existing work, stages attachments, changes the selected target, or calls generation.

## Deliberate boundaries

The app does not implement version deletion, group deletion, labels, sharing, public grants, ACL/people management, random/all directories, or prompt-to-generation auto-submit. It also does not expose a partial editor to roles that have USE/EDIT but not CREATE; that narrower permission composition should be added only after live role/ACL acceptance.

Prompt content may contain sensitive reusable instructions. It must not enter logs, crash breadcrumbs, SwiftData, configuration snapshots, or offline indexes. Future favorites or pinning require an explicit privacy design.

## Verification evidence

The latest package run passed **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** using `/private/tmp/librechat-visual-audit-core`. Prompt coverage includes exact directory/detail/version/mutation requests, permissive DTOs, strict identity/cursor/production/version binding, role capability derivation, pinned validation limits and command grammar, no-retry policy, error-envelope rejection, ordered variable parsing, special-variable expansion, missing-value failure, and replacement-text edges.

The complete app unit/model/repository target previously passed **371/371** on iPhone 17 Pro, iOS 26.5, at `/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`, including the earlier library behavior. Five newer prompt-management repository cases compile in the successful generic Simulator build-for-testing at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`: exact detail/version reads, one-shot lost create, one-shot lost version-add, ambiguous metadata reconciliation, and membership-preflight promotion reconciliation. The iOS 17-baseline device build passed at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`. Those five cases were not executed because no Simulator was booted. The separate 7/7 executed UI suite does not exercise either prompt surface, and no authenticated live prompt request or mutation was made.

Live acceptance must cover role and ACL denial, the owned-category list, owned/shared/public library filtering, opaque pagination, all variable classes, existing-draft preservation, usage 200/403/404/429/5xx/lost-response behavior, create/add/update/promote 200/400/401/403/404/409/429/5xx/lost-response behavior, production consistency, account isolation, absence from local storage/logs, VoiceOver, largest Dynamic Type, keyboard navigation, and narrow iPhone layout.
