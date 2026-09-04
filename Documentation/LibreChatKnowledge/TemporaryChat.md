# Temporary Chat contract and native privacy boundary

This document records the Temporary Chat contract in the pinned LibreChat source
baseline `b2128a7d189ac020ebb6e49a57ee986e98326b77` and the corresponding native
iOS behavior. Temporary Chat is not an incognito transport and it is not a
client-only display mode. It is an authenticated, permission-gated server
retention policy that must remain attached to the exact conversation, messages,
generation, files, and recovery lifecycle.

## Capability and authorization evidence

The authenticated startup interface may expose:

```text
interface.temporaryChat: Bool
interface.temporaryChatRetention: 1...8760 hours
```

The schema defaults `temporaryChat` to enabled. The server retention helper uses
720 hours (30 days) when neither the environment nor interface configuration
supplies a value, and clamps runtime values to 1...8760 hours
(`packages/data-provider/src/config.ts:1446-1447,1529`,
`packages/data-schemas/src/utils/tempChatRetention.ts:6-79`). The current role
must separately grant `TEMPORARY_CHAT.USE`
(`packages/data-provider/src/permissions.ts:30,84,186-189`,
`packages/data-provider/src/roles.ts:73,167`).

Native availability therefore requires all of the following:

1. a successful authenticated `/api/config` response for the active account;
2. interface policy that is not explicitly disabled;
3. a successful exact current-role response;
4. `permissions.TEMPORARY_CHAT.USE == true`;
5. an online authenticated session.

Anonymous config, a cached policy from another account, a missing role, a failed
role lookup, and a stale authenticated-policy refresh are not authorization.
The native `TemporaryChatPolicy` keeps interface and role evidence separate and
the entry point fails closed if either proof is absent.

## Creation and immutability

LibreChat's web control is available only before a conversation has started. It
disappears after the conversation has a real ID, after the first message exists,
or while submission is in progress
(`client/src/components/Chat/TemporaryChat.tsx:14-65`). Navigating to a new
conversation resets the mode to the configured default; reopening a temporary
conversation derives the mode from its persisted metadata
(`client/src/routes/ChatRoute.tsx:141-151`).

The native client follows the stricter invariant:

- Temporary Chat is chosen in the New Chat sheet before the local draft is
  created.
- Changing the target creates another local draft and preserves the temporary
  bit; it never mutates an existing server conversation.
- There is no in-place permanent-to-temporary or temporary-to-permanent toggle.
- The conversation list filters temporary rows, including cached legacy rows,
  while the active route retains the in-memory conversation identity.

## Generation wire contract

Every generation start carries the exact Boolean:

```json
{
  "isTemporary": true
}
```

The web payload builder forwards that value unchanged
(`packages/data-provider/src/createPayload.ts:14-53`), and the agents controller
stores it in generation metadata and every persistence path
(`api/server/controllers/agents/request.js:909,1014,1420-1440,1588`). Resumed
human-in-the-loop work restores the authoritative value from the job rather than
trusting a new client body (`api/server/controllers/agents/resume.js:175,261,832-835`).
The server also skips automatic title generation for temporary conversations
(`api/server/services/Endpoints/agents/title.js:40-62`,
`api/server/controllers/agents/request.js:1222`).

Native implications:

- `isTemporary` is derived from the authoritative conversation or the local
  pre-send draft and is never hard-coded.
- Local-to-canonical promotion preserves the bit.
- A server conversation/message with `isTemporary == true` is temporary.
- For compatibility with LibreChat's own helper, missing `isTemporary` plus a
  non-null `expiredAt` is also treated as temporary
  (`client/src/utils/conversation.ts:3-5`).
- A later profile capability refresh must not clear the in-memory set of known
  temporary conversations unless the profile/account namespace changes.

## Server persistence and retention

Temporary does not mean “never written to the server.” The server writes
conversation and message documents with `isTemporary:true` and a future
`expiredAt`. Saving later activity computes a new deadline from the current
time, so the effective deadline moves with saved activity
(`packages/data-schemas/src/methods/conversation.ts:250-283`,
`packages/data-schemas/src/methods/message.ts:106-138`). MongoDB TTL indexes on
conversation and message `expiredAt` remove records after that deadline
(`packages/data-schemas/src/schema/convo.ts:59-67`,
`packages/data-schemas/src/schema/message.ts:198-203`). TTL deletion is
asynchronous MongoDB behavior, so UI copy must describe a scheduled retention
deadline rather than promise deletion at an exact second.

List and search visibility is intentionally different from direct ownership
reads:

- normal conversation/project/search visibility uses
  `buildRetentionVisibilityFilter`, which includes only permanent active rows
  and excludes temporary rows immediately
  (`packages/data-schemas/src/utils/retention.ts:20-29`,
  `packages/data-schemas/src/methods/conversation.ts:565-610`,
  `packages/data-schemas/src/methods/chatProject.ts:188`);
- direct `getConvo(user, conversationId)` and message reads remain possible for
  the owning account until records expire or are deleted
  (`packages/data-schemas/src/methods/conversation.ts:105-116`,
  `packages/data-schemas/src/methods/message.ts:498-521`).

That distinction is why the native active screen can continue a temporary chat
while it never appears in the library.

## Files and generated output

Conversation file uploads append multipart `isTemporary=true` when the active
chat is temporary (`client/src/hooks/Files/useFileHandling.ts:59,203-204`). File
retention is resolved from the request/conversation by the server
(`api/server/services/Files/retention.js:15-34`). Image/code tools also inspect
the generation request's temporary bit, so resume restores it before tools run
(`api/server/controllers/agents/resume.js:832-835`).

The native client therefore:

- sends multipart `isTemporary=true` for staged Temporary Chat uploads;
- removes the staged local file and its upload record after confirmed message
  attachment rather than retaining attached-file recovery metadata;
- discards any unfinished temporary upload recovery record and staged local
  copy during process restoration;
- does not silently strip an attachment to make a send appear successful.

Server-side retention remains authoritative for a remote file that was already
uploaded. Local removal does not claim an immediate remote delete.

## Native persistence policy

SwiftData is an offline cache and recovery store for normal conversations. For
Temporary Chat it is deliberately not a transcript store. The native adapter
does not persist:

- conversation-list rows;
- messages;
- drafts;
- generation checkpoints or nonterminal recovery handles;
- pending human interactions;
- durable follow-up queue items;
- terminal recoverable steers;
- attached upload recovery metadata.

If authoritative conversation/message metadata reveals that content cached by
an older build is temporary, the repository purges that exact
profile/account/conversation namespace. Purge includes conversation, messages,
draft, follow-up queue, generation/pending-action recovery, matching uploads,
and staged local files. It never purges another profile or account and it never
deletes the remote conversation.

This policy intentionally means force-quit/relaunch cannot restore a Temporary
Chat transcript or resume its generation from local state. The server may still
retain and directly serve the conversation until its deadline, but the current
native product does not create a durable library route to rediscover it.

## Presentation contract

Before creation, the New Chat privacy section states both truths:

- the chat is not shown in history and is not stored for native offline
  browsing;
- LibreChat retains server records until its configured retention deadline.

Inside the chat, a persistent semantic notice repeats the mode. When the server
returns `expiredAt`, it presents that scheduled deadline; otherwise it refers to
the server's retention policy. The notice is ordinary opaque content—not glass,
not a message bubble—and combines into one accessible element.

The composer remains editable in memory. Durable queue/recovery controls are
unavailable because they would contradict the local storage promise. Temporary
mode must survive target changes and canonical identity promotion.

## Security and privacy non-claims

Temporary Chat does not imply:

- end-to-end encryption;
- zero server logging;
- immediate deletion;
- exclusion from infrastructure backups outside the application contract;
- removal from a provider that LibreChat called;
- anonymity from the selected LibreChat account;
- safe disclosure of secrets to models or tools.

The pinned owner `GET /api/files` catalog does not filter Temporary Chat
uploads. An attachment may remain visible in the live, authenticated native
Files library until the server retention sweep deletes it. The app does not
cache that catalog offline and shows the server expiry when the record provides
one; see [FileCatalogAndLibrary.md](FileCatalogAndLibrary.md).

Never label the feature “incognito” or “not stored.” The accurate statement is:
not listed in conversation history, not retained in this app's offline cache,
and scheduled for server deletion under the deployment's retention policy.

## Implemented verification

Package contracts cover authenticated config derivation, invalid retention,
anonymous/fail-closed behavior, exact role permission, DTO mapping, fractional
dates, and legacy inference. The current full package run passed **349 Swift
Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at
`/private/tmp/librechat-visual-audit-core`.

App source now covers the exact generation flag, preexisting-cache purge,
non-persistent drafts, list exclusion, local-to-canonical preservation,
temporary upload handling, durable queue exclusion, and in-chat disclosure.
The three new app privacy/wire tests and an eighth deterministic XCUITest for
the toggle, pre-send explanation, creation, and in-chat notice compile in the
successful generic Simulator build-for-testing at
`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`. A generic
iOS 17 device build passed at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`.
No Simulator was booted, so these four additions have not executed and no live
Temporary Chat server acceptance is claimed.

## Remaining acceptance

1. On an authenticated disposable account, prove config plus role gating and
   verify a denied role never sees the toggle.
2. Create a temporary chat, send a non-sensitive canary, and confirm the v2
   receipt/SSE lifecycle without capturing request bodies.
3. Verify it never enters list/search/project results, but the active screen can
   continue it before expiry.
4. Upload a disposable file, confirm temporary multipart handling, then confirm
   no local staged copy/upload record returns after relaunch.
5. Background and force-quit during generation; verify the app makes no false
   recovery promise and no transcript appears from local cache.
6. Confirm direct server content becomes unavailable after the deployment's TTL
   behavior, allowing for MongoDB TTL monitor delay.
7. Repeat on two same-host profiles and verify no capability, cache, upload, or
   conversation identity crosses the account boundary.
