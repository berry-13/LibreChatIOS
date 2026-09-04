# Message feedback

**Pinned LibreChat source:** `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native status:** implemented and package/build verified; authenticated live acceptance pending

This document records the exact message-feedback contract and the native safety boundary. Feedback is a server-owned mutation on a persisted response. It is not a local reaction, analytics-only event, or optimistic decoration.

## 1. Wire contract

The authenticated route is:

```text
PUT /api/messages/:conversationId/:messageId/feedback
```

The request body has one optional field:

```json
{
  "feedback": {
    "rating": "thumbsUp",
    "tag": "accurate_reliable",
    "text": "Optional details"
  }
}
```

The pinned web client clears feedback by passing `feedback: undefined`; JSON encoding produces `{}`. The server treats missing or null feedback as a clear and persists `null`. Native uses the same omitted-field clear shape rather than inventing a delete endpoint.

A successful response is:

```json
{
  "messageId": "...",
  "conversationId": "...",
  "feedback": {
    "rating": "thumbsUp",
    "tag": "accurate_reliable",
    "text": "Optional details"
  }
}
```

For a clear, `feedback` is present and null. Native response decoding is presence-aware: an omitted field is not accepted as proof of clearing. The returned conversation and message IDs must exactly match the request.

Evidence: `api/server/routes/messages.js:434-489`; `packages/data-provider/src/api-endpoints.ts:486-487`; `packages/data-provider/src/data-service.ts:1314-1320`; `client/src/hooks/Messages/useMessageActions.tsx:138-167`.

## 2. Closed rating and reason registry

LibreChat exposes two ratings:

- `thumbsUp`
- `thumbsDown`

The rating is not independent of the reason. Each tag belongs to exactly one direction:

| Rating | Wire tag | Native label |
|---|---|---|
| `thumbsDown` | `not_matched` | Did not follow the request |
| `thumbsDown` | `inaccurate` | Inaccurate |
| `thumbsDown` | `bad_style` | Writing style |
| `thumbsDown` | `missing_image` | Missing image |
| `thumbsDown` | `unjustified_refusal` | Unjustified refusal |
| `thumbsDown` | `not_helpful` | Not helpful |
| `thumbsDown` | `other` | Something else |
| `thumbsUp` | `accurate_reliable` | Accurate and reliable |
| `thumbsUp` | `creative_solution` | Creative solution |
| `thumbsUp` | `clear_well_written` | Clear and well written |
| `thumbsUp` | `attention_to_detail` | Attention to detail |

The server schema rejects an unknown tag or a tag paired with the opposite rating. The native domain derives rating from `MessageFeedbackTag`, so an invalid pair cannot be constructed above the DTO boundary. Unknown future values fail closed as unavailable feedback but do not prevent the rest of a historical message from loading.

The protocol accepts optional text up to 1,024 JavaScript string units. Native validates `String.utf16.count`, matching Zod/JavaScript semantics rather than Swift grapheme count. The native sheet requires a nonblank explanation for `other`; this is a native usability rule, not a server rule.

Evidence: `packages/data-provider/src/feedback.ts:3-151`; `packages/data-provider/src/feedback.spec.ts`.

## 3. Server-side effects and privacy

The route updates the authenticated user's exact message. After persistence, the server makes a best-effort `sendFeedbackScore` call for non-Assistants endpoints. That call can include trace linkage plus bounded message/conversation/session/user/tenant/endpoint/sender/token metadata and the submitted feedback. Assistants endpoints are excluded because they do not have deterministic AgentRun traces.

Therefore the native UI states that feedback is saved to the LibreChat message and may be sent to an observability service configured by the server owner. The app must never describe this as device-local feedback. It does not log the comment, rating, tag, message ID, conversation ID, or server URL.

Evidence: `api/server/routes/messages.js:448-483`.

## 4. Native domain and transport boundary

Stable domain types live in `LibreChatDomain/MessageFeedback.swift`:

- `MessageFeedbackRating`
- `MessageFeedbackTag`
- `MessageFeedback`
- `MessageFeedbackCoordinate`
- `MessageFeedbackRequest`
- `MessageFeedbackResult`
- `RecoverableMessageFeedbackAmbiguity`
- `MessageFeedbackError`

`ChatMessage.feedback` is optional and backward-decodes to nil for older cached messages. Historical DTO mapping accepts only a valid known rating/tag pair. Invalid feedback is dropped without discarding the surrounding message.

`LibreChatMessagesAPI.updateFeedback` constructs the raw path-component request and uses `.never` retry. A feedback PUT is idempotent in desired-state terms, but blind transport retry is still avoided because the server also emits a best-effort observability score and the response may be lost after persistence.

## 5. Repository reconciliation

The repository validates the active profile/account, rejects local conversation/message IDs, checks the UTF-16 limit, and sends once.

On an exact valid response:

1. response IDs and field presence are checked;
2. returned feedback must equal the submitted desired state;
3. the exact cached message is patched best-effort;
4. the model updates only after confirmation.

Transport failure, a malformed 2xx acknowledgement, decoding failure, server-readiness failure, or 5xx triggers one idempotent authoritative history read. The mutation itself is never repeated.

- Exact authoritative feedback equals the submitted value: return `reconciledAfterAmbiguousFailure` and install full history.
- The message is missing, duplicated, malformed, foreign, or has a different feedback value: return a typed ambiguity.
- The reconciliation read fails: return verification-unavailable ambiguity.
- 401: propagate unauthorized so the app hides cached history and restores authentication.
- Definitive non-401 4xx: do not retry and do not claim success.

Cancellation is outcome-unknown because it may race a committed PUT. The exact response remains locked until an explicit authoritative reload.

## 6. Native interaction contract

Feedback is available only for a persisted, finished assistant message on the currently selected valid branch when:

- conversation routing and history are authoritative;
- there is no active generation;
- no message edit, regeneration, fork, feedback, or other conflicting mutation is running;
- the message belongs to the exact active profile/account/conversation;
- the response is not local or unfinished;
- the exact message is not already delivery-uncertain.

The message context/accessibility actions offer Helpful and Needs improvement. Existing feedback appears as a semantic badge and opens the same editor. The sheet owns its draft and shows:

- a segmented rating choice;
- only reasons valid for that rating;
- optional details with a truthful 1,024 UTF-16-unit counter;
- a required explanation for Something else;
- explicit server/observability disclosure;
- Save and, for existing feedback, Clear feedback;
- an ambiguity state that permits only close-and-refresh.

There is no optimistic badge or success announcement. VoiceOver announces only confirmed save/clear completion. The sheet cannot be interactively dismissed during transport.

## 7. Verification boundary

The latest combined package run passed **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at `/private/tmp/librechat-visual-audit-core`. Feedback coverage includes the closed registry, exact set/clear JSON and path, no-retry policy, UTF-16 limit, presence-aware clear, response-coordinate proof, unknown/mismatched DTO rejection, historical mapping, and backward cache decoding.

The complete app unit/model/repository target passed **371/371** at `/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`. That run executed focused model tests for selected-branch eligibility, no optimistic mutation during a suspended save, conflicting-operation fencing, exact confirmed patching, ambiguity lock, no second mutation, and explicit authoritative reload. Generic Simulator/device builds also passed.

No authenticated feedback request was made. Live acceptance must still prove set, edit, clear, 400/401/403/404/5xx behavior, lost-acknowledgement reconciliation, server reload persistence, VoiceOver, Dynamic Type, and the server owner's observability policy.

## 8. Required live acceptance

1. Open an authoritative saved conversation and select the visible finished assistant response.
2. Save one positive reason and verify the returned exact coordinates plus persisted badge after reload.
3. Edit it to a negative reason with details and verify the closed reason set.
4. Clear it and verify a present-null response plus no badge after reload.
5. Lose the PUT response after server persistence; verify there is no second PUT and the GET reconciliation confirms the result.
6. Produce a mismatch or unavailable reconciliation; verify the exact response remains locked until refresh.
7. Expire authentication; verify cached history hides and refresh/login recovery owns the next step.
8. Confirm the disclosure matches the deployment's configured observability behavior.
9. Verify VoiceOver, Switch Control, keyboard navigation, and maximum Dynamic Type without clipped reasons or inaccessible actions.
