# Native AI product design decision framework

**Status:** design decision framework, updated 2026-08-19  
**Applies to:** the native iOS LibreChat client, iOS 17 minimum and iOS 26 progressive enhancements  
**Evidence standard:** product mechanics are grounded in the competitive research and the pinned LibreChat source audit. Eighteen current first-party App Store frames have now been captured and inspected across ChatGPT, Claude, Gemini, Perplexity, Poe, and Grok. They support bounded visible-hierarchy claims only; they do not prove authenticated navigation, motion, hit targets, focus, accessibility semantics, or iPad adaptation.

This is a decision framework, not a screen specification. It gives the app a coherent point of view before visual directions are created, and protects it from becoming a collection of copied competitor patterns or a thinner rendering of the LibreChat web client.

## Decision in one sentence

Build **a calm, trustworthy native workspace for conversations that may become work**: simple for a fast question, legible and recoverable when it uses files, tools, agents, research, approvals, or a self-hosted server.

The product wins by making the effective execution contract understandable at the moment a user sends work, and by making interrupted work reliably returnable. It should feel lighter than a desktop control plane while being more honest about capability, provenance, and recovery than a generic chatbot.

## Evidence boundary and inputs

### What is established

- LibreChat is a server-configured, permissioned product rather than one fixed API/UI contract. Startup configuration, endpoints/models, resources, and generation protocol are independently discovered. See [Source baseline](../LibreChatKnowledge/SourceBaseline.md) and [Capabilities, agents, and advanced features](../LibreChatKnowledge/CapabilitiesAgentsAndAdvancedFeatures.md).
- A generation v2 run is a durable, server-owned job identified by both conversation/stream identity and its generation epoch. It can reconnect, reconcile, be replaced, pause for a decision, or complete after the app leaves the foreground. See [Generation protocol v2](../LibreChatKnowledge/GenerationProtocolV2.md).
- Conversations, files, projects, agents, presets, memories, tools, sharing, and permissions are meaningful scopes of user work—not merely menu items. See [Conversations, messages, and files](../LibreChatKnowledge/ConversationsMessagesAndFiles.md).
- Competitive official-source research repeatedly describes the same useful mechanics: a progressive capability composer, visible model/agent selection, durable research work, source/provenance controls, projects, and artifacts. See [ChatGPT research](../Audits/ChatGPT.md), [Claude research](../Audits/Claude.md), and [other major AI apps](../Audits/OtherMajorAIApps.md).
- The accepted 2026-08-19 visual evidence shows a repeated visible relationship between target/mode identity and the composer or conversation chrome, stable bottom composition, unboxed assistant prose, and typed rich-result surfaces. See the [screenshot-led competitive visual audit](CompetitiveVisualAudit-2026-08-19.md).

### What remains unproven

- No accepted direct screenshots exist for authenticated competitor product surfaces. The accepted frames are publisher-verified Apple promotional iPhone imagery, not a live interaction trace.
- No claim here establishes competitor hit targets, focus order, VoiceOver behavior, Dynamic Type, motion, back behavior, keyboard avoidance, or current iPad navigation. Exact typography, spacing, and colour may be observed only inside the captured marketing frames and must not be generalized to the live product.
- The native app itself has a functional core but still has documented P0/P1 protocol and product gaps. Its current shell is not a visual reference. See [Native client gap matrix](../LibreChatKnowledge/NativeClientGapMatrix.md).

### Decision rule

Use direct native usability testing and captured visual references to decide *how* a surface looks. Use the server contract to decide *what state the surface must faithfully express*. Never use a pretty visual treatment to hide an unavailable, unresolved, unauthorized, or non-recoverable server state.

## Product position

### The user promise

> Ask quickly. Work deeply when needed. Always know what will be used, where it runs, and how to return if you leave.

This is deliberately different from a “provider catalog” or a desktop dashboard compressed into a phone. LibreChat’s advantage is breadth and self-hosted control; the native app must turn that breadth into composable, understandable work rather than a dense settings hierarchy.

### The core user modes

| User intent | Native promise | Primary product surface | Avoid |
|---|---|---|---|
| Ask | Send a question with almost no ceremony. | A focused chat and composer. | Forcing project/tool/model setup before a first message. |
| Shape | Deliberately choose model, assistant, scope, or reusable instructions. | Target and scope sheets, with plain-language summaries. | A raw list of provider IDs and toggles. |
| Work | Attach files, use tools/search, or run an agentic task. | Execution envelope, activity timeline, artifact/result route. | A generic spinner that hides input scope and progress. |
| Decide | Approve a tool, answer a question, or complete external auth. | A durable, typed pending-interaction surface. | Treating it as an error card or a modal that disappears on reconnect. |
| Return | Resume an interrupted conversation or long-running job. | Library recovery state and a reconstructed chat. | Duplicate messages, false “failed” results, or invisible continued work. |
| Govern | Manage server, account, privacy, memory, connections, and local cache. | Account/server space distinct from normal chat. | Polluting the main chat screen with infrastructure controls. |

## Distinctive experience pillars

### 1. Calm by default, depth by invitation

The default conversation should contain only the information needed to read, write, and understand the next action. The composer is not a cockpit. Advanced context appears through a single capability entry point and compact, removable state chips.

**Design consequence:** one obvious text field, one obvious Send/Stop action, and a compact execution summary. A user should be able to send a normal question without learning projects, MCP, model specs, or agent configuration.

**Server consequence:** the compact summary represents the real selected target, project, privacy/temporary state, files, and enabled tools. It cannot be decorative or inferred from stale local state.

### 2. The execution envelope is a user contract

Every nontrivial send has an inspectable sentence such as:

```text
Research Agent · Project: Launch · 2 files · Web search · Private server
```

This is not a raw request inspector. It answers four human questions:

1. Who/what will answer? (model, assistant, agent, or spec)
2. What may it use? (files, project sources, web search, tools/connectors)
3. Where does the work live? (server/profile, temporary/persistent conversation, project)
4. What changes if I proceed? (time, cost/usage when available, privacy, unavailable capability)

**Design consequence:** the user sees active choices before committing work, rather than discovering incompatible tools after writing a prompt.

**Protocol consequence:** source scope and tool permissions come from authenticated server policy and selected resource/target. Unknown capability triggers discovery or safe negotiation, never silent enablement.

### 3. A run is a durable object, not an animation

Generation v2 supplies the semantics required for a dependable mobile job experience: unique epoch, reconnection, authoritative sync, replay, pending interaction, replacement, status and terminal reconciliation.

The UI should use one understandable activity vocabulary:

```text
Preparing → Working → Needs you → Reconnecting → Finalizing → Complete
```

The user sees phase, current meaningful activity, elapsed time when useful, available action, and recovery promise. Internals such as SSE, epochs, run-step event names, or retry counters remain hidden unless a diagnostic view is deliberately opened.

**Design consequence:** a long running job can leave the screen without “breaking”. The conversation library and chat header can both surface its recoverable status.

**Protocol consequence:** this state language is derived from the generation reducer, status, sync, pending action, and terminal evidence—not timers or UI guesswork.

### 4. Human intervention is a normal turn in the conversation

Tool approval, a user question, and external authorization are three different user actions, but one product category: **the run needs a decision**. They must persist across stream loss, backgrounding, and relaunch as long as the server says the action is live.

**Design consequence:** pending work becomes an explicit, accessible card or sheet with clear consequences, not a generic JSON blob. It always explains the request, which connected service/tool is involved, the allowed decisions, and what happens after approval or rejection.

**Security consequence:** decision UI is bound to the server-issued action ID and generation epoch. It never invents an action, submits broad approval, or replays a decision after a replacement run.

### 5. Provenance is part of reading, not an audit afterthought

For a self-hosted, multi-provider assistant, trust must be visible in the response and before execution. A source, tool, file, agent, project, and output artifact each have a relationship to the answer.

**Design consequence:** citations, sources, tool outcomes, attachments, model/agent, and generated artifacts are compactly inspectable from the response. The default reading flow stays clean; context expands on demand.

**Content policy:** never expose private chain-of-thought as a substitute for useful transparency. Show actionable plans, user-facing activity labels, sources, tool inputs/outputs when appropriate, and a concise explanation of action scope.

### 6. Context has a home

Projects are context boundaries, not coloured folders. A project can own conversations, instructions, files/sources, selected agent/spec, applicable memories, artifacts, and access/sharing state.

**Design consequence:** users can begin a chat outside a project, then consciously place or move it into a project. The active project appears in the execution envelope and conversation header. A “New Chat” should never silently inherit unrelated source or connector scope.

**Capability consequence:** a server without projects still provides a complete conversation experience. Project affordances are absent or clearly unavailable; they do not become broken placeholders.

### 7. Recovery is a visible mark of quality

Mobile networks, self-hosted deployments, account changes, and foreground/background transitions are ordinary conditions. The app should preserve local work while being clear that server state is authoritative.

**Design consequence:** drafts, staged uploads, partial text, and nonterminal job indicators remain visible. A failure message states what was saved, what may still be running on the server, and what Retry/Reconnect will do. Cache freshness is discoverable without being noisy.

**Trust consequence:** no false completion. A socket closing is not a final answer; a server replacement is not the original run; a stale cached conversation is not an active remote session.

### 8. Native reading and touch come first

The product should use standard SwiftUI navigation, sheets, menus, toolbars, selection, text rendering, accessibility, and platform adaptations wherever possible. Liquid Glass is reserved for application chrome and primary controls on supported systems—not message surfaces, code blocks, or tool output.

**Design consequence:** large content surfaces remain high-contrast and stable; the app feels native at iOS 17 and gains iOS 26 polish without making readability or function depend on new visual APIs.

## Anti-copy principles

These constraints are intentional. They prevent a “ChatGPT plus Claude plus LibreChat” collage.

| Do not copy | Why it fails here | Better native LibreChat response |
|---|---|---|
| A desktop sidebar shrunk into an iPhone drawer. | It produces buried creation, unreadable labels, and a split mental model. | Make Chat primary; put Library/search/projects in a deliberate navigation destination or sheet. |
| A provider/model dropdown as the product. | Model names do not express permission, cost, scope, or task fitness. | Present targets by intent and capability, with provider details available in a secondary sheet. |
| A dense icon rail for every capability. | It hides availability and creates touch/accessibility ambiguity. | One labeled capability entry point plus persistent summary chips for active choices. |
| Generic “thinking” bubbles or exposed private reasoning. | It can be inaccurate, unsafe, and offers little user control. | Show activity labels, plan/progress, source/tool work, and a stop/refine path. |
| Infinite token-by-token visual churn. | It destabilizes reading and overwhelms VoiceOver. | Coalesce visible updates; publish state changes immediately and prose at reading-friendly cadence. |
| A web-like right-hand canvas on a narrow phone. | It breaks reading context and back navigation. | Use a full-screen adaptive Artifact Workspace keyed by conversation, message, and server index, with source-message provenance and restored return position; keep iPad in an inspector when appropriate. |
| An optimistic approval/stop UI disconnected from server confirmation. | LibreChat runs have epochs, replacement and reconciliation semantics. | Keep the action in a temporary resolving state until status/final evidence confirms outcome. |
| A full-screen infrastructure setup experience inside every chat. | Self-hosting complexity would crowd out the primary task. | Keep server/account cues quiet but reachable; escalate only for errors, trust changes, or switching. |
| “Feature parity” navigation that exposes every server route. | Server capability does not mean native support or user value. | Gate features by both server capability and native implementation readiness. |
| Glass applied to content cards. | Blur harms text/code/tool readability and accessibility. | Use semantic content surfaces; use glass only for chrome and small controls where the OS supports it. |

## Interaction and state taxonomy

The interface must be designed from states, not only destinations. The taxonomy below is the minimum semantic vocabulary shared by feature models, content components, analytics/diagnostics, and accessibility announcements.

### A. App and identity state

| State | User-facing meaning | Primary action / recovery | Visibility |
|---|---|---|---|
| No server | The app is not connected to a LibreChat installation. | Add server. | Full onboarding surface. |
| Discovering server | The app is checking sign-in methods and compatibility. | Cancel / edit server address. | Focused progress with clear server identity. |
| Signed out | A server is known but there is no usable account session. | Sign in; use supported methods. | Authentication surface. |
| Two-factor pending | Password was accepted; proof is still required. | Enter TOTP or backup code. | Focused secure step; never call it a signed-in state. |
| Authenticated online | Account and server are available. | Normal app use. | Quiet profile/server identity. |
| Authenticated offline | Last verified local cache is available; remote mutation is unavailable. | Retry connection; edit drafts. | Clear but non-alarming library/chat banner. |
| Session expired | Cached data is intentionally hidden because the server rejected the session. | Sign in again. | Authentication surface; do not present stale private data. |
| Profile switching | Current work is checkpointed and streams detach. | Select/return to profile. | Brief transition; warn only if an active job is being left. |

### B. Library and conversation state

| State | Required experience |
|---|---|
| First use / empty library | Explain the first useful action; New Chat is primary; no decorative “empty” dead end. |
| Cached then refreshing | Show useful cached conversations immediately and an unobtrusive freshness/progress affordance. |
| Search | State scope (conversation titles/content, project/files if later supported), filters, no-results, and offline limitations explicitly. |
| Conversation selected | Preserve scroll/reading location, title, target/project summary, and active run state. |
| New chat, uncommitted | Local composition space with chosen target/scope; no fake server record. It becomes a remote conversation only when the server accepts a generation. |
| Archived/deleted/unavailable | Explain whether local cache remains, whether restoration is possible, and use server truth for final removal. |
| Active remote work | Surface a small durable status in library rows; opening it restores the corresponding run, never starts a duplicate. |

### C. Composer state

| State | Required experience | Accessibility behavior |
|---|---|---|
| Idle | Plain text prompt, active target/scope summary, add-capability button, Send disabled until valid input. | Describe active target and scope as a concise value, not a stream of decorative chips. |
| Editing draft | Draft persists locally; changing conversation/profile cannot silently lose it. | Keyboard focus remains in text editor; target changes are announced once. |
| Capability choosing | Attachments, photo/camera, source scope, tools, research mode, temporary mode, and voice are presented only when supported. | Each unavailable choice explains why and its next valid path. |
| Upload staging/uploading | File previews with name/type/size, progress, cancel/retry/remove; not yet assumed visible to model. | Progress changes are throttled; errors name affected file and recovery. |
| Ready | Execution envelope and any attachment chips are final enough to understand before send. | Send label includes context only if it changes the outcome materially. |
| Starting | Input is preserved until server receipt resolves; user can see that creation is in progress. | Announce “Starting response”; do not announce each transport retry. |
| Streaming | Send becomes Stop; new input/steer policy is explicit instead of silently discarded. | Announce a concise generating state, then completion/state boundaries—not every token. |
| Awaiting user | Composer yields to a typed decision/answer control. | Focus moves to the pending action title and then the first decision control. |
| Read-only/offline | Draft can be edited, but remote Send explains why it is unavailable. | Disabled Send has a readable reason and retry path. |

### D. Generation and activity state

| Product state | Protocol evidence | User-visible representation | User actions |
|---|---|---|---|
| Preparing | Start acknowledged, created/early activity. | Compact activity capsule, provisional response area. | Stop if server permits. |
| Working | Live message/tool/run-step/activity events. | Stable response plus expandable activity summary/timeline. | Stop; inspect context; steer only when server confirms it is available. |
| Needs you | `requires_action` / pending action. | Prominent decision card; conversation is still live. | Approve/reject/edit/respond or complete external auth. |
| Reconnecting | Stream lost while handle remains nonterminal. | “Continuing on server” with last update and retry state. | Reconnect now, leave safely, cancel only when confirmed available. |
| Reconciling | Replacement, terminal reconciliation, ambiguous start, abort race, foreground recovery. | Brief explicit “Checking latest result” state; preserve partial reading. | Retry/check again; do not expose speculative terminal action. |
| Finalizing | Durable terminal work is being confirmed/persisted. | Activity contracts; response stabilizes. | Usually none beyond reading. |
| Complete | Matching normal final or authoritative history/status. | Final response, usage/provenance/artifact actions. | Copy, share where allowed, branch/edit/retry where supported. |
| Stopped | Server confirms abort/unfinished terminal state. | Preserved partial response marked stopped. | Continue/new prompt if server supports it. |
| Failed but recoverable | Explicit error with safe local/server recovery. | Explain failure, saved work, and next action. | Retry/reconnect/edit draft. |
| Replaced | Server says another epoch superseded this run. | Preserve original submitted text; show the current server work separately. | Open current run; recover queued input. |

### E. Rich result and resource state

| Object | Default representation | Expanded representation | Key guardrail |
|---|---|---|---|
| Markdown answer | Readable native text and code blocks. | Copy/share/structured citations where supported. | Do not use a general web view. |
| Code | High-contrast dedicated code block. | Full-screen code/artifact route, copy/export. | Keep text selectable and readable at large type. |
| Citation/source | Compact labeled reference. | Source sheet with title, domain, relation, external-navigation warning. | Never rely on superscript position/colour alone. |
| Tool/run step | One-line semantic status. | Expandable card with relevant inputs/outputs/error, duration, approval state. | Redact/suppress sensitive metadata by default. |
| Artifact/report/file | Message attachment/card. | Dedicated artifact destination with provenance and return route. | Do not strand the user away from the originating conversation. |
| Image/media | Native preview with accessible description/name. | Full-screen viewer, save/share only as policy permits. | Remote preview/download is authorized and server-scoped. |
| Project | Context badge/link. | Project workspace with threads, sources/files, instructions, artifacts, access state. | Project data never leaks across profile/account/tenant. |

## Navigation and device implications

### iPhone: one primary canvas, fast secondary surfaces

**Primary posture:** chat is the app’s main canvas. Navigation must make it easy to start a chat, return to recents, find older work, alter scope, and inspect output without recreating a desktop app in miniature.

Recommended primitives:

- `NavigationStack` for chat → detail/artifact/settings flows.
- A Library destination/sheet with recents, search, projects, and saved artifacts/files as the product expands. New Chat remains reachable from the navigation chrome and Library.
- Bottom sheets for target selection, capability configuration, source scope, and contextual action menus. Use full-screen covers for active voice/camera and demanding artifacts/editors.
- A composer anchored to the safe area with enough clearance for keyboards, attachment chips, large Dynamic Type, and stop/pending states.
- A conversation header that is concise by default: title plus a compact target/project/active-job indicator. Detailed configuration opens on demand.

Avoid: a permanently dense sidebar; nested modals that bury the back path; response action rows with many unlabeled icons; requiring landscape width to comprehend a tool result.

### iPad: spatial continuity without forced complexity

**Primary posture:** conversation context can stay visible while the user reads or works. `NavigationSplitView` is valuable when the extra width reduces navigation work, not as a required three-column layout.

Recommended adaptive structure:

```text
Compact iPad / portrait
  Library ↔ Chat (NavigationStack-style collapse)

Regular iPad
  Sidebar: Library / projects / search
  Content: Chat
  Optional inspector: context, activity, source details, or artifact
```

- Use the inspector for one task at a time: active run timeline, artifact/source details, project scope, or selected tool—not all panels simultaneously.
- Keyboard commands should prioritize New Chat, Search, focus composer, send/stop, open activity, and move through conversations.
- Pointer and multiwindow behaviors should preserve server/profile/account isolation. A window can display a snapshot, but no session/cache data crosses profiles.

### iOS 17 baseline and iOS 26 enhancements

| Surface | iOS 17 baseline | iOS 26 progressive enhancement |
|---|---|---|
| Navigation/toolbars | Standard SwiftUI navigation and semantic materials. | System-supported Liquid Glass on navigation/toolbars where appropriate. |
| Composer controls | Clear semantic surfaces, standard buttons/menus, high contrast. | Grouped glass treatment for related chrome controls if it improves hierarchy. |
| Message/content | Opaque/semantic content background, readable code cards. | Same content treatment; no mandatory glass. |
| Accessibility/reduce transparency | Semantic opaque fallback. | Respect system reduction settings; remove/transmute glass accordingly. |

Liquid Glass should sharpen hierarchy at the edge of the interface, never reduce the legibility of a response, artifact, code block, tool result, or accessibility state.

## Design system implications

### Semantic component inventory

The first DesignKit extraction should contain semantic components, not visual-effect abstractions:

```text
ChatComposer
ExecutionEnvelope
TargetSummary
CapabilitySheet
AttachmentChip
GenerationActivityCapsule
RunStepCard
PendingInteractionCard
SourceReference
ArtifactCard
CodeBlock
ServerAccountBadge
OfflineFreshnessNotice
```

There should not be a generic `GlassCard`, nor a universal “AI card” applied to every content type. Components own user meaning, accessibility semantics, loading/error states, and adaptive behavior; visual tokens remain replaceable.

### Content hierarchy

```text
Application chrome
  Navigation, server/account context, primary creation

Conversation content
  User message → assistant response → supporting activity/provenance

Work details
  Expanded tools, sources, files, artifacts, inspector

Governance
  Server/account/privacy/permissions, kept outside normal reading flow
```

### Accessibility and motion contract

- Dynamic Type must allow composer chips and messages to wrap/reflow rather than truncate essential target/scope information.
- All icon-only controls need labels, values, hints where necessary, and an effective 44×44 pt target.
- VoiceOver receives semantic boundaries: “Response generating”, “Needs approval”, “Reconnecting”, “Response complete”, and meaningful file/tool failure. It must not receive every streamed token.
- A pending interaction moves focus to a titled, typed decision surface. On dismissal/reconciliation, focus returns predictably to the conversation or next relevant action.
- Reduce Motion suppresses decorative streaming/capsule animation while retaining status changes. Reduce Transparency/increased contrast keeps chrome and message surfaces legible.
- Tool/source/artifact expansion must have an understandable reading order and retain enough identity when collapsed. Never encode status only through colour, spinning, or spatial position.

## Design risks and non-negotiable mitigations

| Risk | Why it is likely | Required mitigation | Release gate |
|---|---|---|---|
| A beautiful UI misrepresents server state. | LibreChat feature and policy discovery is layered; generations can replace/reconcile. | Drive visible state from capability and generation reducers; unknown ≠ unavailable. | v2 protocol fixtures and simulator state checks. |
| The app exposes a feature that is server-enabled but not natively complete. | Projects/MCP/memory/speech etc. can be configured on server before the client supports them. | Separate server capability, native implementation, entitlement, and current availability. | Capability matrix reviewed per navigation item. |
| Mobile loses user work during interruption. | SSE is not a background task; uploads and runs can outlive the app. | Checkpoint drafts/uploads/jobs; reconnect/reconcile on foreground; visible recovery language. | Background/terminate/relaunch test against live deployment. |
| Approvals/actions become unsafe or confusing. | Server issues specific action/epoch contracts and tool calls can be consequential. | Typed decision UI; show scope; exact action + epoch fence; no optimistic completion. | Resume/approval/rejection/race fixtures. |
| Self-hosting feels frightening or leaks credentials. | Multiple profiles/accounts and TLS configurations are a core use case. | Profile/account namespacing, standard TLS, quiet trust/status cues, no invalid-cert bypass. | Profile isolation and Keychain/cookie tests. |
| Chat becomes visually noisy. | LibreChat’s breadth can lead to stacks of chips, cards and run logs. | One activity vocabulary; collapse secondary detail; summaries are semantic and progressive. | Design review on normal chat, tool-heavy run, and large Dynamic Type. |
| Reading suffers during stream/research. | Token churn, tools, sources, and code compete for attention. | Stable response layout; update coalescing; expand details only on demand. | Simulator performance and VoiceOver pass. |
| The app copies a competitor’s transient visual pattern. | Research currently lacks direct screenshot evidence and products change quickly. | Capture/review exact references before visual selection; use mechanics as evidence, not aesthetics as borrowed truth. | Screenshot/reference checklist below completed. |
| Privacy/trust is hidden in a settings page. | Multiple providers, files/connectors and shares are consequential. | Execution envelope and provenance disclose context at point of use. | Pre-send scope and source disclosure tested. |

## Evidence gaps that constrain visual direction work

Visual directions can be produced only after the following gaps are closed or explicitly accepted by the product owner as a research limitation. The project should not infer exact visual language from help-center copy.

1. **Direct product references:** accepted screenshots of current ChatGPT and Claude iPhone states, plus at least two complementary products for the selected patterns (for example Perplexity research and Gemini project/artifact). A capture needs a visible, stable state; search results or marketing images are not equivalent.
2. **Native baseline references:** accepted screenshots of the current iOS app’s signed-in library, empty New Chat, conversation, target picker, generation, error/offline, and settings. These are needed to understand existing affordances and prevent accidental regression.
3. **Task evidence:** a short usability pass with target users or the product owner for three jobs: quick question, scoped/file-backed work, and interrupted/recovered work. At minimum, record which terms (“agent,” “project,” “tool,” “source,” “temporary”) they understand without explanation.
4. **Server truth:** an authenticated discovery capture from the actual deployment (config, endpoint/model catalog, key feature availability) plus a confirmed target policy, so the visual directions do not depict unavailable functions as immediate product promises.
5. **Operational truth:** live fixture evidence for start/stream/reconnect/approval/abort and upload binding. A visual “research timeline” is premature if the app cannot yet represent authoritative sync and action resumption correctly.
6. **Accessibility reference:** a baseline VoiceOver, largest Dynamic Type, Reduce Motion/Transparency, and hardware keyboard pass on the current native app. This makes typography and control density an evidence-led decision rather than a visual preference.

## Exact capture and reference checklist before three visual directions

The goal is not to collect every screen. It is to capture enough stable evidence to make three genuinely different, defensible native directions. Each saved image must be inspected after capture and rejected if it is blocked, cropped, blank, loading, wrong-state, or contains private data that cannot be retained.

### Capture rules

- Use a valid controllable browser, device, or app surface. Record product, platform/app version, account/plan context, capture date, and task state with each set.
- Capture actual viewed screens only. Do not substitute marketing art, old screenshots, memory, generated mockups, or a similar product.
- Use a fresh/non-sensitive test account and redact personal content before saving. Do not capture credentials, private chats, tokens, cookies, connector secrets, or 2FA codes.
- For each interactive reference, capture both the resting state and the resulting state after the primary action when that change is central to the pattern.
- Keep iPhone captures at a consistent current iPhone viewport and record device/orientation. Capture web/iPad only for patterns that intrinsically require broader spatial context.
- Pair each reference with brief notes: task, visible labels, discovered/hidden controls, apparent state change, and any accessibility observation actually tested. Do not infer untested properties.
- Run direct captures for every source before using it in a visual direction. References should be current enough to guide a product decision, not a style scrapbook.

### A. Competitor mobile-reference captures

The first two sets are required because they are the named reference products. The remaining set supplies complementary patterns rather than a visual mandate.

| ID | Product | Exact states to capture | Purpose | Minimum acceptance |
|---|---|---|---|---|
| C1 | ChatGPT iPhone | Home/library; New Chat empty; active model/mode selector; capability/attachment sheet; normal streaming + Stop; research plan/progress; completed cited response/artifact; privacy/settings. | Compare capability launching, research control loop, source/provenance, and privacy entry points. | 8 stable captures, with one primary interaction pair. |
| C2 | Claude iPhone | Home/library; New Chat empty; model/style selector; composer attachment/dictation; normal streaming + Stop; project context; artifact handoff; settings/connector or unavailable state. | Compare calm chat, reusable style/project context, artifact transition, and mobile input. | 8 stable captures, with one primary interaction pair. |
| C3 | Perplexity or Gemini iPhone | Home; source/mode selector; research setup/plan; active research progress; cited report; project/files; artifact/canvas. | Ground the durable research/job and source-scope pattern. | 7 stable captures, with one research-state progression. |
| C4 | One contrast app (Copilot, Poe, Grok, or DeepSeek) | Target/bot selection; rich result/artifact; source/privacy or usage state; active voice/camera only if available. | Test a distinct model-selection, work-context, or multimodal pattern. | 4 stable captures. |

**Required inspection prompts for every competitor capture:**

1. What is the first obvious action?
2. What state is visible before the user acts?
3. Which critical state is hidden behind an icon, sheet, overflow, or settings path?
4. How does the app say work is active, paused, complete, failed, or restricted?
5. What happens to reading space when controls, sources, or artifacts appear?
6. Which controls look likely to need an accessibility verification pass? Label these as hypotheses unless tested.

### B. Current native LibreChat reference captures

| ID | Exact app state | Why it is required | Test notes |
|---|---|---|---|
| L1 | Signed-in iPhone conversation library with several conversations. | Baseline hierarchy, row density, New Chat reachability, and scroll behavior. | Include normal and large Dynamic Type. |
| L2 | Empty/uncommitted New Chat with composer and selected target. | Establish the true first-use/product-entry baseline. | Include changed target and unsupported capability state. |
| L3 | Existing conversation at top, middle, and near composer. | Reading hierarchy, header, response actions, scrolling, and keyboard avoidance. | Include long text/code. |
| L4 | Generation in progress with Stop available. | Stable streaming, activity semantics, and control placement. | Capture screen at start and after meaningful output. |
| L5 | Stream disconnected/reconnecting, then recovered. | Confirm recovery is comprehensible rather than hidden. | Must use actual tested state, not a mock. |
| L6 | Pending tool approval or user question, once protocol-compatible. | Design typed human intervention. | Capture before and after decision acknowledgement. |
| L7 | Attachment staged/uploading/success/failure, once bound to send. | Design file lifecycle and source disclosure. | Include cancel/retry/removal. |
| L8 | Artifact/source/run-step result, once supported. | Determine whether inline, sheet, or full-screen is appropriate. | Preserve return-to-chat route. |
| L9 | Profile/account switch and authenticated-offline cache. | Validate self-hosted/account identity, read-only state, freshness. | Verify content isolation with test accounts. |
| L10 | iPad regular-width library + chat + optional inspector. | Define adaptive behavior without assuming a desktop copy. | Include keyboard/pointer observation. |

### C. Functional and accessibility evidence required before choosing a visual direction

| Area | Exact test | Pass condition for direction work |
|---|---|---|
| Touch | New Chat, library row, Send/Stop, model/capability sheet, back/dismiss. | Each primary control works with a direct touch/click; no drag-with-click workaround. |
| Scroll | Long library, long conversation, expanded tool/artifact. | Natural one-finger scroll and stable position after state update. |
| Keyboard | Composer typing, keyboard dismissal, send, focus after picker/action sheet. | No obscured composer or lost input; logical focus return. |
| VoiceOver | New Chat, active target, streaming, Stop, pending decision, source/tool expansion. | Concise meaningful labels and state boundaries; no token flood. |
| Dynamic Type | Largest accessibility sizes on library, chat, composer, target sheet, approval. | No clipped essential labels; controls stay reachable. |
| Motion/transparency | Streaming/reconnecting and chrome with Reduce Motion/Transparency enabled. | Status remains clear; content readable without effect. |
| Recovery | Background/relaunch during normal run and paused action. | Correct resumed/reconciled state without duplicated output or lost decision. |
| Capability gating | Unsupported generation, project/MCP/speech/file route, and disabled model spec. | Plain-language reason before user commits work. |

### D. Reference package required for the visual exploration session

Before generating the required three visual directions, assemble this compact package:

```text
1. Accepted source captures: C1–C4 and L1–L10 as available.
2. A one-page evidence index: product, state, capture context, filename, usable lesson.
3. Confirmed deployment capability snapshot for the demo account.
4. A prioritized release slice: which states must be real in the next build.
5. Current app screenshots in light and dark, iPhone and iPad where relevant.
6. Accessibility findings that constrain density, motion, and control treatment.
```

If a reference product cannot be captured, record it as unavailable and remove it from the visual-evidence claim. We may still use its official documentation for product mechanics, but not to replicate its visual language.

## How the three visual directions will differ

This section constrains the forthcoming exploration without creating the options early. Each direction must honor the same functional taxonomy above, but it must make a distinct navigation/information-hierarchy bet rather than merely change tint, blur, or corner radius.

| Direction axis | Direction 1 | Direction 2 | Direction 3 |
|---|---|---|---|
| Primary navigation bet | Conversation-first with a compact Library sheet. | Library/workspace-first with strong project and retrieval structure. | Work-mode-first with an explicit quick-chat vs focused-work transition. |
| Composer emphasis | Minimal by default; context appears as a compact envelope. | Persistent context rail/chips tied to project/source. | A deliberate pre-send scope panel for complex tasks, collapsing for quick prompts. |
| Long-running work | Activity remains inline and expands only when tapped. | Activity has a dedicated inspector/timeline relationship. | Work becomes a durable job card with a return-to-work destination. |
| Artifact handoff | Full-screen destination from message. | iPad inspector / iPhone route with library integration. | Artifact is a first-class work object in a contextual workspace. |
| Best test | Fast recurring conversations. | Users with many threads/projects/files. | Agentic/research-heavy self-hosted deployments. |

Each option must show: iPhone library, empty New Chat, generating chat, target/capability selection, pending approval/tool interaction, artifact/research result, iPad adaptation, dark/light intent, and iOS 17 material fallback. No option may depict a feature as available when the confirmed deployment or release slice cannot support it.

## Decision criteria for selecting a direction

Score each direction against the same priorities after reviewing its images and, later, a SwiftUI prototype:

| Criterion | Question | Weight |
|---|---|---:|
| Fast start | Can a returning user ask a simple question without configuration friction? | 20% |
| Execution clarity | Can a user identify target, scope, privacy, and enabled tools before sending? | 18% |
| Recovery | Does interruption leave a clear, durable return path? | 16% |
| Reading quality | Are response, code, sources and tools readable without visual noise? | 14% |
| Scalable context | Does it make projects/files/artifacts useful without burdening simple chat? | 12% |
| Native fit | Does the structure work naturally on iPhone and adapt honestly to iPad? | 10% |
| Accessibility | Does it preserve touch, Dynamic Type, VoiceOver, contrast and reduced-motion clarity? | 7% |
| Implementation honesty | Can the next product slice make the presented states real with the known protocol/repository work? | 3% |

High visual novelty does not offset a weak recovery story, hidden execution contract, or capability fiction.

## Decision log rules

When a direction is selected, add a dated decision entry that records:

1. the user outcome it improves;
2. the screenshot/product evidence and source contract it relies on;
3. the rejected alternatives and why;
4. iPhone, iPad, iOS 17, and iOS 26 behavior;
5. accessibility and recovery commitments;
6. the smallest implementation slice that can prove the decision honestly.

This turns future polish work into deliberate product evolution rather than a series of local visual edits.
