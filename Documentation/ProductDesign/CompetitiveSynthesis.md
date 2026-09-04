# Competitive synthesis and product principles

## Evidence boundary

The competitive research covers ChatGPT, Claude, Gemini, Perplexity, Microsoft Copilot, Poe, Grok, and DeepSeek. The first pass was official-source research only. On 2026-08-19, a controllable Safari surface produced eighteen accepted, inspected frames from publisher-verified Apple listings for ChatGPT, Claude, Gemini, Perplexity, Poe, and Grok. Those frames now ground bounded visible-hierarchy comparisons, but they still do not prove authenticated navigation, animation, target size, focus order, accessibility, or iPad behavior.

The original capture boundary remains documented in the [2026-08-18 audit](CompetitiveVisualAudit-2026-08-18.md). The new accepted evidence and decisions are in the [screenshot-led competitive audit (2026-08-19)](CompetitiveVisualAudit-2026-08-19.md). Microsoft Copilot remains excluded from visual claims because its consumer App Store page returned a current error in both attempted storefronts.

The clearest new visual decision is structural rather than stylistic: the truthful execution envelope should itself be the target-review control. Across the accepted frames, target or mode identity is visible and directly addressable. LibreChat should not show that state in one element and hide its action behind a separate unlabeled chevron.

The app should not become a visual collage of competitors. The value of the scan is to identify repeated user problems and the strongest control loops.

## What the market has converged on

### 1. The composer is a capability launcher

Modern assistant composers do more than accept text. They bind a prompt to a model/persona, files, source scope, search/research mode, tools, voice/camera, privacy state, and sometimes an output destination.

The failure mode is a toolbar full of unlabeled icons and hidden constraints. Our composer should use progressive disclosure:

- the text field and Send/Stop remain primary;
- active model/persona and active capability scope remain visible;
- one clearly labeled capability sheet contains attachment, source, tool, mode, and privacy choices;
- any selected capability becomes a removable, accessible chip with a plain-language state;
- unsupported choices are explained before the user writes or uploads work.

### 2. Long-running work is a durable job, not a spinner

Deep research and agentic work increasingly expose plan, selected sources, progress, interim findings, interruption/refinement, completion notification, citations, and a saved report. This maps directly to LibreChat generation v2: a run has identity, replay, status, pending actions, run steps, steers, and reconciliation.

The native product should make this protocol legible without exposing implementation noise:

```text
Preparing → Working → Needs you → Reconnecting → Finalizing → Complete
```

Each phase should answer: what is happening, what can the user do, what will survive if they leave, and how to return.

### 3. Durable context belongs to workspaces

Projects/spaces/notebooks combine chats, instructions, files, sources, artifacts, and sometimes connectors. LibreChat already has Projects, presets/prompts, files, agents, memories, and resource permissions. Treating these as separate settings screens would miss their product meaning.

A project in the native app should be a context boundary:

- conversations and generated artifacts;
- pinned/project files and sources;
- project instructions or selected agent;
- applicable memories and connectors;
- project-scoped search;
- explicit sharing/access state.

### 4. Rich output escapes the message bubble

Artifacts, Canvas, Pages, generated files, code execution, and research reports make an answer reusable. On iPhone, a desktop split pane is usually the wrong metaphor. Use a full-screen adaptive Artifact Workspace keyed by conversation, message, and server artifact index that preserves the originating message and return position. On iPad, use an inspector or supplementary column when space and task justify it. Native preview remains Markdown/plain text with provenance; HTML/SVG/Mermaid/React/unknown content stays inert source-only until a separately reviewed sandbox exists.

### 5. Trust comes from provenance and control

The strongest products expose where information came from, what tools/connectors can see, what model/persona is active, whether a conversation persists, and what a long-running job is doing. LibreChat’s multi-provider and self-hosted nature makes this more important.

Every send should have a comprehensible execution envelope:

```text
Model/persona + sources/files + tools/connectors + privacy/retention scope
```

This is not a technical request inspector. It is a compact human-readable contract.

### 6. Model choice is meaningful only when capability differences are legible

Provider lists and model names are not a product. Selection should prioritize intent, recently used targets, organization/favorites, modality, speed/cost/context, and available tools. The exact endpoint/model/spec/agent routing remains inspectable in a detail sheet.

### 7. Voice and camera are sessions

Voice is not a microphone button glued onto text chat. A robust voice/vision session has permission state, listening/speaking state, mute, camera/screen state, live transcript, interruption, reconnect, and “continue in text.” It deserves a recoverable session model and a dedicated surface.

## Where the native LibreChat app can be better

### A calm default with increasing depth

Most conversations should feel like a simple native chat. Complexity appears only when relevant. A first message does not need to show every server capability; a tool-heavy run should expose its steps and pending decisions.

### A single activity language

Tool calls, MCP operations, uploads, research steps, pending approvals, reconnection, and finalization should share one semantic activity system. Users learn one vocabulary instead of decoding a different card for every backend event.

### Recovery as visible product quality

Self-hosted servers and mobile networks fail. The app should make recovery a strength:

- drafts and staged uploads survive;
- partial responses remain visible;
- live jobs become “continuing on server” when the app backgrounds;
- foreground/relaunch reconciles without duplicated text;
- pending approvals return as actionable states;
- failed actions say what was preserved and what retry will do;
- server/profile switching checkpoints and detaches cleanly.

### Self-hosting without infrastructure anxiety

Server identity should remain visible but quiet. A server/account switcher can show trust, connectivity, capability warnings, and cache freshness without turning the chat screen into an admin console.

### Native ergonomics instead of a desktop sidebar shrink

On iPhone:

- chat is the primary canvas;
- recents/search/projects live in a fast navigation surface;
- New Chat is always reachable;
- model/persona and execution scope are visible near composition;
- details, tools, and artifacts use sheets or destinations;
- swipe actions and context menus handle secondary conversation commands.

On iPad:

- `NavigationSplitView` can keep recents/projects beside chat;
- a supplementary inspector is reserved for artifact/context/activity detail;
- keyboard commands and pointer affordances are first-class.

## Product principles

1. **Conversation first, capability on demand.**
2. **Never hide the effective model, scope, or privacy contract.**
3. **A run may outlive the screen; design it accordingly.**
4. **Unknown capability is discovered, not guessed.**
5. **Server truth wins; local work is preserved.**
6. **Rich results become durable objects with provenance.**
7. **Human intervention is a primary state, not an error.**
8. **Every unavailable action explains why and offers the closest valid path.**
9. **Streaming should feel alive without destabilizing reading or accessibility.**
10. **Self-hosted flexibility must not weaken credential, tenant, or TLS isolation.**
11. **Native controls inherit platform behavior; custom visuals earn their complexity.**
12. **Polish includes interruption, failure, empty state, loading, and return—not only the happy path.**

## Initial information architecture hypothesis

This is a hypothesis to validate through visual directions, not an implementation commitment.

```text
App
├─ Chat workspace
│  ├─ conversation content
│  ├─ activity / pending interaction
│  ├─ artifact destination
│  └─ capability-aware composer
├─ Library
│  ├─ recents
│  ├─ search
│  ├─ projects
│  ├─ artifacts/files
│  └─ shared or saved items
├─ Create / choose
│  ├─ model or model spec
│  ├─ agent or assistant
│  ├─ preset / prompt / skill
│  └─ execution scope
└─ Account and server
   ├─ server/account switcher
   ├─ connectivity and compatibility
   ├─ authentication and 2FA
   ├─ privacy, memory, and data controls
   └─ accessibility and appearance
```

## Visual exploration constraints

The next visual phase must produce exactly three genuinely different directions. Each must show at least:

- iPhone conversation list/library;
- empty New Chat;
- populated chat during generation;
- capability/model selection;
- one tool or pending-approval state;
- one artifact/research result state;
- iPad adaptation;
- light/dark and iOS 17 fallback intent.

The options should differ in navigation and information hierarchy, not just color or corner radius. No SwiftUI shell redesign begins until one direction or a deliberate hybrid is selected.
