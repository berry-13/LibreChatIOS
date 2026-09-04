# Competitive pattern scan: Gemini, Perplexity, Microsoft Copilot, Poe, Grok, DeepSeek

Audit date: 2026-08-18  
Scope: patterns that can inform a polished native LibreChat iOS experience.

## Evidence and limits

This run could not produce accepted live screenshots: the required in-app Browser was unavailable, and no authenticated external browser was supplied. The assets folder contains the capture-status record, not invented screenshots. Findings below are therefore **official-source research**, not direct UI audits. A follow-up run with browser access should capture each flow and replace or augment these notes with numbered screenshots.

Current-source links are intentionally linked inline so product claims can be rechecked.

## Executive readout

The strongest patterns to borrow are:

1. Make the composer a capability launcher. Perplexity’s simplified input bar puts upload, source scope, modes, and model identity behind a single `+` affordance while keeping the active model visible ([Perplexity changelog](https://www.perplexity.ai/changelog/what-we-shipped---february-6th-2026)).
2. Treat long-running work as a resumable job. Gemini exposes a research plan, editable plan, progress, completion notification, report history, export, and audio/visual follow-ons ([Gemini Deep Research help](https://support.google.com/gemini/answer/15719111?hl=en)). Perplexity’s current Research experience adds clarifying questions, in-progress follow-ups, source progress, key findings, and an editable/shareable report ([Advanced Deep Research](https://www.perplexity.ai/help-center/en/articles/13600190-what-s-new-in-advanced-deep-research)).
3. Promote durable artifacts out of chat. Gemini Canvas and Microsoft Copilot Pages both turn a response into an editable, persistent surface ([Gemini Canvas](https://blog.google/products-and-platforms/products/gemini/gemini-collaboration-features/), [Copilot Pages](https://support.microsoft.com/en-us/microsoft-365-copilot/how-microsoft-365-copilot-pages-works)).
4. Organize context around projects, not only threads. Perplexity Projects combine threads, files, search, custom instructions, sharing, and connectors ([Projects](https://www.perplexity.ai/help-center/en/articles/10352961-what-are-spaces)); Grok’s current product direction adds Projects plus search over generated media ([Grok Imagine Video 1.5](https://x.ai/news/grok-imagine-video-1-5)).
5. Keep modality switching in the same conversation. Grok explicitly combines text, web/X search, reasoning, voice, files, vision, image/video generation, and Canvas ([Grok overview](https://x.ai/grok?lid=en-us)); Gemini Live supports camera and screen sharing on mobile ([Gemini I/O update](https://blog.google/products-and-platforms/products/gemini/gemini-app-updates-io-2025/)).
6. Make model choice legible and comparable. Poe’s bot marketplace makes the bot/provider identity central and supports user-created bots/apps ([Poe FAQs](https://help.poe.com/hc/en-us/articles/19944206309524-Poe-FAQs)); Perplexity Model Council runs multiple frontier models in parallel and synthesizes agreement/disagreement ([Perplexity changelog](https://www.perplexity.ai/changelog/what-we-shipped---february-6th-2026)); Microsoft Researcher supports multiple models and a council option ([Microsoft Model Council](https://support.microsoft.com/en-us/microsoft-365-copilot/use-model-council-with-researcher-in-microsoft-365-copilot)).

## Product-by-product pattern notes

### 1. Gemini

**Evidence:** official help and Google product posts; direct app interaction was not capturable in this run.

- **Navigation/discovery:** feature families are exposed as destinations/actions: Deep Research, Canvas, Gems, connected apps, quizzes, and media creation. For LibreChat, use a compact capability drawer with recognizable task verbs rather than a crowded tab bar.
- **Model/persona switching:** Gems are customized versions of Gemini with reusable instructions and optional files ([Gems help](https://support.google.com/gemini/answer/15236321?hl=en)). Preserve a visible active persona chip in the composer and make “new chat with this persona” one tap.
- **Composer/multimodal:** Deep Research starts from Add Files plus a Sources selector; sources can include Search, Gmail, Drive, uploaded files, and NotebookLM notebooks. This is a good model for a source-scope sheet that separates temporary attachments from persistent project sources.
- **Streaming/research:** Gemini creates a plan before starting research, allows plan edits, then runs for minutes; users can leave and receive a notification when complete. Design implication: persist job state locally/server-side and show “resume report” in history.
- **Artifacts/voice:** Canvas supports editable docs/code, share/export, visualizations, and Audio Overview. Keep artifact actions beside the answer, not buried in an overflow menu.
- **Monetization:** plan limits and higher research limits are surfaced as capability/usage constraints; design a calm limit sheet with remaining quota and a non-blocking upgrade path.
- **Accessibility risks to test live:** icon-only Add Files/Sources/Canvas controls, plan progress announcements, notification wording, focus order between chat and Canvas, and Audio Overview controls. Official docs cannot verify VoiceOver labels, Dynamic Type, reduced motion, or keyboard behavior.

### 2. Perplexity

**Evidence:** official Help Center/changelog; direct interaction blocked.

- **Navigation/discovery:** Projects act as durable knowledge hubs; thread and file search, pinning, sharing, connectors, and custom instructions live together. For LibreChat, support project-scoped history and sources before adding more top-level navigation.
- **Composer:** the streamlined input bar keeps selected model identity visible and moves upload, source management, and modes into `+`. This is the clearest pattern for a native iOS bottom composer.
- **Modes/tools:** Deep Research, Model Council, Create files/apps, and Learn step-by-step share one command surface. A unified mode sheet reduces mode hunting.
- **Streaming/sources:** Advanced Deep Research shows sources read, learning/progress, key findings as they arrive, and follow-up questions during execution. Model the stream as a structured timeline, not only a spinner.
- **Artifacts:** reports stream into an editable file that can be refined and shared. Make “Save as artifact” explicit and reversible.
- **Accessibility risks to test live:** dense source chips, progress updates, mode menu discoverability, side-panel state on narrow screens, and whether follow-up entry remains reachable during research.

### 3. Microsoft Copilot

**Evidence:** Microsoft Support/Learn; direct interaction blocked by sign-in/licensing.

- **Navigation/context:** Copilot’s differentiator is work context: files, email, meetings, chats, SharePoint/OneDrive, and notebooks. LibreChat can borrow a clear “where this answer can look” scope indicator even without enterprise connectors.
- **Researcher:** a named agent handles complex multi-step research and emits source-cited reports ([Researcher](https://learn.microsoft.com/en-us/microsoft-365/copilot/researcher-agent)). Keep fast chat and long-running research visually distinct.
- **Pages/artifacts:** “Edit in Pages” opens a persistent side-by-side canvas from a response; users can continue chatting and update the page ([Pages workflow](https://support.microsoft.com/en-us/microsoft-365-copilot/how-microsoft-365-copilot-pages-works)). On iPhone, use a sheet or split transition with clear return-to-chat affordance.
- **Model choice:** Researcher plus Model Council introduces explicit multi-model comparison; show which model(s) contributed and what was synthesized.
- **Monetization/access:** licenses, admin controls, and feature rollout vary. Every gated feature needs a reason, entitlement, and fallback.
- **Accessibility risks to test live:** side-by-side navigation semantics on compact widths, table/page editing with VoiceOver, source disclosure, and entitlement errors.

### 4. Poe

**Evidence:** official Poe FAQ, Privacy Center, and Apps announcement; direct interaction blocked.

- **Discovery:** Poe makes bots the primary object: browse/search by topic, see creator/provider identity, and set a default bot. LibreChat could make model/persona cards richer with purpose, modality, latency, context, and privacy indicators.
- **Switching:** many third-party models, user-created bots, and apps share one chat surface. Preserve conversation context when switching models, but make the switch boundary explicit.
- **Tools/artifacts:** bots can execute code and interactive canvases; Poe Apps can run visual interfaces alongside chat. This argues for a native “artifact/app result” card that can expand without leaving the thread.
- **Monetization:** points are a cross-model budget; each bot shows approximate point cost and free users receive daily reset points ([Poe FAQs](https://help.poe.com/hc/en-us/articles/19944206309524-Poe-FAQs)). For LibreChat, show per-request cost/estimate only when meaningful and keep balance visible before send.
- **Privacy:** a bot/app privacy shield communicates who may see chats ([Poe Privacy Center](https://poe.com/pages/privacy-center)). Borrow a lightweight data-routing badge for connectors/tools.
- **Accessibility risks to test live:** marketplace card density, provider/bot naming, cost and privacy disclosures, and interactive canvas focus containment.

### 5. Grok

**Evidence:** xAI product/docs pages; direct interaction blocked.

- **Navigation/discovery:** modes are task-oriented—Search, reasoning, voice, Imagine—and projects/library search organize generated media. Use a single mode control with a strong active-state label.
- **Multimodal/voice:** Grok supports low-latency voice, camera/video understanding, files/PDFs, image/video generation, and follow-up iteration in one thread ([Grok overview](https://x.ai/grok?lid=en-us), [Voice Mode](https://x.ai/news/grok-4)). For iOS, keep mic/camera state persistent and obvious, with a preview and one-tap mute/stop.
- **Research/tools:** multi-agent mode runs subproblems in parallel and merges a cited answer; show expandable work units with status, not opaque “thinking.”
- **Artifacts:** Canvas supports long-form editing; Imagine supports iterative generation and project/media search. Add a media shelf tied to the conversation.
- **Monetization:** one weekly usage allowance spans products; SuperGrok increases rate limits and unlocks media/multi-agent features ([pricing](https://x.ai/pricing)). A shared allowance meter is easier to understand than separate hidden caps.
- **Accessibility risks to test live:** voice interruption/recovery, camera privacy affordance, animation/reduced motion, multi-agent status updates, and citation navigation.

### 6. DeepSeek

**Evidence:** official DeepSeek app/API docs; direct app interaction blocked.

- **Navigation/state recovery:** the official app emphasizes cross-platform history sync, a simple free/no-ads/no-in-app-purchases proposition, and a small set of high-value capabilities ([DeepSeek app](https://api-docs.deepseek.com/news/news250115/)). LibreChat should make sync status and offline/retry state explicit.
- **Composer:** Web Search and Deep-Think are first-class modes; file upload and text extraction are core. Keep these as persistent toggles with clear cost/latency expectations.
- **Reasoning/streaming:** Thinking mode exposes reasoning content in the API ([Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)). For a consumer UI, show a concise expandable reasoning summary/status rather than dumping raw chain-of-thought; test policy and privacy boundaries separately.
- **Monetization:** the app source describes free access without ads or in-app purchases. This is a useful low-friction baseline for onboarding and a contrast with quota-heavy competitors.
- **Accessibility risks to test live:** toggle labels, web-search state, long reasoning expansion, file extraction progress, and sync conflict/recovery.

## Cross-product pattern matrix

| Pattern | Gemini | Perplexity | Copilot | Poe | Grok | DeepSeek | LibreChat iOS implication |
|---|---|---|---|---|---|---|---|
| Unified capability composer | Add Files + Sources + modes | `+` menu + visible model | Researcher in compose | Bot picker | mode switch | Search/Think toggles | One bottom bar; capability sheet; active model/persona always visible |
| Durable workspaces | Gems/Canvas/reports | Projects | Notebooks/Pages | bots/apps | Projects/media library | synced history | Project/thread split; artifacts and sources persist |
| Long-running work | plan → research → notify | progress + follow-ups + report | Researcher | bot-dependent | multi-agent | Think/search status | job state, progress timeline, resume after app relaunch |
| Sources/citations | selectable sources | source-first answer | work/web citations | privacy shield/provider | web + X citations | web search | source scope before send; citation drawer with provenance |
| Artifacts | Canvas, Audio Overview | editable reports/files/apps | Pages | interactive apps/canvases | Canvas/Imagine | file extraction | artifact cards with expand, save, share, export |
| Voice/vision | Gemini Live camera/screen | not central in cited sources | not central in cited sources | audio bots | voice + camera | not central in cited sources | voice session surface with interruption/recovery |
| Monetization | plan limits | feature/model limits | license/admin gates | points per bot | shared allowance | free/no IAP | transparent entitlement + graceful fallback |

## Highest-value paths for LibreChat iOS

### P0 — Composer capability sheet

Active model/persona, search/deep research, file/photo/camera, voice, tools/connectors, and artifact destination should be reachable from one bottom-sheet interaction. Keep the selected model and source scope inline in the composer.

### P0 — Resumable research job

Represent research as a job with plan, sources, progress, findings, follow-ups, completion notification, and saved report. Persist it across backgrounding and relaunch; expose “resume” from history.

### P0 — Source and privacy provenance

Before send, show whether the request uses model knowledge, web search, uploaded files, connectors, or a tool. In results, make citations tappable and expose a compact “why this source” view. Add a provider/privacy badge inspired by Poe.

### P1 — Artifact handoff

Every answer that can become a document, code file, table, image, or audio summary gets a visible “Open as artifact” action. Artifact editing should preserve the originating thread and allow return without losing scroll position.

### P1 — Model Council / compare mode

Offer optional parallel responses for high-stakes or exploratory prompts. Show per-model outputs, agreement/disagreement, latency, and synthesis; make the extra cost/time explicit.

### P1 — Project-scoped memory and history

Projects should contain threads, pinned sources, files, custom instructions/personas, and artifacts. Add full-text search and filters for chat, research, files, and artifacts.

### P1 — Voice and camera session recovery

Use a persistent session capsule with mute, camera state, transcript, interruption, reconnect, and “continue in text” actions. Test VoiceOver and reduced-motion behavior before shipping.

### P2 — Entitlement surfaces

Use one usage/limits sheet that explains what is limited, when it resets, which alternative model/tool remains available, and what upgrade changes. Avoid surprise paywalls after the user has composed a long prompt.

## Follow-up capture plan

When browser access is available, capture these numbered steps for each product: (1) home/navigation shell, (2) new chat and composer closed, (3) model/persona or bot switcher, (4) attachment/multimodal menu, (5) streaming response, (6) sources/citations, (7) research mode start/plan, (8) in-progress research, (9) report/artifact/canvas, (10) voice or camera, (11) history/search/project recovery, and (12) monetization/limit state. Inspect every saved image and reject loading, cropped, blocked, or wrong-state captures.

