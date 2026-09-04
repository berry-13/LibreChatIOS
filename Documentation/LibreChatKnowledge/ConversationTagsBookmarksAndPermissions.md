# LibreChat conversation tags, bookmarks, and permission metadata

Audit date: 2026-08-18. The server evidence in this document is the detached LibreChat checkout at `/tmp/librechat-knowledge.mI6Evl/LibreChat`, exactly at commit `b2128a7d189ac020ebb6e49a57ee986e98326b77`. This is a read-only contract audit; no server or iOS application source was changed.

## Executive result

LibreChat calls the feature “conversation tags” in its API and “Bookmarks” in the web UI. A bookmark is not a separate conversation resource: it is a user-owned `ConversationTag` directory record plus a string name in each matching conversation's `tags` array. The directory carries description, ordering, and a denormalized conversation count; the conversation is the source of the association. Every `/api/tags` operation is JWT-authenticated and requires the caller's role to have `BOOKMARKS.USE`. There is no create/update/delete permission split for bookmarks.

The actual server routes are a small, non-paginated CRUD surface plus one conversation replacement mutation:

| Operation | Exact route and method | Request body | Successful response |
|---|---|---|---|
| List the caller's tag directory | `GET /api/tags` | none | `200` JSON array of tag records, sorted by `position` ascending |
| Create a directory tag | `POST /api/tags` | `{ tag, description?, conversationId?, addToConversation? }` | `200` one tag record |
| Rename/edit/reorder | `PUT /api/tags/:tag` (URL-decoded) | `{ tag?, description?, position? }` | `200` updated record; `404 { error: "Tag not found" }` if old name absent |
| Delete | `DELETE /api/tags/:tag` (URL-decoded) | none | `200` deleted record; `404 { error: "Tag not found" }` if absent |
| Replace a conversation's tags | `PUT /api/tags/convo/:conversationId` | `{ tags: string[] }` (the web type also sends an unused `tag` field) | `200` string array of the final, de-duplicated tags |

The web data-provider also exposes `GET /api/tags/list?pageNumber=...` and `POST /api/tags/rebuild`, but the pinned `api/server/routes/tags.js` has no matching handlers. Treat both as stale/dead builders, not supported routes. In particular, the conversation mutation is `PUT`, not `POST` (`api/server/routes/tags.js:104-121`; `packages/data-provider/src/api-endpoints.ts:469-479,473-476`; `packages/data-provider/src/data-service.ts:1266-1295`).

## Authentication and permission gates

The route is mounted at `/api/tags` (`api/server/index.js:323-327`). The router applies `requireJwtAuth` and then one common `generateCheckAccess` middleware before all handlers (`api/server/routes/tags.js:17-24`). The check is:

```text
permissionType = PermissionTypes.BOOKMARKS
permissions = [Permissions.USE]
```

The middleware loads `req.user.role`, resolves that role, and requires the `BOOKMARKS.USE` value to be truthy (`packages/api/src/middleware/access.ts:85-121,164-204`). Missing user/role, missing role, missing permission object, or an explicit false all fail closed with `403 { message: "Forbidden: Insufficient permissions" }`; a role lookup exception becomes `500 { message: "Server error: ..." }`. JWT failure is handled by the shared auth middleware and is outside the tag handler's error mapping.

The permission type has only one bit and defaults to `USE: true` in the provider schema (`packages/data-provider/src/permissions.ts:6-15,159-162`). Role defaults include bookmark use for the default roles (`packages/data-provider/src/roles.ts:44-56`). The server's startup permission seeding distinguishes interface configuration from role permissions: `interface.bookmarks` is an optional UI/config value and is copied into the authenticated `/api/config` response, while the route authorization is the role permission (`packages/data-schemas/src/app/interface.ts:47-66`; `api/server/routes/config.js:250-294`). Anonymous `/api/config` intentionally does not expose this post-login interface policy (`api/server/routes/config.js:215-248`).

For a client that needs to know its own role permission before drawing bookmark controls, `GET /api/roles/:roleName` is bearer/JWT-protected and returns the role including `name` and `permissions`; the caller may read its own role without the `READ_ROLES` capability (`api/server/routes/roles.js:20-22,112-145`). Reading another custom/admin role can require `READ_ROLES` and returns `403 { message: "Unauthorized" }`. The bookmark permission schema remains `{ USE: boolean }`; generic ACL `/api/permissions` resource types do not apply to personal conversation tags.

The web UI uses role data to hide bookmark entry points (`client/src/hooks/Roles/useHasAccess.ts:5-47`; `client/src/hooks/Nav/useSideNavLinks.ts:63-69,163-170`), but this is only presentation gating. The server check remains authoritative for every request.

## DTOs and persistence shapes

The provider response schema requires the following directory fields (`packages/data-provider/src/schemas.ts:1220-1230`):

```json
{
  "_id": "mongo-object-id",
  "user": "account-id",
  "tag": "work",
  "description": "optional text",
  "createdAt": "ISO date string",
  "updatedAt": "ISO date string",
  "count": 3,
  "position": 1
}
```

The server schema indexes `tag`, `user`, `description`, and `position`, applies timestamps, and enforces uniqueness on `(tag, user, tenantId)` (`packages/data-schemas/src/schema/conversationTag.ts:3-42`). The tenant-isolation model plugin is applied when the model is created (`packages/data-schemas/src/models/conversationTag.ts:1-12`), but method-level queries are still explicitly user-scoped.

Provider request types are looser than the response schema. `TConversationTagRequest` is a partial directory record (excluding timestamps, count, and user) with optional `conversationId` and `addToConversation`; the conversation replacement request is `{ tags: string[]; tag: string }`, although the server uses only `tags` (`packages/data-provider/src/types.ts:448-465`). There is no server-side Zod/body validation in `tags.js`.

## Behavior and ambiguity semantics

### List

`getConversationTags(user)` does `find({ user }).sort({ position: 1 }).lean()` and returns an array, including zero records as `[]` (`packages/data-schemas/src/methods/conversationTag.ts:175-193`). The route returns `200 []` for an empty directory; its `404` branch is unreachable for the normal method because Mongoose returns an array (`api/server/routes/tags.js:32-43`). There is no server pagination, search, count filter, or sort parameter. The web side filters locally for the bookmark panel.

### Create

`createConversationTag` first looks up `(user, tag)` and returns the existing record unchanged if found (`packages/data-schemas/src/methods/conversationTag.ts:198-230`). Therefore a duplicate create is an idempotent-looking `200`, not a `409`; a duplicate request does not update its description, position, or add the tag to a conversation. For a new tag, position is one greater than the user's current maximum (or `1` when no tag exists), count is `1` only when `addToConversation` is truthy and otherwise `0`, and the tag is upserted (`:232-250`). If both `addToConversation` and `conversationId` are present, the server `$addToSet`s the tag onto a same-user conversation (`:252-257`). It does not first verify that the conversation exists; the tag record can be created with a count of one even if no conversation was updated.

Missing/invalid body fields are not normalized by the route. Model/database errors are collapsed to `500 { error: "Internal server error" }` (`tags.js:52-59`).

### Update

The `:tag` path segment is decoded once before lookup (`tags.js:68-75`). A missing old tag is a clean `404`. A rename checks for a target-name collision and then replaces the old name in every same-user conversation before updating the directory record (`conversationTag.ts:321-350`). The method throws on a collision, but the route catches it and emits generic `500`, not `409` (`tags.js:77-80`). `description` uses an explicit `undefined` check, so an empty string clears it; `tag` and `position` are changed only when truthy/present. Moving a tag shifts neighboring positions to preserve ordering (`conversationTag.ts:267-290,335-350`).

### Delete

Deletion is name-based and user-scoped. A missing name is `404`; a successful delete returns the deleted directory record, removes that name from all same-user conversations, and decrements positions above the deleted position (`tags.js:89-100`; `conversationTag.ts:357-399`). Database/cleanup failures become generic `500`.

### Replace conversation tags

The server first finds the conversation by `(user, conversationId)` and treats absence as an error; the route maps this and all other failures to `500` plain text `Error updating conversation tags` (`tags.js:110-121`; `conversationTag.ts:405-417,467-470`). It converts both old and incoming lists to `Set`s, so duplicate input is removed and response order follows first occurrence in the input (`:419-425,458-466`). Added names increment a matching directory record, with `upsert: true`; removed names decrement one if a directory record exists (`:427-455`). Consequently, conversation tags may create directory records even when the user never used the create-tag endpoint, and the resulting upsert may have no explicit position/description. The final conversation update returns only `string[]`, not the conversation object or directory records.

The request's `tag` field is not read by the server. A client should send the exact minimal body `{ tags }` unless it is intentionally matching the web provider's broader type.

## Relationship to conversation metadata and filtering

Conversation documents store `tags: [String]` with a default empty array and a Meilisearch index (`packages/data-schemas/src/schema/convo.ts:29-36`). The conversation list route accepts repeated or single `tags` query values, wraps a scalar into an array, and passes them to the model (`api/server/routes/convos.js:38-69`). The model filter is `tags: { $in: tags }`, which means **OR** semantics: a conversation is included when it has at least one requested tag (`packages/data-schemas/src/methods/conversation.ts:565-599`). This filter is independent of the bookmark directory permission middleware; `/api/convos` itself only applies JWT auth (`api/server/routes/convos.js:32-34`). A client must not infer that a visible `tags` array means the user can manage the directory or that a bookmark count is authoritative for the list.

The pinned iOS DTO/domain boundary preserves optional conversation tag names and distinguishes omitted tags (`nil`) from an explicit empty list (`[]`) (`Packages/LibreChatCore/Sources/LibreChatProtocol/DTOs.swift:45-99`; `Packages/LibreChatCore/Sources/LibreChatDomain/Models.swift:158-197`). The separate native tag-directory repository and UI are documented below.

## Current iOS implementation and remaining gap

The native app now implements a separate `ConversationTagRepository` and keeps the directory distinct from the conversation cache model. It has exact request builders and DTO/domain mappings for directory CRUD (`GET/POST /api/tags`, `PUT/DELETE /api/tags/:tag`) and atomic conversation replacement (`PUT /api/tags/convo/:conversationId`). Tag path components use one raw-path encoding pass. The app reads `GET /api/roles/:roleName`, fails closed unless `BOOKMARKS.USE` is true, and exposes the directory from the account menu. A tag-filtered conversation list sends repeated `tags` query items, matching LibreChat's OR semantics; context-menu assignment updates the selected conversation and cache. Offline mode hides or disables remote tag mutations.

Mutation ambiguity is deliberately non-idempotent: no mutation is automatically retried. Transport/5xx outcomes reconcile through an authoritative read; matching state is cached and returned, mismatch caches server authority while preserving the original error, unauthorized reconciliation propagates, and an unconfirmable result requires refresh before retry. The implementation is fixture/simulator tested but has not passed authenticated live acceptance against the pinned deployment. Older route summaries that say the conversation mutation is `POST /api/tags/convo/:conversationId` are inaccurate for this pinned commit; the exact method is `PUT`.

## Follow-on hardening recommendation

Keep the separate `ConversationTagRepository` and continue to harden it:

1. Preserve strict DTO/domain decoding and unknown-field tolerance while extending forward compatibility.
2. Keep exact URL builders and one raw-path encoding pass; do not reintroduce the provider's stale `/list` or `/rebuild` endpoints.
3. Keep role lookup and `BOOKMARKS.USE` fail-closed. A hidden control or `interface.bookmarks` must never become authorization.
4. On replacement, keep selected conversation/list cache and directory counts coherent; on rename/delete, refresh rather than guessing counts.
5. Keep offline mode read-only. Treat duplicate create `200`, update collision `500`, conversation-not-found `500`, and transport/5xx outcomes according to the server behavior documented above, with authoritative refresh before retry.

This is deliberately bounded to personal tags/bookmarks and conversation filtering. Generic `/api/permissions` ACLs, public sharing, role administration, and project membership are separate contracts.

## Implemented coverage and remaining acceptance

- Permission matrix: missing JWT, role with no `BOOKMARKS`, explicit `USE: false`, `USE: true`, role lookup failure, and authenticated `/api/config` versus anonymous `/api/config`.
- Directory: empty `200 []`, position ordering, percent-encoded names, duplicate create returning unchanged record, description clearing, reorder neighbor shifts, rename propagation, collision generic `500`, delete propagation, and deleted-name `404`.
- Conversation association: add-on-create with a real conversation, add-on-create with an unknown conversation (document observed count drift), replacement with duplicate tags and empty tags, replacement with unknown directory names, missing conversation, and repeated `tags` query values on `GET /api/convos` proving OR filtering.
- Pagination/dead routes: verify `/api/tags` never accepts page/sort filters, `/api/tags/list` is not implemented, and `/api/tags/rebuild` is not implemented at this baseline.
- Native coverage: account/profile isolation, partial conversation pages, rename/delete while a tag-filtered list is cached, stale 403/permission gating, raw path encoding, offline hidden/disabled mutations, role lookup, repeated-tag filtering, cache updates, and transport ambiguity followed by authoritative directory/conversation refresh. The current independent package verification passed 350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks) using [`/private/tmp/librechat-visual-audit-core`](/private/tmp/librechat-visual-audit-core). The complete app unit/model/repository target passed **371/371** at [`/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`](/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult), and generic Simulator/iOS 17 device builds passed; no authenticated live network acceptance was performed.
