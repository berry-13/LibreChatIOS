# Steering, queued follow-ups, and branch actions

## Evidence boundary

This document records the generation-control contract at LibreChat commit `b2128a7d189ac020ebb6e49a57ee986e98326b77`, audited on 2026-08-18. It separates three things that look similar in a composer but have different ownership and recovery rules:

1. **Server steering** injects a durable instruction into one exact active Agents generation.
2. **Queued follow-up and interrupt-and-send** are orchestration implemented by the LibreChat web client around ordinary generation requests and abort.
3. **Regenerate, continue, edit, and resubmit** are message-graph operations built from the normal generation payload or the message update route; they are not steer aliases.

Source capability is not evidence that the native client implements or has exercised it. The native steering slice covers exact v2 `POST /api/agents/chat/steer`, `/steer/cancel`, and `/steer/arm` paths, stable `clientSteerId`, full generation-handle/profile/account/epoch fences, no automatic retry, finite ambiguity lockout, authoritative preempt downgrade, queued/replayed/settled/leftover state, durable terminal leftovers, and a FIFO exact-handle control lane. Pending chips expose cancel/apply-sooner and a one-shot Guide Response sheet presents native guidance; presentation and URLProtocol tests executed in the complete app result. Direct-path fork presentation tests and its deterministic one-shot review/cancel XCUITest executed. Phase C adds a V2 SwiftData queue journal/migration, atomic reserve/corruption/isolation handling, and a bounded drain coordinator with exact completed-signal/authoritative-graph/target proof, stable IDs, reserve-before-POST, streaming-to-admitted and durable-row-to-committed transitions without synthetic handles, ambiguity lock/no repost, and atomic blocking on 4xx/429/conflict/handoff. Its reconciliation entry point covers reserved, uncertain, committed, and admitted attempts only from exact frozen user/epoch/file proof; an exact admitted handle is preserved, an exact retained terminal closes it, and exact jobless durable user plus one clean direct assistant transitions to delivered-without-epoch and blocks followers without inventing a handle. AppModel invokes it before active-job discovery during restoration, foreground, and connectivity recovery, and the visible ChatModel refreshes both queue ownership and authoritative history even if no active generation remains. ChatModel exposes enqueue/status/remove for text and completed same-target attachments, transfers durable upload ownership, renews file holds, chains one follower per clean terminal, blocks unsafe followers, and presents terminal leftovers with keep-by-default, exact text-only send-next, and server-confirmed dismiss. File-bearing terminal recovery, quotes, skills, new-chat queueing, and background initiation remain unsupported. Message-tree branch selection, save-only message editing, text-only user-prompt edit-and-resubmit, bounded response regeneration, and the direct-path `/api/convos/fork` slice remain separate, fail-closed operations; Continue, assistant resubmit, specialized branch actions, and broader fork modes remain deferred. Direct authenticated live acceptance of every mutation/branch flow in this document is still pending.

## Capability map

| User action | Authoritative mechanism at the pinned commit | Where it lives | Verified native state |
|---|---|---|---|
| Steer this response | `POST /api/agents/chat/steer` against an exact active generation | Server capability, negotiated generation protocol v2 | Implemented with stable `clientSteerId`, full-handle/profile/account/epoch fences, no automatic retry, finite ambiguity lockout, and queued/replayed/settled reconciliation |
| Cancel a queued steer | `POST /api/agents/chat/steer/cancel` | Server capability | Implemented on the FIFO exact-handle lane; pending chips expose cancel and uncertain outcomes lock out repost |
| Escalate a steer to interrupt | `POST /api/agents/chat/steer/arm` | Server capability; safe-boundary preemption may degrade to ordinary steering | Implemented with authoritative preempt-capable downgrade to ordinary steer |
| Queue for after this run | Store a per-conversation item locally, then send one ordinary generation after the exact clean terminal | Web-only orchestration, not a queue endpoint | Phase C native text/completed-attachment enqueue/status/remove, exact terminal/graph/target/file admission, durable upload ownership/holds, reserve/commit safety, jobless delivered-without-epoch blocking, no-repost retained-status lifecycle reconciliation, and keep/send-next/confirmed-dismiss leftover decisions are compile-verified; file-bearing terminal recovery and live acceptance remain open |
| Interrupt and send | Put the local item at the front, bind the interrupt intent to the current epoch, abort, then drain only after that matching abort terminal | Web-only orchestration around `/abort` plus ordinary generation | Native stop exists; the combined queue/epoch/drain action does not |
| Regenerate | Re-submit the parent user turn through the ordinary generation endpoint with `isRegenerate` and branch identity | Web orchestration plus ordinary generation | Start payload currently hardcodes `isRegenerate:false` |
| Continue | Pinned web orchestration attempts an ordinary generation with the parent user turn and `isRegenerate:true`, `isEdited:true`, `isContinued:true`, but its observed behavior is internally inconsistent and degrades toward regeneration rather than a distinct append-continuation contract | Web-only orchestration; no `/continue` route | No native implementation; blocked until the server/web contract is corrected or live-proven |
| Save message edit | `PUT /api/messages/:conversationId/:messageId` with `{text}` or `{text,index}` | Server message mutation | Implemented as save-only native editing with exact raw text/reasoning-part indexes, no automatic retry, and authoritative reconciliation |
| Edit and resubmit user prompt | Ordinary generation with `action: editPromptAndResubmit`, exact original parent, and fresh stable caller IDs | Server creates a new user/assistant sibling branch; original prompt and replies remain unchanged | Implemented only for the selected persisted authoritative single-primary-text user prompt; verified resumable v2 and authoritative idle preflight required; no attachments/rich/artifact/citation content; ambiguity never reposts, losing handoff never attributes a winner, accepted terminal reloads/focuses history, and 401 hides history |
| User edit and resubmit | Submit edited user text from the original parent as an ordinary generation, producing a fresh user sibling and downstream assistant sibling | Web orchestration plus ordinary generation | Not implemented |
| Structured assistant-part resubmit | Send `editedContent {index,type,text}` against the original branch context, producing a new assistant sibling | Web orchestration plus ordinary generation | Not implemented |
| Legacy assistant-text Save & Submit | Pinned UI path appears to resubmit, but does not forward the edited legacy assistant text into generation, so the edit is dropped | Internally inconsistent pinned web orchestration | No native implementation; blocked |

The distinction is load-bearing: a deployment can expose steer/cancel/arm while providing no server-side equivalent of the web client's normal follow-up queue. The native app must implement its own durable local queue semantics instead of inferring another endpoint. Likewise, branch identity is the message tree—message ID, parent ID, chosen sibling/response, and conversation—not simply visible array order. The specialized `POST /api/messages/branch` parallel-agent-part operation and `POST /api/convos/fork` new-conversation operation are separate contracts; neither substitutes for ordinary regenerate, edit-resubmit, Continue, or local queue drain.

## Native steering mutation and guidance boundary

The native mutation slice is intentionally narrower than a complete follow-up system:

- `POST /api/agents/chat/steer`, `/steer/cancel`, and `/steer/arm` are built with negotiated v2 headers/body markers, stable `clientSteerId`, and full profile/account/conversation/stream/epoch/protocol fencing.
- Mutation lanes are FIFO per exact handle. Requests do not automatically retry. A transport/5xx ambiguity enters a finite uncertain state; the same identity may be reconciled manually, but the client never silently reposts or mints a replacement ID.
- Submit receipts distinguish fresh `queued`, `replayed`, `settled`, and `leftover` outcomes. Cancel and arm consume the same identity; cancellation is advisory when the item already applied or parked. Arm preserves FIFO identity and can authoritatively downgrade preempt to ordinary steering when the runtime reports `PREEMPT_UNSUPPORTED`.
- Authoritative `resumeState.pendingSteers`, applied `part.steer`, replay/update events, FINAL/abort pending steers, and status `unrecoveredSteers` drive chip state. Durable terminal leftovers remain outside active recovery and are not silently converted into ordinary sends.
- The UI exposes pending chips with Cancel and Apply sooner, a one-shot Guide Response sheet, and an uncertain-operation lock. Its model/presentation tests executed, but it has no hands-on or live network claim.

The remaining boundary is explicit: Phase C has a user-facing after-run queue for text and completed same-target attachments, lifecycle-triggered no-repost reconciliation, exact one-at-a-time clean-terminal drain, durable upload ownership/hold renewal, jobless delivered-without-epoch blocking, and keep/send-next/server-confirmed-dismiss choices for durable leftovers. The composer remains editable while a response streams; queue admission is available only after exact response coordinates exist, and file-bearing leftovers cannot be sent next. There is still no interrupt-and-send drain, recovered-file ownership mapping, new-chat queue, or background initiation. The coordinator reserves before POST, never reposts an ambiguous item, requires exact resume user/epoch plus durable rows when reconciling, and blocks atomically on unsafe outcomes.

## Protocol-v2 negotiation gate

Steering is a generation-v2 feature, not a general `/api/config` flag.

- The web client advertises version `2` through `X-LibreChat-Generation-Protocol`, query, or JSON body helpers and enables v2 behavior only after an exact numeric `generationProtocolVersion: 2` echo. Strings, missing echoes, and future versions fail closed to v1 ([client protocol, lines 3–43](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/data-provider/SSE/protocol.ts#L3-L43)).
- The server reads every supplied body, query, and header marker. A missing marker set, any malformed marker, or disagreement resolves to v1; every supplied marker must agree on v2. New generations are capped by the server rollout gate, and existing jobs retain the protocol recorded when they were created ([server protocol, lines 1–65](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/agents/protocol.js#L1-L65)).
- A native control request must bind the profile, account, conversation, `generationCreatedAt` epoch, and negotiated job protocol. A replacement is never a valid retarget for an old steer.

The audit's steer-request evidence is intentionally pinned in smaller semantic spans so future reviews can detect contract drift: [request/body types, lines 21–56](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L21-L56); [text normalization, lines 149–213](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L149-L213); [file resolution, lines 223–249](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L223-L249); [fingerprinting, lines 252–300](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L252-L300); [degradation codes, lines 326–335](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L326-L335); [receipt replay, lines 348–435](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L348-L435); [active-job/protocol fence, lines 437–485](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L437-L485); [authorization/enqueue, lines 487–637](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L487-L637); [fresh receipt, lines 697–707](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L697-L707); and [cancel/arm controls, lines 732–1028](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L732-L1028).
- Only an exact v2 echo permits v2 receipt/idempotency or preemption-revision handling. An unknown or downgraded response must not be interpreted as durable v2 proof.

## Server steering wire contract

The routes are mounted before the ordinary chat router. Submit steering receives the normal message rate limits, PII filtering, then moderation; cancel and arm have the shared rate limits but do not submit new model-bound text ([route registration, lines 890–940](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/agents/index.js#L890-L940)).

### Submit

```http
POST /api/agents/chat/steer
X-LibreChat-Generation-Protocol: 2
Content-Type: application/json

{
  "conversationId": "conversation-id",
  "generationCreatedAt": 1720000000000,
  "clientSteerId": "stable_client_id",
  "text": "Use the newer figures instead.",
  "files": [],
  "preempt": false,
  "generationProtocolVersion": 2
}
```

The exact request shape is defined in [`SteerRequestBody`](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L21-L56). Validation and durable enqueue impose these constraints:

- `conversationId` is a non-empty real ID and cannot be `new`;
- `generationCreatedAt`, when sent, is a non-negative safe integer and must match the active epoch;
- `clientSteerId` is 1–128 characters from `[A-Za-z0-9_-]+` and must remain stable across an ambiguous retry;
- text is NUL-stripped, trimmed, non-empty, and at most 16,000 characters by default;
- at most ten file references are accepted; each is re-resolved under the current owner/tenant and marked used before the 202 can be considered durable;
- `preempt:true` asks the owning runtime to seal at a provider-safe boundary. Lack of preemption support does not reject a valid steer; the server can enqueue it as ordinary steering.

The parsing, sanitization, owner-scoped file resolution, and fingerprint are in [lines 149–300](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L149-L300). The validation, ownership/tenant/agent checks, epoch fence, runtime capability gate, and guarded enqueue are in [lines 326–637](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L326-L637).

A fresh success is HTTP 202:

```json
{
  "status": "queued",
  "steerId": "server-steer-id",
  "position": 1,
  "conversationId": "conversation-id",
  "preempt": false,
  "preemptRevision": 3,
  "generationProtocolVersion": 2
}
```

`preempt` describes the durable queued item's interrupt flag, not proof that the owner already sealed. `preemptRevision` is monotonic and only belongs to the v2 contract. The fresh receipt is assembled in [lines 697–707](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L697-L707).

### Idempotency and delivery ambiguity

The server fingerprints `{text, files, preempt}`. With negotiated v2 and a stable `clientSteerId`:

- the same ID and same fingerprint returns the existing 202 receipt, even when the original job has ended or been replaced;
- a replay can additionally report `replayed:true`, `settled:true`, and `leftover:true` so the client can distinguish already-settled versus parked recovery work;
- the same ID with changed text/files/preempt returns `409 STEER_IDEMPOTENCY_CONFLICT`;
- an epoch that does not match the receipt or active job returns `409 RUN_REPLACED`;
- transport failure or 5xx after dispatch is delivery-uncertain. Do not mint a new ID or expose an unsafe ordinary resend; retry the same ID/body or reconcile from SSE/status.

Receipt replay must be checked before the current job marker so a later v1 generation cannot hide proof of an earlier accepted v2 action ([receipt replay, lines 348–435](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L348-L435)).

The server's same-ID replay contract is not permission for an automatic native retry. The native repository records a finite uncertain state, keeps the original `clientSteerId` and fingerprint available for explicit reconciliation, and leaves the chip locked until authoritative receipt/status/SSE evidence resolves it.

### Error/degradation matrix

| HTTP/code | Meaning | Safe native response |
|---|---|---|
| `400 INVALID_CONVERSATION`, `INVALID_GENERATION_IDENTITY`, `EMPTY_TEXT`, `INVALID_CLIENT_STEER_ID`, `INVALID_FILES`, `TOO_MANY_FILES` | Definite invalid request | Keep editable text/files; require correction; do not retry automatically |
| `403 UNAUTHORIZED` / `FORBIDDEN` | Owner, tenant, or originating-agent access failed | Hide/lock the action; refresh auth/capabilities as appropriate; never retarget |
| `404 NO_ACTIVE_RUN` | No exact active run accepted the steer | Reconcile, then offer/send as an ordinary queued follow-up only under predecessor fencing |
| `409 RUN_REPLACED` | Another generation owns the conversation epoch | Keep it queued for the replacement's eventual end; never normal-send immediately into and replace that winner |
| `409 RUN_PAUSED` | The run awaits human action | Keep a local queued follow-up; resolve the action first |
| `409 STEER_IDEMPOTENCY_CONFLICT` | Stable ID was reused with a changed fingerprint | Fail closed and retain both local proof and user content for diagnosis; never silently change the ID and resend |
| `413 STEER_TOO_LONG` | Text exceeds the returned `maxLength` | Return text to editing |
| `429 STEER_QUEUE_FULL` / `STEER_RECEIPT_LIMIT` | Server queue or receipt capacity reached | Keep a local queued follow-up; respect retry policy, but do not create duplicate IDs |
| `501 STEER_UNSUPPORTED` | The active runtime cannot inject | Keep a local queued follow-up; do not mark generation v2 globally unsupported from this alone |
| `503 STEER_FILE_RETENTION_FAILED` | Files were not durably retained | Keep text/files and retry only with the same receipt identity after reconciliation |

The documented degradation codes and ordering are in [lines 326–335](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L326-L335), with the complete result ladder in [lines 348–707](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L348-L707).

### Cancel

```http
POST /api/agents/chat/steer/cancel
X-LibreChat-Generation-Protocol: 2

{
  "conversationId": "conversation-id",
  "generationCreatedAt": 1720000000000,
  "steerId": "server-steer-id",
  "clientSteerId": "stable_client_id",
  "generationProtocolVersion": 2
}
```

A v2 cancel binds both identities and the epoch. A successful removal returns `200 {"removed":true,"generationProtocolVersion":2}`; replay of a confirmed cancel or discarded terminal leftover may also include `replayed:true`. `removed:false` is an advisory race outcome, not a transport error: the steer may already be applied, terminally parked, or absent. The client must defer to authoritative applied content, terminal/status leftovers, and the receipt rather than assuming the words were rejected. Cancel logic and bounded preempt-disarm behavior are in [lines 732–912](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L732-L912).

Terminal-leftover discard is deliberately exact: local recovery ownership is acknowledged only when the server returns `removed:true` for the matching full identity. A missing, false, replay-without-confirmed removal, unauthorized, conflicting, or ambiguous response leaves the local recovery row intact; no local acknowledgement is treated as a server discard, resend, or drain.

### Arm an existing steer

```http
POST /api/agents/chat/steer/arm
X-LibreChat-Generation-Protocol: 2

{
  "conversationId": "conversation-id",
  "generationCreatedAt": 1720000000000,
  "steerId": "server-steer-id",
  "clientSteerId": "stable_client_id",
  "generationProtocolVersion": 2
}
```

Arm changes the existing queued item in place, preserving FIFO position, ID, and timestamp. Outcomes are:

- `200 {"armed":true,"preemptRevision":n,"generationProtocolVersion":2}` when the durable flag was set;
- `200 {"armed":false,"code":"PREEMPT_UNSUPPORTED",...}` when the owning runtime cannot preempt; the item remains queued normally;
- `200 {"armed":false,...}` when it already applied, was cancelled, or the run ended;
- `409 RUN_REPLACED` when the exact epoch fence fails.

The highest `preemptRevision` wins when update events race. Arm behavior is defined in [lines 925–1028](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/api/src/agents/steering/request.ts#L925-L1028).

## Authoritative lifecycle and reconciliation

### Shapes

A pending steer projected into sync/final/status has this shape:

```text
steerId, clientSteerId?, text, createdAt?, files?, preempt?, preemptRevision?
```

`on_steer_applied` carries `steerId`, optional `clientSteerId`, absolute content `index`, and a structured part whose text is under **`part.steer`**, plus optional response/conversation identity. `on_steer_updated` carries one or more `{steerId,clientSteerId?,preempt,preemptRevision}` updates. Exact shared types: [data-provider `runs.ts`, lines 122–166](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/types/runs.ts#L122-L166).

### Merge order

On resume or reconnect, the safe order is:

1. replace the response with authoritative `resumeState.aggregatedContent` and other snapshot state;
2. replace the server-owned pending-steer list from `resumeState.pendingSteers` — an empty list clears stale acknowledged-pending chips;
3. remove pending chips already represented by structured steer parts in authoritative content;
4. apply `resumeState.replayEvents` and then top-level `pendingEvents` in order;
5. consume subsequent live events.

The web reference performs snapshot reseeding and applied-part settlement before replay/pending/live handling in [useResumableSSE, lines 1834–1927](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/SSE/useResumableSSE.ts#L1834-L1927). Applied events settle chip ownership before waiting for their message target, preventing an intervening error/final from requeueing already-applied words ([lines 1254–1300](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/SSE/useResumableSSE.ts#L1254-L1300)).

Local definite failures are a separate namespace/state from server-acknowledged pending steers. An empty authoritative server list must clear stale acknowledged pending items without erasing definite local failures that were never accepted.

### Terminal and detached recovery

Unapplied accepted steers have several authoritative delivery surfaces:

- normal FINAL: `pendingSteers`;
- successful abort response: `pendingSteers` after persistence succeeds ([abort result, lines 857–866](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/agents/index.js#L857-L866));
- inactive/jobless status: `unrecoveredSteers` ([status route, lines 394–516](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/agents/index.js#L394-L516)).

Before converting any leftover to a local follow-up, collect applied IDs from the final/authoritative response. Convert each remaining source exactly once, retaining text, files, timestamps, receipt identities, preempt state, and source epoch. The web final path does this before emitting the run-end drain signal ([useResumableSSE, lines 1496–1527](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/SSE/useResumableSSE.ts#L1496-L1527)).

## Local queued-follow-up and interrupt semantics

The web queue is a per-conversation client store, not a server steer queue. Its item identity can include text, files, quotes, selected skills, stable recovery identity, `expectedPredecessorCreatedAt`, and logical queue-neighbor information. See [queue types, lines 364–406](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/store/families.ts#L364-L406).

Required native invariants:

- namespace every item by profile, account, and conversation;
- preserve a stable local ID, original timestamp, attachments, context, and logical slot across all retries/restoration;
- renew or otherwise retain attached uploads while the item waits;
- drain at most one item after one exact **clean completion**, letting that new turn's terminal signal drain the next item;
- do not auto-drain after ordinary user Stop or generation error;
- bind drain signals to the exact conversation and generation epoch, parking a signal for its owning conversation when another chat is visible;
- carry the completed generation epoch into `expectedPredecessorCreatedAt` for the ordinary follow-up start;
- on predecessor mismatch, restore the exact item to the exact logical slot; do not mint a replacement request or blindly resend.

The web queue's matching, one-at-a-time drain, terminal policy, attachment-hold renewal, and predecessor propagation are in [useQueueDrain initialization, lines 42–70](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/Chat/useQueueDrain.ts#L42-L70) and [drain lifecycle, lines 160–333](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/Chat/useQueueDrain.ts#L160-L333). The generation start route validates the predecessor identity in [request controller, lines 359–375](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/agents/request.js#L359-L375) and returns typed winner proof on mismatch in [lines 1851–1883](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/agents/request.js#L1851-L1883), rather than treating the fence as a UI hint.

“Interrupt and send” is not server preemptive steering. It:

1. inserts a local follow-up at the front;
2. records the active conversation and `generationCreatedAt` as the only abort terminal allowed to release it;
3. calls normal generation abort;
4. drains the item only when that matching abort settles.

The web action is `enqueue(front:true) → armDrainAfterAbort() → stopGenerating()` ([useSteering, lines 1346–1368](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/Chat/useSteering.ts#L1346-L1368)). It must not be confused with “interrupt and steer,” which tries a server steer with `preempt:true` and keeps the partial response in the same assistant message.

## Regenerate, continue, edit, and resubmit

### Regenerate

Regenerate selects the original user node, copies its relevant context/files/quotes/skills, and submits through the current ordinary generation target. The payload marks `isRegenerate:true`, preserves the parent/branch identity, and, when regenerating a specific assistant response, carries `targetResponseMessageId` ([useChatFunctions, lines 700–734](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/Chat/useChatFunctions.ts#L700-L734); response ID handling in [BaseClient, lines 327–370](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/app/clients/BaseClient.js#L327-L370)). There is no dedicated regenerate route. The native response-regeneration slice is narrower: it is offered only for a selected persisted finished plain-text assistant that is the direct child of the exact user source, after authoritative branch/target fingerprint and v2 idle checks. It sends exact source/override-parent/preliminary-response coordinates, stable caller identity, no attachments/skills/quotes/rich/citation/artifact content, and creates a new assistant sibling while preserving the original subtree. Settled/failed outcomes require exact authoritative new-sibling proof; ambiguity never reposts, a typed losing handoff is never attributed, and 401 hides history. A one-shot sheet/review lock prevents duplicate admission. Continue, assistant resubmit, and conversation fork remain distinct.

### Continue

Continue is presented as an ordinary generation start. The pinned web client replays the latest response's parent user message and passes `isContinued:true`, `isRegenerate:true`, and `isEdited:true` ([useChatHelpers, lines 171–191](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/hooks/Chat/useChatHelpers.ts#L171-L191)); the transport serializes `isContinued` only with the edit/continue combination ([createPayload, lines 45–60](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/createPayload.ts#L45-L60)). The audited pinned behavior is internally inconsistent and can degrade toward regeneration instead of a clearly distinct append-continuation result. There is no `/continue` control endpoint, and HITL `/api/agents/chat/resume` must never be used for this product action. Native Continue therefore remains unimplemented and blocked until corrected or directly live-proven.

### Save-only edit

`PUT /api/messages/:conversationId/:messageId` with `{text}` updates the message's primary text. `{text,index}` updates an existing structured `text` or `think` part at that exact persisted content-array index; other part kinds and invalid indexes are rejected. The server recomputes token counts, including persisted quotes for user text ([data service, lines 931–947](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/data-service.ts#L931-L947); [message route, lines 360–432](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/messages.js#L360-L432)). This mutation alone does not generate a new answer. The native app exposes save-only editing for persisted messages on the selected valid branch, preserves raw indexes, excludes artifact boundaries/citation-resolved text, disables automatic retry, and installs the complete authoritative history after confirmation. An ambiguous response triggers exact-coordinate reconciliation; if verification is unavailable or the server text mismatches, the edit remains recoverable and is never reposted. This is not regenerate, edit-resubmit, or a branch action. The server has no compare-and-swap revision, so last-writer-wins remains a deployment limitation.

### Edit and resubmit

Edit-and-resubmit is an ordinary generation request, not the save-only PUT. Editing a **user** message submits the edited text from the original parent with the original files/quotes/skills and creates a fresh user sibling followed by its assistant response. Editing a **structured assistant content part** sends `editedContent {index,type,text}` in the original branch context and creates a new assistant sibling ([EditMessage, lines 54–102](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/components/Chat/Messages/Content/EditMessage.tsx#L54-L102); [EditTextPart, lines 62–91](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/client/src/components/Chat/Messages/Content/Parts/EditTextPart.tsx#L62-L91)).

The pinned legacy assistant-text **Save & Submit** path is unsafe: it does not forward the edited legacy text into the generation request, so the user's edit is dropped. Keep that control disabled rather than copying the bug. Structured-part resubmit also needs the server/web prefix-offset convention and exact content-part identity; visible substring indexes cannot be assumed to equal persisted prompt indexes. Until branch-head reconciliation and these distinctions are proven, every native edit-resubmit control remains unavailable. The implemented save-only sheet explicitly tells users that it changes saved history without generating a new response; it remains open on failure and closes only after authoritative confirmation.

### Distinct specialized branch operations

The ordinary message-tree actions above must not be conflated with the specialized parallel-agent API or the direct-path fork API:

- `POST /api/messages/branch` with `{messageId,agentId}` branches a parallel-agent content part into a new assistant message. It is not generic regenerate or edit-resubmit.
- `POST /api/convos/fork` with conversation/message coordinates creates a separate conversation fork. The native direct-path slice validates the authoritative source conversation/message and graph, uses `.never` retry with typed preflight-vs-ambiguous handling, preserves the original, creates fresh IDs, and presents a one-shot review/navigation action. It is not an in-conversation sibling branch or the local after-run queue. `includeBranches`, `targetLevel`, and `splitAtTarget` remain unimplemented/unproven.

Native message-graph work must preserve conversation ID, message ID, parent ID, target response/content-part identity, and chosen sibling head. Array order or visible text alone cannot safely identify the mutation target. The native client now implements the local branch projection: server sibling order is authoritative, the default is the last child at each depth, selections are client-local, send/share use the exact selected projected tail, and duplicate/missing/self/cyclic graphs fail closed. Root sentinels (`nil`, zero UUID, and `NO_PARENT`) normalize to the root; malformed non-empty histories disable branch-dependent actions. Parallel-agent `/api/messages/branch` remains unimplemented; direct-path `/api/convos/fork` is implemented only for the bounded slice above. See the exact route inventory in [Conversations, messages, and files](ConversationsMessagesAndFiles.md).

## Verified native read/recovery boundary

The current Swift slice now implements the lossless **observation and recovery** half of steering:

1. `resumeState.pendingSteers` is authoritative; the ambiguous legacy wire field `steers` is deliberately ignored;
2. structured applied content reads text from `part.steer` and preserves server/client IDs, files, timestamps, target message identity, and content index;
3. pending, applied, update, and recoverable leftovers remain distinct domain states;
4. an authoritative sync replaces pending state, clears an empty server list, removes applied identities, and deduplicates recoverable leftovers;
5. `on_steer_updated` applies only a non-stale `preemptRevision`, so out-of-order lower revisions cannot roll back the label;
6. FINAL `pendingSteers` and status `unrecoveredSteers` project into typed recoverable leftovers;
7. abort `pendingSteers` is projected through the repository after a successful persisted abort outcome;
8. cached `GenerationSnapshot` and `GenerationSync` records written before the new arrays existed decode with empty defaults.

Terminal projection is presence-aware: omitted FINAL `pendingSteers` or status/abort arrays leave an already-owned local batch unchanged, while an explicitly present empty array authoritatively clears it. This avoids both accidental loss on an older server and resurrection after an explicit empty projection.

The app boundary adds two deliberately non-send types:

- `RecoverableSteerIdentity` is the exact server steer ID plus optional client steer ID. An incomplete identity cannot acknowledge a two-coordinate item.
- `RecoverableSteerBatch` is one terminal generation's full `GenerationHandle`, parked steers, and checkpoint time. It is not a `ChatRequest`.

`RecoverableSteerRepository` reads terminal batches for one conversation and acknowledges a caller-selected identity set. Terminal records are stored separately from nonterminal active-recovery records, so they cannot be resumed as jobs. Lookup and mutation require exact profile, account, conversation, and complete handle equality—including client request ID, stream, optional generation epoch, and protocol version. V1 keys that lacked client-request identity and encoded a nil epoch as zero remain discoverable, but the decoded full handle is authoritative; collisions fail closed. Two current nil-epoch handles with the same stream/conversation remain separate.

This separation does not introduce a new terminal discriminator. Terminal/nonterminal state remains authoritative inside the Codable `GenerationSnapshot`, and cache queries decode and filter `snapshot.state`. The originally shipped V1 record already contains an `isTerminal` compatibility column; it remains in `CacheSchemaV1` so the model checksum matches deployed stores and they can reach the V1-to-V2 queue migration. The column is maintained on writes but is not trusted in place of the snapshot state.

Acknowledgement is atomic local ownership release only:

- a partial match removes only those exact identities and persists the remainder;
- a duplicate or unknown identity is an idempotent no-op;
- acknowledging the last item removes the terminal record;
- sibling handles, conversations, accounts, and profiles remain untouched;
- acknowledgement never turns the text into an ordinary send or silently retries it.

Final verification executed **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at [`/private/tmp/librechat-visual-audit-core`](/private/tmp/librechat-visual-audit-core), **371/371 previously executed iOS unit/model/repository tests** at [`/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`](/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult), and **7/7 deterministic XCUITests** at [`/private/tmp/LibreChatIOS-UIFinalTests-20260819.xcresult`](/private/tmp/LibreChatIOS-UIFinalTests-20260819.xcresult). Queue journal/migration and the focused recovery/wire fixtures now have executed Simulator evidence, and the preserved V1 store migrated successfully in place. Steering/queue mutation UI and authenticated live-server behavior remain unproven.

The remaining native gaps are still substantial:

- no live proof of steer submit/cancel/arm request factories, stable IDs, full-handle fencing, or per-conversation control serialization;
- no live proof of durable steer-submission receipt/ambiguous-202 acknowledgement state; finite ambiguity is locked out without automatic retry;
- terminal leftovers expose keep-by-default, exact text-only send-next, and server-confirmed dismiss, but file-bearing recovered steers remain disabled because their server file IDs cannot yet be mapped safely onto local queue-owned upload records;
- Phase C has a persistent after-run journal, native enqueue/status/remove UI for text and completed same-target attachments, lifecycle no-repost reconciliation, one-at-a-time exact clean-terminal drain, and jobless delivered-without-epoch blocking; live proof remains open;
- normal queued uploads transfer durable ownership and renew holds immediately/every 30 minutes/on restore/foreground/connectivity return, but terminal-leftover attachment lifetime/expiry recovery remains unresolved;
- native pending chips expose cancel/apply-sooner, and the one-shot Guide Response sheet plus uncertain-operation lock have executed model coverage; reclaim/edit/retry, interrupt-and-steer, and interrupt-and-send remain absent;
- bounded response regeneration is implemented for a selected persisted finished plain-text assistant that is the direct child of the exact user source: authoritative branch/target fingerprint, verified v2 and idle status, exact source/override-parent/preliminary-response coordinates, stable caller identity, bounded retries, original-subtree preservation, new-sibling proof, no attachments/skills/quotes/rich/citations/artifacts, ambiguity-safe no-repost, typed losing-handoff rejection, 401 history hiding, and one-shot sheet/review locking. Structured assistant-part resubmit, Continue, assistant resubmit, and legacy assistant-text Save & Submit remain blocked by the pinned inconsistencies described above. Text-only user-prompt edit-and-resubmit is implemented as a guarded ordinary-generation sibling branch with verified v2/idle admission and no blind repost; save-only message editing remains separate, with no generation or automatic retry. The server's missing compare-and-swap revision leaves a last-writer-wins limitation, and in-flight edits are not durably journaled.

Do not present typed recovered leftovers as a shippable steering subsystem. They now preserve and relinquish local ownership safely, but there is no user-facing decision or resend path. Repository acknowledgement must never be described as submitting, retrying, or draining those words.

## Safe phased implementation

### Phase A — lossless read/recovery model — implemented and package-tested

- Typed pending/applied/update/recoverable models retain the protocol identities and revision needed for lossless reconciliation.
- Decoder/reducer fixtures cover `resumeState.pendingSteers`, structured `part.steer`, FINAL/status leftovers, authoritative replacement, deduplication, revision ordering, and legacy cache decoding.
- Presence-aware omission versus explicit-empty clearing is package-tested.

### Phase A2 — terminal ownership persistence — app-wired and build-verified

- `RecoverableSteerIdentity`/`RecoverableSteerBatch` and the repository seam keep terminal records out of active recovery.
- Full namespace/handle equality, legacy-key lookup, nil-epoch collisions, and partial/idempotent/full acknowledgement are covered by compiled Architecture fixtures.
- Execute those fixtures in Simulator before promotion. Acknowledgement remains local ownership release only.

### Phase B — steer/cancel/arm transport — app-wired and compile-verified

- Exact v2 request factories, protocol echoes, typed errors, stable `clientSteerId`, and one FIFO control lane per exact generation handle are implemented.
- Lost 202/5xx is finite delivery-uncertain state; native mutation code performs no automatic retry or blind resend and retains the identity for reconciliation.
- Every operation is fenced to the selected profile/account/conversation/full handle/epoch and rejects replacement retargeting.
- Cancel and revision-aware arm state are implemented; `PREEMPT_UNSUPPORTED` is an authoritative downgrade to ordinary steering, not a failed global capability check.
- Four pure guidance presentation tests and the URLProtocol repository cluster executed in the complete 371/371 app test run.

### Phase C — bounded durable journal/drain foundation — implemented and package-tested

- V2 SwiftData queue journal/migration provides atomic reserve, corruption handling, and profile/account isolation.
- The drain coordinator requires an exact completed signal, a valid authoritative message graph, target proof, and exact frozen file identities before admission; it uses stable IDs and reserves before POST.
- Streaming transitions to admitted, and a durable row transitions to committed without creating a synthetic generation handle.
- Delivery ambiguity locks without reposting. 4xx, 429, conflict, and handoff outcomes block atomically.
- Exact jobless user plus single clean assistant proof transitions to delivered-without-epoch and blocks followers; no predecessor epoch is invented.
- Completed same-target attachments transfer into durable queue ownership and renew `/api/files/usage` holds. File-bearing terminal recovery, quote/skill/new-chat/background initiation, edit/reorder review for blocked rows, and live acceptance remain intentionally absent.
- Add “interrupt and send” only after matching-epoch abort/drain lifecycle wiring and the user-facing policy exist.

### Phase D — safe message-tree branch actions

- Bounded response regeneration is implemented for the selected finished plain-text assistant/direct-user pair with exact branch/target fingerprint, source/override-parent/preliminary-response coordinates, stable request identity, sibling proof, and one-shot sheet/review admission. Keep the original subtree intact and fail closed on ambiguity.
- Implement non-automatically-retried save-only message edit separately from user edit-resubmit and structured assistant-part resubmit.
- Keep Continue disabled until its append semantics are corrected or directly proven; never copy the pinned regeneration-like ambiguity.
- Keep legacy assistant-text Save & Submit disabled because the pinned path drops the edited text.
- Treat `/api/messages/branch` parallel-agent branching and direct-path `/api/convos/fork` conversation forking as separate capabilities, not generic branch fallbacks; keep `includeBranches`, `targetLevel`, and `splitAtTarget` disabled until their contracts are proven.
- Add authoritative history/branch reconciliation and structured-content prefix-offset fixtures before enabling any controls.

## Required contract and recovery tests

1. Exact steer/cancel/arm URL, protocol header/body, IDs, and epoch.
2. Same `clientSteerId` plus same fingerprint replays one receipt.
3. Same ID plus changed body returns idempotency conflict without resend.
4. Real `pendingSteers`, `part.steer`, and update/revision frames decode losslessly.
5. SYNC replaces the authoritative pending set and applies replay/pending events in order.
6. Applied-before-ACK and terminal-before-ACK settle once without resurrecting a chip.
7. FINAL/abort `pendingSteers` and status `unrecoveredSteers` persist one recoverable local identity each without automatic resend; missing versus explicit-empty projection differs.
8. Lost steer 202 produces delivery-uncertain state without automatic retry; Phase C drain ambiguity locks without repost.
9. `RUN_REPLACED` never falls back to an immediate normal send.
10. The internal text-only coordinator admits one item only after the exact completed signal, valid authoritative graph, and target proof; it never admits after ordinary Stop/error.
11. Predecessor mismatch restores the same ID, slot, text, attachments, and context.
12. Persistence/relaunch proves profile/account/conversation/full-handle isolation, legacy-key lookup, nil-epoch collision safety, and partial/idempotent/full acknowledgement.
13. The highest `preemptRevision` wins across out-of-order updates.
14. An empty authoritative pending list clears stale server-pending state without erasing definite local failures.
15. Bounded response regeneration starts from the exact user source and selected finished plain-text assistant target, uses authoritative branch/target proof plus exact wire coordinates and stable request identity, excludes attachments/skills/quotes/rich/citations/artifacts, preserves the original subtree, and proves the new assistant sibling before handoff.
16. User edit-resubmit creates a fresh user sibling; structured assistant-part resubmit carries exact `{index,type,text}` content identity and creates a new assistant sibling.
17. Save-only edit uses exact `{text}` or `{text,index}`, disables automatic retry, and reconciles ambiguous outcomes.
18. Continue remains unavailable while the pinned path is regeneration-like/inconsistent; legacy assistant-text Save & Submit remains unavailable because the edited text is dropped.
19. `/api/messages/branch` and `/api/convos/fork` never masquerade as regenerate, edit-resubmit, Continue, or local queue drain.

Then run direct authenticated acceptance against the pinned deployment: ordinary steer, preempt-capable and degraded steer, lost-ACK retry, cancel/apply race, arm/update race, disconnect SYNC, FINAL/abort/status leftover recovery, queue drain, predecessor replacement, relaunch, regenerate, save-only edit, safe user/structured-part resubmit, specialized message branch, and conversation fork. Continue requires corrected or explicit live contract evidence before implementation; the pinned legacy assistant-text Save & Submit path must remain disabled. None of that direct live acceptance is complete as of this audit.
