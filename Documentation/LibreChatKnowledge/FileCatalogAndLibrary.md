# Owner file catalog and native Files library

This document records the exact account file-catalog contract in the pinned
LibreChat source at commit
`b2128a7d189ac020ebb6e49a57ee986e98326b77`, and the deliberately narrower
native iOS presentation built on top of it.

The Files library is not a local media vault and it is not a complete file
manager. It is a live, authenticated view of the records LibreChat currently
returns for the selected account.

## Exact catalog route

```text
GET /api/files
Authorization: Bearer <access token>
```

The files router applies JWT authentication, server configuration, ban checks,
user-agent parsing, and tenant-context middleware before its child routes
(`api/server/routes/files/index.js:1-72`). The catalog handler then calls:

```js
db.getFiles({ user: req.user.id })
```

and returns the resulting array with HTTP 200
(`api/server/routes/files/files.js:54-75`). The pinned endpoint has:

- no cursor or page parameter;
- no server-side filename search;
- no sort query;
- no account ID in the URL or request body; and
- no anonymous form.

The bearer-authenticated user is therefore the owner-selection coordinate.
The native repository additionally fences the response to the profile and
account that initiated the request so an in-flight response cannot install
after a same-host account switch.

For S3 deployments the handler may refresh expiring file URLs, at most once per
user in the server's thirty-minute cache interval. Failure to refresh those
URLs is logged by the server but does not fail the metadata catalog.

## Wire record

The web `TFile` contract includes:

```text
file_id              stable server file identity
temp_file_id?        upload acknowledgement identity
filename
filepath
bytes
type                 MIME type
embedded
context?
source?
width? / height?
expiresAt?           short-lived upload TTL
expiredAt?           retention deadline on current Mongo records
status?              pending / ready / failed preview lifecycle
createdAt? / updatedAt?
```

The server record may also contain owner/tenant/storage identifiers, extracted
text, HTML preview material, provider metadata, and future fields. The native
catalog DTO is permissive but its domain mapper retains only the stable file
attachment metadata plus parsed dates. It does not decode extracted `text`,
`preview`, arbitrary metadata, credentials, owner IDs, or tenant IDs.

`filepath` remains in `UploadedFile` because a future separately authorized
transfer or delete contract may require it. The Files UI never renders that
path, never uses it as a URL, and never treats it as access authority.

Mongo file records use timestamps and carry both short-lived `expiresAt` and
retention-scoped `expiredAt` fields (`packages/data-schemas/src/schema/file.ts:
135-170`). Native presentation prefers the retention deadline when both are
present. Missing or invalid dates remain unknown rather than being invented.

## Identity and compatibility policy

`file_id` is required for a native catalog item. One malformed record does not
hide all valid files; it increments a privacy-safe omitted count. Duplicate
identity handling is fail-closed:

- an exact duplicate is rendered once and counted as one omitted replay;
- two different records with the same `file_id` cause that identity to be
  hidden entirely; and
- later records for the quarantined identity remain hidden.

Independent valid files remain visible. The warning reveals only a count, not
the malformed filenames, paths, source values, or payloads.

Unknown `source`, `context`, MIME type, or preview status values are retained by
the transport/domain boundary for compatibility but never surfaced verbatim.
Presentation maps known values to finite labels such as `Cloud storage`,
`Chat attachment`, or `Generated output`; unknowns become `Server-managed
storage`, `Account file`, or `File`.

## Native product behavior

The account menu exposes **Files** only while online. The native sheet provides:

- live load and pull-to-refresh;
- local filename/type search over the current response;
- stable local sorting by update date, name, or size;
- finite file-kind icons and accessible labels;
- safe detail metadata: kind, non-negative size, semantic use, coarse storage
  category, finite preview state, valid dimensions, and parsed dates;
- an explicit protected download followed by the native system Share/Save
  handoff, without exposing a provider URL;
- a separately confirmed single-owner-file deletion flow that reports success
  only after a fresh raw catalog proves the exact identity absent;
- distinct offline, unauthorized, forbidden, unsupported, empty, and transient
  error states; and
- a warning when malformed/conflicting records were omitted.

The result is process/view state only. It is not written to SwiftData,
configuration snapshots, drafts, logs, or the offline cache. A transient
refresh error may leave the already visible in-memory snapshot on screen with a
refresh warning; a 401 clears it and expires the session, while a 403 or 404/405
clears it into a distinct closed state.

The pinned route returns a complete array, so the client must not fabricate
cursor paging. Local UI sorting does not claim server order is meaningful.

## Exact text-preview route

Opening a file detail performs a separate live request:

```text
GET /api/files/:file_id/preview
Authorization: Bearer <access token>
```

LibreChat applies the same `fileAccess` middleware used by download. It first
requires an authenticated user and file record, rejects cross-tenant access,
then permits either the owner or a viewer of an agent that references the file
(`api/server/middleware/accessResources/fileAccess.js:83-148`). A catalog row
is therefore not itself preview authority.

The pinned response is the smallest lifecycle envelope
(`api/server/routes/files/files.js:375-445`):

```text
{ file_id, status: "pending" }
{ file_id, status: "ready", text?, textFormat?: "text" | "html" | null }
{ file_id, status: "failed", previewError? }
```

The native mapper requires the echoed `file_id` to match the selected row and
accepts only these three lifecycle values. Missing/mismatched identity, unknown
status, pending text, failed text, and contradictory terminal fields fail
closed without altering the source card. Ready text is bounded to 50,000 Swift
characters and discloses truncation. HTML and unknown formats remain inert and
download-only; they are never injected into a web view. Provider failure codes
map through a finite local presentation, so arbitrary server detail is not
displayed. Preview state is in-memory compatibility state and is never written
to SwiftData, logs, drafts, or configuration.

The active chat owns one profile/account-scoped in-memory poll coordinator. It
starts immediately for each distinct visible pending `file_id`, issues the
exact ACL-protected GET at 2.5-second intervals with no transport-level retry,
and permits only one in-flight request per file. It stops on `ready`/`failed`,
401, 403, 404, invalid protocol shape, navigation/profile teardown, scene
inactivity, or cancellation. Transport/5xx failures retain the pending state
and stop after five consecutive attempts; foregrounding starts a fresh bounded
pass. A validated per-file response fans lifecycle fields out to every card
sharing that `file_id` while preserving each tool/agent/message provenance.
Bare SSE updates may wildcard a missing tool or agent coordinate only when one
slot matches; an ambiguous multi-slot update is not assigned by array order and
is instead left for authenticated preview reconciliation. Replayed `pending`
events never regress terminal preview data. A failed terminal preview offers an
explicit user retry; pending state is owned only by the coordinator, avoiding a
second overlapping request path. A 401 expires the native session.

## Exact protected-download route

The native detail screen uses the same proxied byte route as LibreChat's web
client:

```text
GET /api/files/download/:userId/:file_id
Authorization: Bearer <access token>
Accept: application/octet-stream
```

The app supplies the selected account ID as `userId`, but that path value is
not authorization evidence. The pinned `fileAccess` middleware obtains the
caller from the bearer session, loads the exact `file_id`, rejects
cross-tenant access, and then requires either file ownership or inherited
agent VIEW permission (`fileAccess.js:83-148`). The route may stream provider
bytes and returns 501 when the storage strategy has no download stream
(`files.js:526-632`). The native request deliberately omits `direct=true`.

LibreChat also exposes `GET /api/files/download-url/:userId/:file_id`, which
can return a short-lived provider URL plus metadata. The native owner library
does not call that endpoint. Signed URLs, response metadata envelopes, server
storage paths, cookies, and bearer headers never enter SwiftUI state, logs, or
the share item.

The transport uses `URLSession.download(for:)`, moves Foundation's ephemeral
result to a randomly named private staging file, performs the same explicit
profile cookie handling and serialized one-time bearer refresh as JSON
requests, and never materializes the complete response as `Data`. Every 401,
HTTP failure, cancellation, or decoding/validation failure removes its staging
file. The byte request uses `.never` retry; retry remains an explicit user
action.

After a successful non-empty transfer, the app moves the bytes into a
profile/account-isolated Caches namespace, applies iOS file protection, uses a
sanitized display filename with a random prefix, and supplies only that local
URL to `ShareLink`. System Share/Save therefore owns export to Files or another
destination. Downloads older than seven days are pruned opportunistically;
Clear Cache and profile/account purge remove the exact namespace, including
the legacy generated-file cache. A profile/account switch during transfer
deletes the result instead of handing it to the newly selected account.

The UI distinguishes offline, 401, 403, unsupported/missing, cancellation,
and transient failure. It exposes an indeterminate progress state and Cancel,
then a native **Share or save file** control only after the exact selected
`file_id` request completes inside the current view-operation fence. The
downloaded presentation value contains only local/export metadata, not the
server file ID. It does not claim byte-level progress because the current
disk-backed transport does not publish it.

## Exact owner-delete route and ambiguity policy

The pinned owner mutation is:

```text
DELETE /api/files
Authorization: Bearer <access token>
Content-Type: application/json

{
  "files": [{
    "file_id": "file-… | assistant-… | UUID",
    "filepath": "<opaque server storage path>",
    "embedded": true | false,
    "source": "<storage strategy>",
    "temp_file_id": "<optional upload identity>"
  }]
}
```

The route first discards entries without both `file_id` and `filepath`. It
accepts only identities beginning `file-` or `assistant-`, or valid UUIDs. An
empty filtered batch returns 204. The native client mirrors those gates before
network dispatch, sends exactly one selected owner-catalog item, omits every
agent/assistant unlink field, uses `.never` transport retry, and never displays
the opaque `filepath` or `source` required by the wire contract
(`files.js:169-207`; `packages/data-provider/src/types/files.ts:257-274`).

For ordinary owner deletion the server loads the database records, requires
every found row to belong to `req.user.id`, and returns 403 if any fetched row
is not owned. It then invokes `processDeleteRequest`. Agent tool-resource and
assistant unlinking are different branches with different authority and are
not exposed by the owner library (`files.js:209-298`).

The HTTP acknowledgement is not deletion proof. The route ignores
`processDeleteRequest`'s `deletedFileIds` / `failedFileIds` result and can return
`200 { message: "Files deleted successfully" }` even when a storage strategy
reported a failed member. A record that no longer exists can also lead to a
successful empty processing path. Therefore the native repository always
performs a fresh authenticated `GET /api/files` after the attempt—including
after a rejected 4xx other than 401/403, a 5xx, or transport ambiguity—and
checks the raw DTO array for the exact `file_id` before mapping display rows.

- Exact raw identity absent: deletion is authoritatively complete.
- Exact raw identity present: the file is retained, even if conflicting rows
  would be quarantined from the rendered snapshot.
- A 401 from either request expires the selected session.
- A 403 from DELETE preserves the row and shows a permission result without a
  reconciliation request.
- Unavailable catalog reconciliation shows `verification required`, preserves
  the detail, and never issues an automatic second DELETE.

The detail uses a destructive confirmation dialog and explains that the action
targets the selected LibreChat account. While the attempt/reconciliation is in
flight it shows one non-cancellable verification state; this avoids presenting
cancellation as proof that a potentially delivered mutation did not run. A
retained or transient state offers only a new user-confirmed attempt. Proven
absence installs the reconciled owner snapshot in the parent list, removes any
app-private downloaded copy for that detail, announces the boundary to
assistive technology, and dismisses the detail only if it is still visible.
No filename, path, source, request body, owner ID, or storage failure detail is
logged.

## Temporary Chat relationship

Temporary uploads receive a server retention deadline, but the pinned
`GET /api/files` owner query does not exclude them. A Temporary Chat attachment
can therefore appear in this **live** server-owned catalog until the retention
sweep removes it. This does not create an offline native copy; the detail view
shows a valid server-expiry date when the record provides one.

The product must not claim that Temporary Chat files are instantly absent from
all server resource views. The accurate promise remains: no native offline
catalog/transcript, bounded server retention, and deletion according to the
deployment's retention process.

## Explicitly absent operations

The catalog now supports the bounded, reconciled single-owner-file deletion
described above. It does not yet enable:

- attaching an existing catalog file to the current composer;
- bulk cleanup or multi-file deletion;
- binary/image thumbnail preview;
- thumbnails; or
- background synchronization.

Those actions have materially different authorization, endpoint-policy,
storage-strategy, ambiguity, and lifecycle rules. They must not be inferred from
catalog visibility.

Direct/signed URL download remains intentionally unused: the native app takes
the authenticated proxied stream instead. Agent/assistant resource unlinking
remains intentionally absent and must not be inferred from owner-file deletion.

## Verification evidence

The package suite covers the exact catalog and preview bearer GET factories,
echoed preview identity, lifecycle validation, inert HTML handling, bounded
text, unknown-field decoding,
date precedence, malformed identity omission, identical replay deduplication,
conflicting identity quarantine, legacy fallback names, and evolving
source/context preservation, exact protected-download coordinates, unsafe
identity rejection, a disk-backed refresh-after-401 transfer, exact owner-delete
wire fields, server-filtered identity rejection, and `.never` retry. The
complete package run passes **350 Swift Testing tests across 43 suites plus 4
XCTest checks (354 package checks)** at
`/private/tmp/librechat-visual-audit-core`.

Fifteen app model tests cover search/sort, finite source presentation, offline
zero-request behavior, unauthorized clearing, 403/404 distinction, and
transient in-memory snapshot preservation plus preview processing/refresh,
HTML-source state, offline/401, 403/404/405/501 policy, exact download identity,
foreign-result deletion, offline zero-request, session expiry, and download
permission/deployment states, deletion success, retained-server state,
pre-network metadata/offline rejection, 401/403, and verification-required
ambiguity. Four repository tests compile-check exact mutation JSON,
single-dispatch reconciliation, raw-identity retention despite render
quarantine, ambiguous 5xx proof, 403 no-reconciliation, and unavailable proof.
A ninth deterministic XCUITest
fixture opens the account menu, loads an allowlisted two-file catalog, searches,
opens safe details, verifies the raw S3 source is not presented, and observes a
live fixture text preview, protected fixture transfer, native Share/Save
readiness, destructive confirmation, and dismissal only after the fixture
catalog proves absence. These twenty app/UI tests compile in the generic Simulator
build-for-testing at
`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`; they have not executed because
no Simulator was booted. The iOS 17 device-baseline build passes at
`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`.

No authenticated catalog, same-host account switch, real file metadata,
accessibility runtime, real download/provider stream, preview, or owner deletion
acceptance is claimed.

## Remaining acceptance

1. Load the catalog for two accounts on the same host and prove no response can
   cross profile/account identity during a switch.
2. Exercise empty, 401, 403, 404/405, malformed item, conflicting ID, and
   transient refresh states without capturing private filenames.
3. Confirm Temporary Chat file visibility/expiry matches the pinned server's
   retention behavior and no native catalog returns after relaunch offline.
4. Run VoiceOver, largest Dynamic Type, Reduce Transparency, keyboard, Switch
   Control, iPhone, and iPad acceptance.
5. Live-prove text-preview lifecycle, identity mismatch, large-text truncation,
   HTML-source inertness, and account/agent ACL changes.
6. Live-prove protected local/S3/OpenAI-backed transfers, cancellation,
   refresh-after-401, insufficient-space handling, namespace cleanup, and the
   system Save to Files handoff without recording private filenames.
7. Live-prove owner deletion against local, S3, and provider-backed records,
   including 200-but-retained storage failure, 403, lost response, failed
   reconciliation, same-host account switching, and downloaded-copy cleanup.
8. Design reattach and agent/assistant resource unlinking as separate exact
   contracts before enabling either corresponding control.
