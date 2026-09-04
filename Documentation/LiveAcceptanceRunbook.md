# Live acceptance runbook

This runbook promotes a capability from fixture/build evidence to authenticated
live evidence without capturing credentials, message content, or server record
identifiers. It is intentionally limited to the app's finite OSLog vocabulary.

## Preconditions

- Use the manually configured iPhone 17 Pro Simulator and the saved LibreChat
  profile. Never boot, erase, reset, or replace a Simulator as part of capture.
- Run one generation at a time so timestamps establish ordering without logging
  conversation, message, stream, profile, or account identifiers.
- Do not enable CFNetwork diagnostics, packet capture, proxy inspection, or
  request/response body and header logging.

Discover an already-running Simulator:

```sh
xcrun simctl list devices booted
```

If this prints no booted device, stop and ask the user to open the Simulator.

## Deterministic UI-test fixture gate

The `LibreChatUITests` target has seven previously executed deterministic UI
flows covering
New Chat dismissal/navigation and target selection; existing-row navigation to
the matching conversation/message plus composer target/attachment/server
assertions; manual scroll followed by Jump to latest; exact message-search
branch focus; and one-shot conversation-fork and response-regeneration review.
Five newer compile-only flows cover Temporary Chat setup/disclosure, the
live-only Files catalog/search/safe-detail/preview/protected-download/confirmed-delete path,
reviewed New Chat preset application, native preset creation, and basic native
agent creation.
Launching
with `-ui-test-fixtures` is Debug-only and injects in-memory profile/cache/
secret stores plus an allowlisted URL protocol; it does not use Keychain or a
real network. The current generic iOS Simulator build-for-testing artifact is
[`/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived),
with the generic device artifact at
[`/private/tmp/LibreChatIOS-SkillManagement-Device-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Device-Derived).
The UI-test bundle executed **7/7 deterministic flows** on iPhone 17 Pro,
iOS 26.5, at
[`/private/tmp/LibreChatIOS-UIFinalTests-20260819.xcresult`](/private/tmp/LibreChatIOS-UIFinalTests-20260819.xcresult).
Those fixtures prove the native interaction shell, not live-server behavior.
The current package result passed **367 Swift Testing tests across
44 suites plus 4 XCTest checks (371 package checks)** at
`/private/tmp/librechat-skill-management-core`. The complete app
unit/model/repository target previously passed **371/371** on iPhone 17 Pro, iOS 26.5, at
[`/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`](/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult).
One hundred twenty-six newer app/model/repository tests compiled in the generic Simulator build
but have not executed because no Simulator was booted. The six newer
deterministic XCUITest methods—Temporary Chat, Files, reviewed-Preset
application, native-Preset creation, basic native-agent creation, and artifact
card → workspace → Back—also
compile but have not executed. Thirteen deterministic UI methods exist in total;
only the historical seven have executed, with six newer methods compile-only,
including the artifact card → workspace → Back flow.
The preserved production-like V1 store also migrated in place to V2 and retained
the saved server profile. No microphone/audio output or authenticated live
network acceptance was performed.

Focused `TargetCatalogTests` execute in the package result. The app Architecture
tests for authenticated catalog requests, New Chat target state,
conversation/history hydration, identity promotion, V1 reopen safety, and
terminal-leftover persistence all ran inside the 371/371 Simulator result.
Terminal classification must remain decoded from the existing V1
snapshot blob—do not quarantine, reset, or mutate a user's store to perform
acceptance.

## Skills live gate

The Core Skills contract is build-verified but not live-verified. After the
user opens the already configured Simulator and completes login, run this
finite sequence without recording prompts, skill bodies, IDs, or tokens:

1. Confirm the account has `SKILLS.USE` and that the agents capability list
   advertises `skills`; otherwise record a truthful disabled result.
2. Open the native Skills picker for an ephemeral target and verify catalog
   paging, loading/empty/error states, cancel-without-send, and the visible
   availability explanation for inactive/model-only/excluded rows.
3. Select one available Skill, change target/model or account state, and verify
   fresh preflight blocks the send until the selection is reviewed again.
4. Send one manual Skill selection and verify the user message preserves its
   `manualSkills` pills after history reload; never print the selected name in
   the capture log.
5. Regenerate the same turn and verify the persisted selection is replayed,
   while a fresh compose selection is not accidentally drained into replay.
6. Repeat with a saved-agent allowlist and model-spec `true`, `false`, empty,
   and name-list scope where the server account exposes those targets.
7. Open Settings → Skills. Verify search and All/Active/Inactive filters, then
   toggle one mutable row. Confirm only one saving state is admitted and the
   returned server state replaces the displayed account setting.
8. Exercise a lost-response test account/proxy condition only if it can be done
   without logging bodies: verify the app performs one state read and never a
   second POST. Repeat 401 and 403 to prove catalog clearing/session expiry vs
   permission loss. Restore the original account state with one explicit user
   action after the result is known.

Any lost, 401, 403, malformed, duplicate-name, target-drift, or ambiguous
response is a failed/uncertain live gate, not a reason to retry a generation
POST. Authoring, import/files, durable pending-selection restoration, and
background/relaunch Skill recovery are deferred and should be reported
separately.

## Privacy-safe capture

Replace `<BOOTED-UDID>` and `<APP-BUNDLE-ID>` with the exact installed values
and run the command in a PTY. The project default is
`com.berry13.LibreChatIOS`; a preserved-container acceptance build may use a
different explicit bundle ID, and `AppLog` uses that runtime bundle ID as its
subsystem. Debug level is required because successful request/response and
refresh coalescing milestones are deliberately debug-level.

```sh
xcrun simctl spawn <BOOTED-UDID> log stream \
  --style compact \
  --level debug \
  --predicate 'subsystem == "<APP-BUNDLE-ID>" AND (category == "transport" OR category == "authentication" OR category == "compatibility" OR category == "generation" OR category == "persistence" OR category == "uploads")' \
  | tee /private/tmp/librechat-live-acceptance.log
```

Stop the stream with Control-C only after the chosen flow is complete.

## Core-loop acceptance

### Password login

Required order:

```text
Password login started
HTTP started route=auth-login method=POST
HTTP responded route=auth-login method=POST status=200
Credential revision changed reason=authenticated
Password login completed outcome=authenticated
Authenticated session committed to app state
```

`requires-2fa` and `rejected` are valid bounded login outcomes, but neither is
evidence of a committed signed-in session.

### Cookie-backed restoration and one 401 recovery

Terminate and relaunch without signing out. A successful restoration requires:

```text
Refresh requested
HTTP started route=auth-refresh method=POST
HTTP responded route=auth-refresh method=POST status=200
Credential revision changed reason=refreshed
Refresh succeeded
Authenticated session committed to app state
```

A controlled expired-access-token test additionally requires one 401, one
serialized refresh, a successful second attempt, and a closing
`401 recovery completed ... outcome=succeeded`. Do not claim this branch unless
the server actually expires or rejects the access token.

### Target catalog and chat hydration

1. Open New Chat online and verify its choices correspond to the current
   authenticated config, endpoints, models, saved-agent ACL, and user-key
   status. Record the server's explicit default and every compatibility notice.
2. Force a catalog refresh failure. Existing stale choices must not become
   newly authorized. If a successful policy refresh removes the selected
   choice, Create must remain disabled until the user explicitly selects again.
3. Open an existing conversation through both the conversation list and a
   partial search result. Sending and attachment staging must stay disabled
   until canonical conversation routing is hydrated; sending additionally
   waits for authoritative message history.
4. Repeat with transport unavailable. Cached messages must remain browsable and
   the draft editable/persisted, while send and uploads remain unavailable.
5. Complete a first send from a local New Chat. After identity promotion,
   verify the app refetches the canonical conversation and history rather than
   retaining inferred local routing.
6. Select a non-default target and create a local draft successfully. Reopen
   New Chat and verify a fresh catalog selects that exact target only while it
   remains authorized. A failed creation, a canonical/server-created result,
   or an option removed by fresh policy must not write or resurrect it.
7. Repeat across two accounts on one profile and a sibling profile. Verify the
   stored choice never crosses the exact profile/account namespace, survives a
   healthy V1 reopen, and disappears with the owning namespace purge.
8. Exercise one authenticated custom endpoint whose display/name component
   includes spaces or punctuation and whose resolved endpoint configuration
   advertises `type: custom`. Verify generation sends that name as one encoded
   path component and preserves the exact endpoint/type body fields.
9. Repeat with an untyped unknown endpoint, `assistants`/`azureAssistants`, and
   endpoint names colliding with the reserved `abort`, `resume`, or `steer`
   control routes. They must remain read-only: draft editing stays available,
   while catalog selection, uploads, queue admission, and generation POST are
   disabled with a truthful compatibility reason.
10. Make authenticated `/api/config` temporarily unavailable after a valid
    login. The app must remain signed in but hide account-gated Agents, Memory,
    MCP, speech, sharing, Projects, bookmarks, and prompt permissions. Settings
    must explain the verification failure and expose **Retry server feature
    check**. After policy recovery, one explicit retry must restore only the
    freshly proven features. A 401 during that retry signs the account out.
11. Configure one visible model spec with a harmless test MCP name plus mixed
    search/file/code/memory flags and `artifacts: true`. Select it in New Chat.
    Before sending, verify the composer execution envelope lists only the
    expected safe tool categories and MCP count. It must not show the MCP name
    or an artifact-mode identifier.
    With an operator-controlled redacted request capture, verify the start body
    carries the spec name and an `ephemeralAgent` object with exact `mcp`,
    `web_search`, `file_search`, `execute_code`, `memory`, and
    `artifacts: "default"` values. Application logs must still contain none of
    those names or payload values.
12. Repeat with a named artifact mode and with artifacts false/absent. Verify
    the exact wire values are respectively that name and an empty string. Then
    open a persisted conversation that names the visible spec and prove its
    next send restores the same companion object after authoritative routing
    hydration.
13. Exercise enforced and non-enforced forms. The server remains authoritative
    for private prompt, skills, subagent, and other hidden policy; the client
    must not reconstruct or expose those fields. A malformed visible companion
    value must quarantine that target rather than silently sending a weakened
    configuration.
    A verified spec with every public companion tool disabled must explicitly
    show **Tools: None**; a non-spec or otherwise unknown scope must omit the
    tools line rather than claiming none.
14. Queue a harmless follow-up, then change the visible spec's public companion
    configuration before the predecessor finishes. The older queue fingerprint
    must not silently drain under the changed tool/artifact policy; it remains
    blocked for explicit review.

Do not promote this slice without authenticated proof. Recent-target
persistence, purge/reopen, and model tests passed inside the 371/371 Simulator
result. The shared endpoint policy, model-spec companion policy, and safe
execution-disclosure presentation pass package coverage; three endpoint
regressions, two companion wire/hydration app regressions, and one disclosure
redaction app regression compile, but still need the authenticated checks
above.
Grouped/searchable selection, in-chat target switching, assistants, key
credential use inside an authenticated generation, scoped icon loading/rendering, and a direct visual
competitor capture remain separate unfinished work.

### User-provided provider credentials

Use only a disposable provider credential and test account. Never capture the
secret field, request body, clipboard contents, or provider response in a
screenshot, log, proxy, or result bundle.

1. Open **Settings → Provider credentials** online. Compare only provider name,
   storage state, and expiry with the server-owned settings UI. The native app
   must never display or fetch an existing secret value.
2. Add a disposable key with a short expiry. Verify the relevant New Chat
   target becomes selectable only after fresh authenticated key-status and
   target-catalog reads. The secret must leave editor state before the first
   network suspension and must not survive backgrounding or sheet dismissal.
3. Replace the stored key. A confirmed response plus fresh status may update
   the row. A lost response or malformed acknowledgement must report delivery
   uncertainty and must not issue a second PUT or claim which value is stored.
4. Revoke the key through the destructive confirmation. Only an explicit
   server acknowledgement, or a post-failure status read proving the key is
   missing, may mark it removed. Transport/5xx ambiguity must not repeat the
   DELETE automatically.
5. Repeat with two accounts on the same host and a sibling server profile.
   Status, target availability, mutation state, and credentials must never cross
   the exact profile/account namespace. Offline mode must expose no cached key
   status or mutation controls.
6. If supported by the deployment, separately exercise simple, OpenAI/custom,
   Azure OpenAI, Google API-key/service-account, and Bedrock forms. Verify the
   server accepts the pinned wrapper shapes without exposing their contents in
   application logs.

Promotion requires one authenticated add, replace, revoke, target-availability,
same-host isolation, background clearing, and controlled ambiguous-delivery
proof. Package and compile-only repository/model tests do not substitute for
this live acceptance.

### Live preset library, reviewed application, and bounded creation

1. From New Chat, refresh and open **Preset**. Confirm the visible order matches
   the owner account's web preset order and that the default preset is marked.
2. Search by preset title and model label. Open a compatible endpoint/model
   preset with a prompt prefix and expand **Instructions**. Verify the complete
   reviewed text is correct before Create.
3. Create the chat. Confirm no message or generation starts, the composer stays
   editable, and the execution summary shows the exact reviewed target.
4. Send one harmless test message, then verify on the server that the request
   used the reviewed prompt prefix. Do not capture the prefix in logs or
   screenshots.
5. Create or use a preset containing one of `temperature`, `tools`,
   `web_search`, reasoning settings, files, `presetOverride`, or a future field.
   Confirm it remains visible but Create is disabled with a bounded reason.
6. Remove/deauthorize a preset's model or agent after the library loads. Create
   must fail closed after refresh; no first-available target may be substituted.
7. Switch between two accounts on the same host. Preset titles/instructions
   must never cross accounts, survive logout as offline content, or appear in
   transport/authentication logs.
8. Force one 401 during `GET /api/presets`; verify the shared refresh succeeds
   once. Exercise 403/404 and transient failure; manual target selection must
   remain available, while stale preset rows must not remain actionable.
9. From the native creation path, select a fresh live target, enter a title and
   optional harmless prompt prefix, then save. Verify the app refreshes the
   target catalog immediately before one `POST /api/presets`, sends only the
   reviewed UUID/title/routing/prompt fields, and does not send default, tools,
   files, ownership, parent-message, or ephemeral-agent fields.
10. Confirm the response must echo the exact UUID/title/target/prefix before
    the app calls it saved. Force the pinned server's message-only 201 failure
    envelope and an interrupted post-dispatch response; verify a new save is
    locked, exactly one owner-list reconciliation is offered, and no automatic
    repost occurs. Verify 401 and definite 4xx remain errors rather than an
    ambiguous success.

Promotion requires one authenticated compatible apply/send proof, one blocked
unimplemented-setting case, stale-target failure, same-host account isolation,
one exact native-create confirmation, one message-only/ambiguous-create
reconciliation proof, and VoiceOver/maximum-Dynamic-Type review of search,
instruction disclosure, blocked state, removal, and Create.

### Live basic private-agent creation

1. With a verified authenticated and online account that has `AGENTS.USE` and
   `AGENTS.CREATE`, open the native Agent-create form. Remove either role,
   force offline state, or hide the Agents capability, and verify Create does
   not send network traffic.
2. Select a provider/model from a fresh `/api/models` response. Change or
   deauthorize that target before confirmation and verify the native app
   refreshes and blocks rather than substituting another model.
3. Create a harmless private agent. Verify exactly one `POST /api/agents` with
   the reviewed basic fields; it must contain no tools, actions, files, MCP,
   skills, subagents, credentials, avatar, or sharing/ACL data.
4. Verify that only a `201` with a valid generated ID and the exact reviewed
   request echo becomes a visible native success. A message-only or mismatched
   `201` must not be shown as created.
5. Interrupt the response after dispatch. The app may make one owner-scoped
   GET reconciliation, then must enter finite outcome-unknown with no automatic
   repost. Confirm a post-response 401 or browser redirect likewise never
   replays the mutation, while ordinary GET/idempotent auth recovery still
   works.

Promotion requires capability/role/offline gates, reviewed-target drift,
allowlisted-body inspection, strict-201 success, ambiguous reconciliation,
post-response authentication behavior, same-host account isolation, and
VoiceOver/maximum-Dynamic-Type review. Advanced/full authoring, avatar,
tools/actions, and share/ACL management are not in this acceptance slice.

### Read-only MCP connection catalog

1. Use an account whose role advertises `MCP_SERVERS.USE`, open Settings, and
   confirm that Connections performs one authenticated server-list request and
   one aggregate status request. Verify that each visible row/detail is limited
   to title, bounded description, transport, management source,
   direct-versus-agent availability, connection state, and authorization state.
2. Compare the native result with the server-owned UI or an operator-approved
   redacted response. A missing or unknown status must remain visibly unknown;
   it must never render as connected or authorized.
3. Search using only visible title/description. Confirm no URL, header, custom
   variable, credential, OAuth token, raw tool payload, or raw server identifier
   appears in UI, accessibility values, logs, screenshots, or persisted cache.
4. Take the app offline after a successful load. The screen must clear the live
   catalog and explain that connection state is unavailable offline rather than
   showing stale private metadata.
5. Verify a role without `MCP_SERVERS.USE` cannot enter the catalog. Exercise a
   controlled 403 and 401 separately: 403 stays a permission result; 401 clears
   the catalog and follows normal session-expiry handling.

This acceptance is read-only. Do not enter auth values, select tools, start
OAuth, or mutate a server from the native app; those flows are not implemented.
The package mapper tests and generic app build do not substitute for these live
role, privacy, and status checks.

### Owner Files preview and protected download

1. Open **Account → Files** for the selected test account. Confirm the live
   catalog loads, local search/sort work, and no raw storage path, owner ID,
   tenant ID, signed URL, provider metadata, or extracted-text envelope appears
   in UI or redacted logs.
2. Open one consented test record. Confirm `GET /api/files/:file_id/preview`
   is ACL-authorized for the same account, returned identity matches, HTML (if
   used) is inert source, and the preview disappears after leaving the detail
   screen or relaunching offline.
3. Tap **Download securely**. Capture only the finite transport route/status
   marker, never the account ID, file ID, filename, query, headers, cookies, or
   bytes. Verify the request is `GET /api/files/download/:userId/:file_id`, has
   bearer authorization and `Accept: application/octet-stream`, omits
   `direct=true`, and never calls `/download-url`.
4. Force one access-token expiry before a consented transfer. Confirm exactly
   one serialized cookie-backed refresh occurs, the rejected staging file is
   removed, and the successful transfer is not automatically replayed after a
   later transport ambiguity.
5. On success, confirm only **Share or save file** appears, the system share
   sheet can Save to Files, the local filename is sanitized, and the local URL
   resides in the selected profile/account cache. Confirm Clear Cache removes
   that namespace without touching another same-host account.
6. Cancel a sufficiently large consented transfer. Confirm no Share/Save action
   appears and no staging or final cache file remains. Repeat a profile switch
   during transfer and confirm the completed bytes are discarded rather than
   adopted by the new account.
7. Exercise 401, 403, 404, 501, server 5xx, insufficient device space, and
   connection loss. Confirm each produces the truthful bounded state and never
   exposes server body text or a provider URL. Run at least one local/S3-backed
   file and, when available, one OpenAI-backed file because storage strategies
   have different server stream implementations.
8. For a separate purpose-created owner file, tap **Delete from LibreChat** and
   cancel the first confirmation. Confirm zero DELETE requests and no catalog
   change. Confirm again, then require exactly one `DELETE /api/files` followed
   by `GET /api/files`; do not capture either body. The detail may dismiss only
   when the fresh raw catalog no longer carries the exact identity.
9. Use a controlled storage stub that returns HTTP 200 while retaining the file
   record. Confirm the detail stays open with a retained explanation, the row
   remains after refresh, and the client sends no automatic second DELETE.
10. Separately exercise 403, lost response/5xx followed by absent proof, and
    unavailable reconciliation. A 403 must perform no catalog reconciliation;
    an ambiguous attempt may become success only through raw absence proof;
    unavailable proof must show **verification required** and preserve the
    detail. Repeat with two accounts on the same host and switch during the
    attempt: neither a result nor a downloaded local copy may cross accounts.
11. After proven deletion, confirm any app-private downloaded copy for that
    detail is removed, another account's cache is untouched, and VoiceOver
    announces one final boundary. Agent/assistant unlinking and bulk deletion
    are outside this acceptance and must not be inferred from the owner action.

Do not capture private filenames or file contents. Use a purpose-created test
record with non-sensitive bytes and record only route class, finite status,
account-isolation result, and local cleanup result.

### Camera and upload acceptance

1. Open the single attachment menu and verify Photo Library, Take Photo, and
   Choose File are visible together. Confirm that Take Photo checks camera
   availability and authorization before presenting the full-screen native
   camera. Denied permission must offer Settings; unavailable or restricted
   cameras must leave Photo Library available.
2. Capture a photo and verify the staged payload is an orientation-normalized,
   metadata-free JPEG, no larger than 4096 pixels on its longest side, using
   the native `.88` compression default. Choose an HEIC or PNG from Photo
   Library and verify it is also decoded through that same normalization path,
   never labelled JPEG merely because it came from the picker. Then verify an
   advertised `clientImageResize` policy applies its additional configured
   resize/quality step.
3. For a dimensioned image sent to a non-Assistants target, verify
   `POST /api/files/images`; verify Assistants targets and non-image files use
   `POST /api/files`. Check that multipart `file_id` is the client UUID, the
   acknowledgement binds it to `temp_file_id`, and the returned server
   `file_id` is retained for the generation payload.
4. Exercise a lost response, HTTP 5xx, and malformed acknowledgement. Each
   may perform one owner-scoped `GET /api/files` reconciliation by
   `temp_file_id`; a unique match completes the upload. An unresolved result
   must become `deliveryUncertain` with blind retry disabled. Tap the native
   Check action and verify it performs only that GET reconciliation and never
   reposts the bytes. Verify the server's `clientImageResize` configuration
   is decoded and applied.
5. Repeat with offline/background interruption and an expired upload hold.
   Record separately whether staged files, usage renewal, and a later send
   recover. Background `URLSession` upload behavior, live image-detail
   processing, microphone/provider STT, manual Read Aloud playback, automatic/
   background/full-duplex voice, and authenticated
   live upload proof remain pending until exercised.

### Native speech-to-text acceptance

1. After authenticated startup, verify the app requests
   `GET /api/files/speech/config/get` and exposes dictation only when the
   response proves external STT and does not disable speech-to-text. A stale or
   incomplete capability snapshot must keep the microphone action unavailable.
2. Start dictation and verify microphone denial offers Settings. On success,
   record a bounded temporary mono 16 kHz AAC `.m4a`; verify the five-minute/
   25 MiB local limits, interruption handling, and that cancellation or scene
   inactivity removes the temporary audio.
3. Stop and transcribe. Verify exactly one non-retried multipart
   `POST /api/files/speech/stt` with field `audio` and optional validated
   language. A 401 may perform the existing serialized authentication refresh;
   429 presents the server retry duration without scheduling a retry. Lost,
   5xx, or malformed responses must not repost automatically.
4. Verify the transcript is inserted into the existing editable composer draft
   and is never sent automatically. Explicit retry must state that provider
   work may repeat. Confirm no audio, transcript, token, cookie, or multipart
   body appears in logs or SwiftData.
5. Record separately that microphone/audio-session behavior, provider
   interoperability, and VoiceOver/Dynamic Type remain unproven until exercised.

### Native Read Aloud acceptance

1. After authenticated startup, verify the same speech configuration request
   exposes Read Aloud only when external TTS is proved and text-to-speech is not
   disabled. Confirm it is absent offline, on unfinished/local/user/system rows,
   and when the projected assistant prose is empty.
2. Open **Choose reading voice** from a finished response and from the active
   compact player. Verify one authenticated idempotent
   `GET /api/files/speech/tts/voices`, opaque server ordering, no `ALL` option,
   and no synthesis request merely from selecting or saving. Confirm Server
   default remains distinct from each named voice, the exact selection survives
   navigation and app relaunch only for the same profile/account, sibling
   accounts cannot read it, and Clear Cache removes it. Remove the selected
   voice from a later server response and verify the picker visibly falls back
   to Server default rather than claiming the stale name remains active.
3. From a finished assistant row, invoke the context-menu and VoiceOver
   `Read response aloud` actions. Verify exactly one non-retried multipart
   `POST /api/files/speech/tts/manual` with `input` and only the configured
   optional `voice`; the source must omit reasoning, code, tool/activity/error
   content, artifacts, citation markers, and hidden metadata.
4. Require a nonempty MPEG response before playback. Verify the compact active
   reader presents preparing, playing, paused/interrupted, progress, failure,
   explicit retry, and stop states with 44-point controls and meaningful
   VoiceOver labels. Starting another response must release the first player.
5. Exercise 401, 429 with `Retry-After`, 5xx, malformed/truncated MP3, and lost
   response. Only the existing one-time 401 refresh may replay; no other outcome
   automatically resubmits synthesis. Explicit retry must disclose possible
   repeated provider work.
6. While playing, edit/regenerate or switch the selected branch, navigate away,
   start dictation, switch profile/account, and background the app. Exact content
   revision/profile/account and the process-wide audio lease must stop stale or
   competing playback. Confirm audio/text/request bodies never enter SwiftData,
   logs, or persistent caches.
7. Record automatic/streaming TTS, captions, background/lock-screen audio,
   remote controls, barge-in, and full-duplex voice as unimplemented rather than
   treating manual Read Aloud and voice selection as proof of them.

### HITL ownership and resume

1. Pause an exact v2 generation on a two-tool approval. First submit an
   incomplete or disallowed decision batch and verify **zero** HTTP requests,
   including no conversation-hydration GET. Repeat for a user-question batch
   containing a duplicate question ID; it must also reject before network use.
   Then submit the complete batch and verify exactly one POST to
   `/api/agents/chat/resume` includes the original conversation, non-negative
   epoch, protocol `2`, action ID, endpoint/agent, and one allowed decision for
   every tool-call ID.
2. Accept only an acknowledgement proving `status:"resuming"`, the same
   conversation and stream, and protocol `2`. A missing or mismatched field is
   a potentially consumed outcome after dispatch: reconcile the exact action,
   and verify that no second decision POST occurs.
3. After a valid ACK, cancel/fail the SSE reopen. Repeat with a lost response
   where reconciliation proves the action was consumed, then make the reopen
   raise `CancellationError`. In both cases the old pending interaction must
   disappear, streaming must stop, and a recoverable Resume action must appear.
   Resume may reopen the stream but must not restore or repost the
   approval/answer.
4. Reconcile an unchanged pending payload and verify in-progress safe input is
   retained. Reconcile the same action ID with changed prompt/options/tool
   decisions and verify all view-owned answer/selection/edit state is reset.
5. Attempt response, Stop, and stream attachment with a handle from another
   profile/account. Each must fail before a network request or UI mutation.
6. Inject a fatal stream error and verify no reconnect loop occurs; the exact
   saved handle remains available for explicit reconciliation. Transient
   transport and rate-limit behavior remains a separate bounded-retry path.
7. Verify external-auth actions open only HTTPS URLs, plus loopback HTTP for
   local development. Reject custom schemes, non-loopback HTTP, credentials,
   fragments, and malformed URLs.

The direct validation, tool-approval request/body, ambiguity, cancellation,
ownership, and ACK fixtures execute in the 371/371 app result. Do not claim
live HITL safety until these steps, relaunch persistence, approval
races, accessible focus return, and a real authenticated deployment are
exercised.

### Generation v2 start and completion

Send a harmless prompt with a unique canary that must not appear in the log.

```text
Generation start requested; protocol=2
HTTP responded route=generation method=POST status=200
Generation start installed; status=started|resumed protocol=2
Generation stream connecting; resume=false
Event stream opened route=generation status=200
Generation stream reached a terminal state; kind=completed
```

The installed marker is emitted only after validating the receipt coordinates,
persisting the initial checkpoint, installing the reducer, and registering the
in-memory snapshot.

Reload the conversation and verify the authoritative history contains the
completed response exactly once.

### Stop

Start a response long enough to stop before completion:

```text
Generation stop requested
HTTP responded route=generation method=POST status=200
Generation stop accepted; awaiting an authoritative terminal state
Generation stream reached a terminal state; kind=aborted
```

A stop that races to `completed` is not abort evidence and must be repeated.

### Background checkpoint and detach

During an active generation, send the Simulator to Home:

```text
Application became inactive
Generation checkpoint pass completed; candidateCount=N savedCount=N
Generation streams detached; streamCount=N
```

Acceptance requires `candidateCount >= 1`, `savedCount == candidateCount`,
`streamCount >= 1`, and no checkpoint-failure marker. A second zero-count pass
from another scene transition is harmless.

### Foreground reconciliation and automatic resume

Return without tapping the manual Resume button. If the job remains active:

```text
Application became active
Generation recovery started; cachedCheckpointCount>=1
Generation reconciliation restored an active state
Generation recovery completed; recoverableCount>=1
Visible chat accepted foreground generation recovery
Generation stream connecting; resume=true
Event stream opened route=generation status=200
```

Then require a terminal state. If the server finished in the background, the
valid branch ends with `Generation reconciliation reached a terminal state` and
does not reopen a stream.

The automatic handoff is deliberately fenced by the active profile, account,
conversation, exact generation handle, current operation, and a one-time signal
sequence. A mismatched or replayed signal must produce no new stream. If an
owned active job cannot be reattached, the chat keeps the saved handle and shows
the existing manual **Resume** action with a recoverable explanation. Tapping it
is fallback evidence only; it does not satisfy the automatic-resume branch and
must be recorded separately.

### Connectivity-return recovery after the retry cap

Keep the app active, start a long response, then make the Simulator network
unavailable long enough for the capped stream reconnect policy to stop. Restore
network access without tapping **Resume**. The valid recovery branch requires:

```text
Network connectivity returned; starting generation reconciliation
Generation recovery completed; recoverableCount>=1
Generation stream connecting; resume=true
Event stream opened route=generation status=200
```

Then require a terminal state. Repeated reachable-path notifications without a
new unavailable→available transition must not start another recovery. A later
distinct transition may retry the same still-recoverable exact handle. This path
never adopts a different generation into the visible chat and does nothing while
the app is inactive, signed out, or authenticated offline. If connectivity
returns in the background, foreground reconciliation remains the required path.

## Conversation-duplication acceptance

Use a persisted, nonempty conversation whose source history, project, and
bookmark/tag membership are safe to inspect. Do not use a local empty draft.

1. Open the row's visible ellipsis menu and confirm that Rename, Pin,
   Duplicate, project/bookmark, Archive, and Delete remain independently
   accessible without opening the conversation.
2. Choose **Duplicate**, review the one-shot warning, and confirm once.
3. Verify the app navigates to a fresh conversation whose title and visible
   history match the server result, while the source conversation remains
   unchanged.
4. Return to the list and refresh. Confirm exactly one new row exists; if the
   source had project/tag metadata, verify the returned server metadata rather
   than assuming the associations were copied.
5. In privacy-safe transport logs, require exactly one
   `POST /api/convos/duplicate` for the confirmation. Do not capture request or
   response bodies.
6. Exercise a definite `429` or other 4xx in a controlled deployment: the
   action must report rejection and must not retry automatically.
7. Exercise one outcome-unknown case by dropping the connection only after
   dispatch or returning a malformed `201` fixture. The UI must say that a copy
   may have been created, lock Duplicate for that source, and send no second
   POST. Restore connectivity, explicitly refresh the list, inspect server
   truth, and only then permit a new user decision.
8. Repeat with two profiles/accounts on the same host. A request with foreign
   profile/account coordinates must produce zero network traffic and no
   cross-account cache insertion.

Pass only when VoiceOver announces the row action menu, confirmation,
progress/error state, and destination distinctly, and maximum Dynamic Type
leaves the menu and warning operable. This remains pending until a manually
booted Simulator or device and an authenticated deployment produce a recorded
result.

## Message-feedback acceptance

Use a saved conversation with one visible finished assistant response. Do not
put the feedback details or server record coordinates in logs or screenshots.

1. Open the response actions, choose **Mark as helpful**, select one positive
   reason, save, and wait for the confirmation announcement.
2. Reload the conversation. The same selected response must retain the helpful
   badge; another branch must not inherit it.
3. Edit the feedback to **Needs work**, select a negative reason, add a short
   non-secret detail, save, and reload again.
4. Clear the feedback and confirm the badge remains absent after reload.
5. Repeat once with the PUT response deliberately lost after server commit. The
   client must perform an authoritative history read and must not send a second
   feedback PUT. If the outcome cannot be proved, the exact response stays
   locked until **Close and refresh conversation** completes.
6. Expire authentication before a feedback mutation. A 401 must hide cached
   history and enter the ordinary authentication-recovery path; it must not
   show a saved badge.
7. Run VoiceOver, maximum Dynamic Type, Switch Control, and keyboard navigation.
   Every reason must remain reachable, the selected reason must be announced,
   and the server/observability disclosure must be read before Save.

Record whether the deployment forwards non-Assistants feedback into a configured
observability destination. The app disclosure must match that server policy;
never treat this as device-local feedback. Exact protocol and ambiguity rules
are in [MessageFeedback.md](LibreChatKnowledge/MessageFeedback.md).

## Privacy verification

Run both checks after capture. They must return no matches:

```sh
rg -n -i 'bearer|cookie|set-cookie|refreshToken|accessToken|password=|email=|prompt|toolPayload|messageId|conversationId|streamId|profileId|accountId|authorization:' \
  /private/tmp/librechat-live-acceptance.log
```

```sh
rg -n '<UNIQUE-PROMPT-CANARY>' /private/tmp/librechat-live-acceptance.log
```

Record the Simulator model/runtime, server build, tested profile capabilities,
result bundle or screenshot paths, redacted log path, and every branch actually
observed. Never infer an unobserved recovery outcome from a successful final UI.
