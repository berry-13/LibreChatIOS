# LibreChat citations, artifacts, code output, Mermaid, and UI resources

## Native Artifact Workspace update

The native artifact card now opens an adaptive workspace keyed by the exact
conversation, message, and server artifact index. On iPhone it pushes through
`NavigationStack` while preserving the originating chat model, scroll position,
and draft; on iPad it remains an inspector that preserves split-view context.
The current native preview is limited to Markdown/plain text with a visible
provenance cue. HTML, SVG, Mermaid, React, and unknown types remain inert
source-only content; no web execution or live artifact acceptance is claimed.
The authoritative artifact edit fence and one-shot save/reconciliation path
remain unchanged, including preserving the local draft after failure.

**Audit date:** 2026-08-18  
**Pinned LibreChat source:** `b2128a7d189ac020ebb6e49a57ee986e98326b77` in `/tmp/librechat-knowledge.mI6Evl/LibreChat`  
**Evidence boundary:** pinned source-contract audit plus native package fixtures and iOS Simulator tests. No authenticated live citation, generated-file pending → ready → download, authorized file-preview, artifact, code-sandbox, Mermaid, or MCP UI-resource flow was exercised for this document.

## Executive contract

LibreChat does not have one generic “rich result” payload. The native client must preserve five distinct mechanisms:

1. web- and file-search results are message attachments keyed to a message/tool call;
2. citation anchors are private-use markers embedded in assistant text and resolved against those attachments;
3. artifacts are fenced directives inside message text/content and are edited by document-order index plus original-content comparison;
4. code execution emits run state and file attachments whose preview lifecycle can change after the first event; and
5. MCP UI resources are attachment payloads referenced from message text by resource ID, including cross-turn references.

These mechanisms share message/tool provenance but have different identity, lifecycle, permissions, and rendering rules. Flattening them into Markdown strings would lose citation resolution, deferred preview state, edit coordinates, and safe recovery after reload.

## Search has two unrelated meanings

| Surface | Contract | Meaning |
|---|---|---|
| Conversation/message retrieval | `GET /api/search/enable` is a configured/healthy Meilisearch probe; actual retrieval is `GET /api/convos?search=...` and `GET /api/messages?search=...`. | Finds the user's existing LibreChat conversations and messages. |
| Web search tool | Selected/configured agent or model-spec tool; results arrive as `attachment` generation events with `type: "web_search"`. | Searches external sources for the current generation and supplies citation data. |
| Agent file search | Permissioned agent tool; results become `file_search` attachments when file-citation policy permits. | Searches files available to the generation and supplies file citation data. |

`GET /api/search/enable` is **not** evidence that the web-search tool is configured, authorized, selected, or supported by the current target. Conversely, a working web-search tool does not prove conversation/message search is available. Source: `api/server/routes/search.js:8-25`, `api/server/routes/convos.js:38-73`, `api/server/routes/messages.js:25-105`, and `api/server/services/Tools/search.js:1-139`.

## Web-search attachment and citation contract

Search results are emitted as an SSE `attachment` event in both standard and resumable generation. The attachment envelope is:

```text
{
  messageId,
  toolCallId,
  conversationId,
  name,
  type: "web_search",
  web_search: {
    turn,
    organic?, topStories?, images?, videos?, news?, places?, shopping?,
    knowledgeGraph?, answerBox?, peopleAlsoAsk?, relatedSearches?,
    references?, error?
  }
}
```

The shared `SearchResultData` definition is intentionally optional/permissive because providers return different categories (`packages/data-provider/src/types/web.ts:43-58`). The server builds the provenance envelope at `api/server/services/Tools/search.js:126-139`. When highlight extraction marks a source as processed, the server emits the same logical attachment again with the same message/tool/name and updated search data (`search.js:98-118`). The current web SSE attachment handler appends unkeyed web/file-search attachments; the later turn-map projection then overwrites by turn (`client/src/hooks/SSE/useAttachmentHandler.ts:70-147`; `client/src/hooks/Messages/useSearchResultsByTurn.ts:39-52`). A native reducer should converge earlier by upserting this specific web-search re-emission identity; it must not render every highlight update as a second source set. This identity rule is specific to search re-emission, not a universal attachment rule: file-bearing attachment merge paths use `file_id`/`filepath` plus tool/agent provenance, and server resume/persistence paths use other weaker keys.

### Standard/resumable versus Open Responses wrappers

There are two wire envelopes that must normalize into the same retained attachment, but they are not interchangeable on the wire:

| Generation surface | Streaming event | Payload coordinates |
|---|---|---|
| Standard agent chat | named SSE event `attachment` | `data:` is the attachment object itself. |
| Resumable agent chat | generation chunk `{ event: "attachment", data: attachment }` | the generation manager adds epoch/replay semantics outside the attachment. |
| Open Responses | JSON SSE event with `type: "librechat:attachment"` | the attachment is nested under `attachment`; `sequence_number`, `message_id`, and `conversation_id` are on the outer event. |

The Open Responses tool callback commonly constructs web-search and UI-resource inner attachments without inner `messageId`/`conversationId`; `writeResponsesAttachment` supplies those values on the outer wrapper. The file-search helper already constructs inner IDs, so a decoder must accept the duplication without treating the wrapper itself as a source attachment. Normalize outer snake-case coordinates only when the inner value is absent, preserve the sequence number for event ordering, then feed the normalized inner attachment to the same identity/upsert path used by standard and resumable chat. Source: `api/server/controllers/agents/callbacks.js:650-667,729-827,1044-1142` and `packages/api/src/agents/responses/handlers.ts:807-892`.

History persistence is also asymmetric at the pinned revision. Mongo permits an unrestricted mixed `attachments` array and the message-history route returns the saved message DTO, so saved search attachments can survive history unchanged (`packages/data-schemas/src/schema/message.ts:113-136`; `api/server/routes/messages.js:280-305`). Ordinary LibreChat chat finalization awaits `artifactPromises` and assigns the results to `responseMessage.attachments` before persistence (`api/app/clients/BaseClient.js:836-838`); resumable continuation explicitly merges prior and new attachments (`api/server/controllers/agents/resume.js:87-182,326-332`). That only proves persistence for attachments collected as tool artifacts. A live web-search attachment emitted directly by `createOnSearchResults` is not automatically added to `artifactPromises`, so it is not guaranteed to appear after history reload unless the tool-output path also contributes the corresponding artifact.

Open Responses is weaker still: `store: true` calls `saveResponseOutput`, which extracts and stores assistant text but has no attachments field (`api/server/controllers/agents/responses.js:213-246`). The streaming Responses path saves before its asynchronous artifact promises are awaited, and the non-streaming path waits for processing but still does not pass the results to `saveResponseOutput` (`responses.js:866-899,1046-1064`). Therefore a source set observed live through Open Responses is **not proven to round-trip through LibreChat message history**. A native cache may retain live source evidence for recovery, but must record transport/provenance and must not claim that a later text-only history response is an authoritative deletion.

Assistant text refers to search/file sources through literal escaped markers or the corresponding actual Unicode private-use characters. Both forms are valid at the pinned revision:

| Marker | Meaning |
|---|---|
| `\ue202turn0search0` or `U+E202` + `turn0search0` | One standalone citation. |
| `\ue200 ... \ue201` or `U+E200 ... U+E201` | A composite containing multiple `U+E202` anchors. |
| `\ue203 ... \ue204` or `U+E203 ... U+E204` | Highlighted cited span, normally followed by an anchor/group. |

Anchor grammar is `turn{N}{type}{index}`. The supported reference types in the parser are `search`, `image`, `news`, `video`, `ref`, and `file` (`client/src/utils/citations.ts:1-45`). Orphaned or out-of-range anchors must fail closed into cleaned text rather than unsafe links or fabricated sources. The source display may contain title, attribution/domain, snippet, link, image, and file-specific page/relevance metadata; a native citation sheet should expose only validated URLs and authorized file previews.

The parser vocabulary is broader than the web client's visible source catalog. Its inline resolver maps reference types as follows (`client/src/components/Web/Context.tsx:27-97`):

| Anchor type | Lookup array | Pinned web-renderer behavior |
|---|---|---|
| `search` | `organic` | Inline citation and general source list. |
| `news` | `topStories` | Explicit remap; the separate optional provider `news` array is not used for `news` anchors. |
| `image` | `images` | Accepted by the parser and resolved by fall-through lookup; images also have a source-panel tab. |
| `video` | `videos` | Accepted by the parser and resolved by fall-through lookup, but the source-panel tab builder does not render a videos tab. |
| `ref` | `references` | Explicit remap. |
| `file` | `references` in the web client's merged turn map | Explicit remap after file sources have been projected into references. |

The visible source panel aggregates `organic`, `topStories`, `images`, file references, and `answerBox`; it does not enumerate `videos`, the provider's separate `news` array, or every other optional `SearchResultData` category (`client/src/components/Web/Sources.tsx:574-718`). Native code should preserve all raw provider categories, implement only proven anchor mappings, and distinguish “parseable inline anchor” from “category has a complete directory renderer.”

## File-search citations

The runtime file-search payload is attachment-oriented even though its shared property is typed broadly as `SearchResultData`. Its important shape is:

```text
{
  type: "file_search",
  messageId,
  toolCallId,
  conversationId,
  name,
  file_search: {
    sources: [{
      fileId, fileName, pages?, relevance?, pageRelevance?,
      snippet?, refType?, metadata?, ...unknown
    }]
  }
}
```

The server applies the `FILE_CITATIONS`/`USE` permission, relevance threshold, total citation limit, and per-file limit before constructing the attachment. Permission denial or a policy-check error yields no citation attachment, not an implied authorization (`api/server/services/Files/Citations/index.js:23-92`; permission definition `packages/data-provider/src/permissions.ts:45-55,78-95,213-221`). The web client deduplicates sources by `fileId`, merges pages/page relevance, and keeps the maximum relevance (`client/src/hooks/Messages/useSearchResultsByTurn.ts:24-120`). Native decoding should retain the original source objects and perform display deduplication separately so future fields and exact provenance survive cache restore.

### File citation coordinates are hazardous at the pinned revision

The apparent `turn/index` coordinate is not a stable source identity end to end:

1. The file-search tool assigns `\ue202turn0file{index}` while formatting the top ten distance-sorted chunks, before citation policy is applied (`api/app/clients/tools/util/fileSearch.js:142-181`). If one per-file request fails, `validResults` removes the null response and then indexes the compressed array back into the original `files[fileIndex]`; a surviving later file can therefore receive the wrong `fileId` (`fileSearch.js:127-151`).
2. `processFileCitations` subsequently filters by minimum relevance, groups by file, applies per-file/total limits, and globally re-sorts by relevance (`api/server/services/Files/Citations/index.js:63-70,102-121`). This can remove or reposition the source that the model saw at a given anchor index.
3. The web hook then deduplicates those attachment sources by `fileId` before constructing `references` (`client/src/hooks/Messages/useSearchResultsByTurn.ts:55-115`). Inline file citation lookup uses this shorter display array, so repeated chunks from one file can shift every later index.
4. Every file-search result set is instructed with `turn0`, while the client independently numbers file attachments from zero and stores web and file search data in the same `turnMap`. A web turn and a file turn with the same number overwrite one another according to attachment order (`fileSearch.js:175-206`; `useSearchResultsByTurn.ts:40-125`). Multiple file-search calls also cannot express their actual encounter turn in the emitted attachment because the file payload has no `turn`.

These are source-confirmed collision/misbinding hazards, not a contract the native client should reproduce. Preserve the received raw source order and perform file-card deduplication only for display. Do not resolve an anchor against the deduplicated array. When filtering/reordering, repeated-file indices, missing turn evidence, or a web/file turn collision makes the target ambiguous, strip the private marker and present an unresolved/source-set affordance rather than opening a possibly wrong file. Full correctness requires a server change that emits an explicit file-search turn and a stable citation/source identifier preserved from prompt through policy filtering; `fileId` alone is insufficient because multiple cited chunks/pages can belong to one file.

`FILE_CITATIONS/USE` authorizes citation emission, not file access. `GET /api/files/:file_id/preview` is independently protected by the files router's JWT/config/ban middleware and `fileAccess`; the middleware requires owner or agent-derived `VIEW` access, enforces tenant equality, and can return 401, 403, or 404 (`api/server/routes/files/index.js:20-25`; `api/server/middleware/accessResources/fileAccess.js:79-149`; `api/server/routes/files/files.js:368-446`). Preview state is `pending`, `ready`, or `failed`; ready text appears only when available, and stale pending preview extraction can be failed lazily by the route. Download is a separate authorized request. The native citation sheet must re-request the appropriate authorized preview/download route and handle every denial; attachment metadata or a rendered citation is never an access token.

## Artifact directives and editing

Model-created artifacts live in ordinary assistant text/content as remark-directive containers:

`````text
:::artifact{identifier="unique-identifier" type="mime-type" title="Artifact Title"}
````
complete artifact content
````
:::
`````

The outer `:::` container and its `identifier`, `type`, and `title` are part of the persisted message contract. The inner content can itself contain a backtick/tilde fence, so a parser must find the container boundary without terminating on nested fenced code. Source parsing/edit logic is in `packages/api/src/artifacts/update.ts:1-220`; prompt contract and examples are in `packages/api/src/prompts/artifacts/index.ts:35-81`.

Prompt-advertised types at the pinned commit are HTML (`text/html`), SVG (`image/svg+xml`), Markdown (`text/markdown` or `text/md`), Mermaid (`application/vnd.mermaid`), and React (`application/vnd.react`). Plain text is also a first-class viewer type in client artifact routing, while code/output files and office previews introduce additional internal viewer MIME values (`client/src/utils/artifacts.ts:275-305,609-625`). Treat MIME as extensible: known-safe types get typed viewers; unknown types remain downloadable/inspectable metadata rather than being injected into HTML.

Artifact editing is:

```text
POST /api/messages/artifact/:messageId
{ index, original, updated, isTemporary? }
```

`index` is the artifact's document-order index across message text/content. The server verifies ownership, bounds, and that `original` still matches inside that exact artifact before saving the updated message (`api/server/routes/messages.js:199-273`). The native client must not key edits only by `identifier`, and it must treat “original content not found” as a conflict requiring message refresh. `isTemporary` is accepted by message persistence even though the shared client request type currently omits it.

### Native artifact-edit admission boundary

The native editor preserves a local draft but does not treat it as authority to
write. Opening and submitting require exact authoritative, valid, persisted
assistant history and routing, one uniquely identified finished artifact, a
valid message tree, and an idle conversation with no active generation,
recovery, pending HITL interaction, or competing mutation. Cached/offline
history fails closed. The complete parsed artifact baseline is rechecked just
before the one-shot POST, so stale document-order coordinates or changed
original content cannot be sent. A rejected preflight or non-auth failure keeps
the draft available for review; a 401 invalidates the edit authority and does
not leave a stale editable state. This is compile-only fixture/build evidence,
not authenticated live artifact-edit acceptance.

## Mermaid

Mermaid may appear as a normal fenced code block, an artifact with type `application/vnd.mermaid`, or a tool-generated Mermaid attachment routed into an artifact card. Each diagram needs stable per-message identity so multiple diagrams and streaming edits do not collide.

The web renderer parses Mermaid with `securityLevel: "strict"`, disables HTML flowchart labels, caps text/edges, sanitizes the generated SVG, and then displays a blob URL (`client/src/hooks/Mermaid/useMermaid.ts:79-145`; `client/src/components/Messages/Content/Mermaid/useSvgProcessing.ts:61-91`). Native parity does not require porting the JavaScript renderer into the message list. A constrained `WKWebView` may render Mermaid off the main text path, but the output must be isolated, navigation/bridges restricted, and SVG treated as untrusted. Export must use the sanitized rendered representation or an explicit source export—not arbitrary HTML injection.

## Code-sandbox lifecycle and generated files

Server code execution is not device code execution. A native app must never run returned source with local process authority.

The generation stream can emit:

```text
event: on_sandbox_starting
data: { tool_call_id, runId }
```

This event is generation-fenced and explains cold-boot latency for the matching code tool call (`api/server/controllers/agents/callbacks.js:236-263`). It is activity state, not a new sandbox credential or a guarantee that execution succeeded.

Code output files have two distinct session concepts. The transient execution session is not the long-lived `storage_session_id` in a structured `codeEnvRef`; the latter is paired with `file_id` and resource kind/identity (`packages/data-provider/src/codeEnvRef.ts:22-59`). Preserve both names and never substitute one for the other.

Generated-file attachments can arrive first as `status: "pending"`, then be re-emitted as `ready` with `text`/`textFormat` or `failed` with `previewError`. They must be upserted by the exact `(file_id ?? filepath) + toolCallId + agentId` identity while keeping distinct tool-call/agent provenance; a replayed pending event must not regress a ready/failed record (`client/src/hooks/SSE/useAttachmentHandler.ts:53-148`). The native domain preserves these attachments in both historical messages and standard/Responses SSE streams, and the reducer upserts lifecycle updates rather than appending duplicates. An ambiguous wildcard SSE update fails closed rather than selecting an arbitrary card. Authenticated per-file terminal reconciliation may fan lifecycle state out to matching cards only while preserving each card's message/tool/agent provenance. Pending polling is ownership-scoped; when the same file moves to a different message, tool call, or agent, the prior poll is cancelled and the new owner restarts its own bounded polling lifecycle. Preview/download route factories are explicit: authenticated preview uses `GET /api/files/:file_id/preview`, ordinary download uses `GET /api/files/download/:userId/:file_id` or a server-provided download URL, and code-output fallback uses `GET /api/files/code/download/:session_id/:fileId`. HTML `textFormat` is never injected; only plain text is previewed natively. The app presents a semantic message card with pending/ready/failed states, explicit authenticated download/share actions, and profile/account-namespaced local copies. Live authenticated pending → ready → download acceptance remains pending. Polling contract:

- `GET /api/files/:file_id/preview` → `{file_id,status,text?,textFormat?,previewError?}` (`api/server/routes/files/files.js:368-446`);
- `GET /api/files/code/download/:session_id/:fileId` returns the authorized code-output stream and validates both route IDs (`files.js:313-366`).

Persist lifecycle metadata and provenance, not temporary signed URLs or rendered web state. Unsupported HTML/SVG/Mermaid/React/unknown output remains source-only metadata and never executes in the chat renderer. A future Mermaid compatibility surface must be constrained and separately accepted; source-only behavior is the current safe fallback.

## MCP UI resources

UI resources are attachment metadata, not arbitrary message HTML:

```text
{
  type: "ui_resources",
  messageId,
  toolCallId,
  ui_resources: [{ resourceId, uri, mimeType?, text?, ...unknown }]
}
```

The stable schema deliberately retains unknown fields (`packages/data-provider/src/schemas.ts:879-895`). Assistant text references one or more resources as `\ui{id}` or `\ui{id1,id2}`; one ID renders one resource and multiple IDs render a carousel (`client/src/components/MCPUIResource/plugin.ts:5-90`). Resolution is conversation-wide across persisted messages and in-flight attachments, enabling cross-turn references (`client/src/hooks/Messages/useConversationUIResources.ts:8-54`). Duplicate `resourceId` behavior is last-writer-wins in the web map, so native persistence must retain attachment order and message/tool provenance rather than maintaining only a lossy global dictionary.

Interactive HTML must use a sandboxed `WKWebView` compatibility surface with a narrowly typed action bridge. It should not inherit app cookies, arbitrary navigation, unrestricted popups/downloads, or direct access to MCP credentials. Native renderers may cover known static MIME types, but unsupported resources must remain a typed, recoverable placeholder rather than disappearing.

## Native domain and reducer boundary

At minimum, introduce typed envelopes equivalent to:

```text
MessageAttachment
  - identity: messageId, toolCallId, conversationId, name/fileId
  - provenance: agent/run/turn where present
  - payload: webSearch | fileSearch | generatedFile | uiResources | unsupported

CitationAnchor
  - turn, referenceType, index, group/highlight relationship

Artifact
  - messageId, documentOrderIndex, identifier, title, mimeType, sourceContent

GeneratedFilePreview
  - fileId, executionSessionId?, storageSessionId?, pending|ready|failed
```

Unknown attachment/resource fields should remain lossless `JSONValue` data below the domain boundary. UI snapshots may expose a safe summary but must never be the only persisted form. Sync/history and replayed attachment events must converge on the same reduced state.

## Current native status and bounded gaps

The citation **protocol and native presentation slice is implemented, package/UI fixture-tested, and full-suite Simulator tested, but not authenticated/live-proven**. `LibreChatDomain/Citations.swift` retains lossless web/file source provenance, models search-specific attachment identity/upsert, maps the proven web reference arrays, produces cleaned text plus ordered inline render segments, and intentionally refuses to resolve unsafe file-position anchors. `LibreChatProtocol/Citations.swift`, `DTOs.swift`, `GenerationDecoder.swift`, and `GenerationReducer.swift` normalize history, standard/resumable events, and the nested Open Responses wrapper into `ChatMessage.citationAttachments`; live highlight re-emissions update the retained response rather than becoming visible duplicates. The package preserves unknown provider fields, validates only HTTP(S) source URLs, and keeps deduplicated file cards separate from raw provenance.

`CitationViews.swift`, `MessageRow.swift`, and `ChatView.swift` provide the native app surface. Resolved web anchors render as selectable numbered inline citations; composites remain one control and open one native sheet. A message-level Sources control opens a deduplicated directory covering organic results, top stories, images, videos, general references, and display-deduplicated file sources. Source rows show safe title/attribution/domain/snippet data, while file rows expose pages and relevance plus an explicit preview-unavailable explanation. Only validated HTTP(S) links with a host can leave the app; `javascript:`, `file:`, and pseudo-file URLs are rejected. Accessibility labels use cleaned Markdown text so private-use markers and raw link syntax are not announced, and the Sources control exposes counts and a descriptive hint.

Final verification evidence is tracked in the repository README and traceability matrix. This document's rich-content fixtures include generated-file decoding and lifecycle reduction, but no authenticated live pending → ready → download run; the installed-build screenshot remains startup smoke only.

Authenticated streaming/history interoperability remains unproven. Open Responses history loss and direct live-web-search history gaps remain server-side compatibility constraints. Positional file anchors remain cleaned but deliberately unresolved until the server supplies stable post-policy coordinates; file source sets are presented only through the non-positional directory. Generated-file preview/download is independently authorized through authenticated routes with transport retry disabled and profile/account-namespaced local copies. The exact-echo/shape validator, bounded inert text, terminal-no-pending-regression reducer, fail-closed ambiguous wildcard handling, provenance-preserving per-file terminal fan-out, and ownership-scoped active-chat 2.5-second/five-error poll coordinator are package-tested and app-compiled; a same-file message/tool/agent ownership move cancels the old poll and restarts it under the new owner. HTML/SVG/Mermaid/React/unknown output remains source-only and never executes. Artifact directive parsing/editing is implemented behind semantic native cards with exact server content-part global provenance, legacy-text fallback only when content has zero raw candidates, exact document-order indexing, safe Markdown/plain previews, copy/share, and one-shot edit reconciliation. Source viewing remains available, but edit admission now requires exact authoritative valid persisted assistant routing/history, a valid tree, a uniquely identified finished artifact, no active/paused/reconnecting generation, no recovery/HITL, and no competing mutation. The full parsed baseline is compared again immediately before POST, so cached/offline content and a sheet opened before a server-state transition cannot bypass the model fence. Rejection preserves the local draft; a 401 invalidates the edit rather than retaining stale authority. Current generated-preview and artifact regressions compile in `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`; they have not executed because no Simulator was booted. Authenticated live generated-file pending → ready → download and artifact streaming/history/edit acceptance, including temporary-message retention, Mermaid rendering/export, sandbox HTML/SVG/React, and the MCP UI-resource index/renderer/action bridge remain pending.

Remaining citation acceptance work before live promotion:

1. exercise standard and resumable raw `attachment` events plus the nested Open Responses `librechat:attachment` wrapper against an authenticated deployment, including sequence ordering, highlight re-emission, and persisted-versus-live-only history restoration;
2. prove authenticated rendering/history recovery for literal and actual-Unicode standalone/composite/highlight markers and the provider categories used by the native directory;
3. exercise file-search permission absent/denied, pre-policy index removal/reordering, repeated-file display deduplication, web/file turn-zero collision, multiple file searches, failed per-file request attribution, and an independently authorized preview/download implementation without converting an ambiguous anchor into a file link;

The other rich-content mechanisms still require:

1. multiple artifacts interleaved with text and nested code fences; edit success, stale-original conflict, index out of bounds, and temporary message;
2. multiple Mermaid blocks with stable identities, malformed/oversized diagrams, sanitization, export, Reduce Motion, and accessibility fallback;
3. `on_sandbox_starting`, sibling tool calls, execution-vs-storage session distinction, pending → ready/failed, replayed pending after terminal state, and authorized download;
4. UI resources across turns, single/carousel markers, missing/duplicate IDs, unknown MIME/fields, cache restore/share view, denied navigation, action-bridge validation, and profile/account isolation.

Passing these fixtures promotes protocol coverage only. Shippable/live status still requires an authenticated deployment run that proves streaming updates, history restoration, authorization failures, background/relaunch reconciliation, and the sandboxed renderer on supported iOS versions.
