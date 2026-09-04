# ChatGPT major chat experience — capture-blocked product, UX, and accessibility review

**Prepared:** 2026-08-18  
**Requested scope:** iPhone/mobile first, with web/desktop where required: onboarding; chat navigation/search; new chat; model/mode choice; composer, attachments and voice; streaming/stop/retry; tools/deep research; citations/artifacts; settings/account; and empty, loading, and error states.

## Audit status and evidence boundary

This is **not a completed screenshot-led UI audit**. The required in-app browser was selected first, as required by the Product Design and Browser workflows, but no in-app browser surface was available in this session (`Browser is not available: iab`; available browser surfaces: none). Therefore no signed-in ChatGPT screen, iPhone UI, interaction, accessibility tree, keyboard flow, loading state, or error state could be captured or inspected.

The requested screenshot directory exists at `Assets/ChatGPT/`, but contains **no accepted screenshots**. Creating illustrative or copied screenshots would violate the capture requirement, so none are included. Do not treat the research observations below as direct inspection findings.

### Evidence classes

| Class | What it supports | What was available |
|---|---|---|
| Direct audit evidence | Visible layout, controls, state transitions, targets, contrast, focus, screen-reader semantics | **None** — browser capture blocked |
| Official-source research | Documented features, documented entry points, stated platform availability and limits | Current OpenAI Help Center / release-note pages retrieved 2026-08-18 |
| Transferable product inference | Recommended native-app pattern derived from the documented capability, to validate in the real UI | Marked **Inference** below |

## User goal and accessibility target

A returning or new user should be able to begin the right kind of chat, provide context, understand what the system is doing, verify consequential answers, recover from an interruption or limit, and control privacy—on a compact iPhone screen without hidden critical state.

The accessibility target is a robust native experience for VoiceOver, Dynamic Type, keyboard/Switch Control where applicable, reduced motion, and low-vision users. Screenshots alone would not prove this; here, direct evidence is absent altogether.

## Surface-by-surface evidence ledger

| # | Requested surface | Direct audit status | Current official-source research | Risk / LibreChat implication |
|---:|---|---|---|---|
| 1 | First launch / onboarding | Not captured | No first-launch screen was directly documented in the sources retrieved. | Do not infer onboarding design. For LibreChat, make sign-in, account/data expectations, and a first useful prompt explicit; test interrupted onboarding and credential errors. |
| 2 | Conversation navigation and search | Not captured | Chat history search is documented for web and mobile sidebar; it searches conversation titles and content, but only exact matches are currently supported. Archived chats remain searchable; canvas contents are not searchable. [Source](https://help.openai.com/en/articles/10056348-how-do-i-search-my-chat-history-in-chatgpt) | **Transferable pattern:** search must be a first-class recovery path when a compact recents list omits older chats. **Risk:** exact-match discovery is fragile and an unsearchable artifact creates a mental-model gap. LibreChat should disclose scope, match behavior, and exclusions in the search UI, and consider tokenized/prefix or semantic search only when privacy/performance permits. |
| 3 | New chat | Not captured | Documentation describes starting deep research from the composer tools menu, slash command, or sidebar, implying multiple task-entry routes. [Source](https://help.openai.com/en/articles/10500283-leep-research-faq) | **Inference:** a native New Chat should remain a persistent, reachable action rather than compete with mode selection. Preserve user context deliberately—do not silently carry an incompatible tool/mode into the next chat. |
| 4 | Model / mode selection | Not captured | Release notes say the picker is at the top of the conversation on iOS/Android and directly in the composer on web; available choices and configuration vary by plan. Another current Help Center page documents Instant, Thinking, and Pro, with constraints such as Apps, Memory, Canvas, and image generation not being available with Pro. [Release notes](https://help.openai.com/en/articles/6825453-chatgpt-apps-on-ios-and-android) · [GPT-5.5](https://help.openai.com/en/articles/11909943-gpt-5-3-and-gpt-55-in-chatgpt) | **Transferable pattern:** put mode where users make the decision, and show only meaningful options. **High risk:** per-plan and per-mode capability restrictions can be invisible until after selection. LibreChat should expose a concise “what changes” summary and a disabled-with-reason state before send. |
| 5 | Composer, attachments, and voice | Not captured | File upload support is documented on web and iOS/Android, with type/size/usage limits and an error when a quota is hit. Voice starts from the Voice icon in the message bar; Live accepts text and images in the same chat, while Advanced enables some mobile-only capabilities (video/screen share). [File uploads](https://help.openai.com/en/articles/8555545-uploading-images-and-files-in-chatgpt) · [Voice](https://help.openai.com/en/articles/20001274/) | **Transferable pattern:** one composer can support multimodal work without forcing a mode switch. **Risk:** attachment and voice availability is conditional, so an icon alone is insufficient. LibreChat should preflight unsupported file type/size, show upload progress and cancel/retry, request microphone permission in context, and expose what a selected voice mode can/cannot do. |
| 6 | Streaming, stop, and regenerate | Not captured | The documented Deep Research flow allows users to follow progress and interrupt to refine the focus. Retry is documented as an overflow action under a mobile response. [Deep research](https://help.openai.com/en/articles/10500283-leep-research-faq) · [GPT-5.5](https://help.openai.com/en/articles/11909943-gpt-5-3-and-gpt-55-in-chatgpt) | **Inference:** interruption and retry are core recovery, not secondary decoration. **Risk:** placing retry only in overflow reduces discoverability, and a generic spinner provides poor state explanation. LibreChat should provide a visible Stop during generation, preserve partial output, announce streaming/status changes accessibly, and offer regenerate with clear scope/model information. |
| 7 | Tools and research | Not captured | Deep Research lets the user choose sources (web, uploads, enabled apps), review/edit a proposed plan, follow progress, interrupt/refine, then receive a structured report. [Source](https://help.openai.com/en/articles/10500283-leep-research-faq) | **Strong transferable pattern:** make agentic work inspectable and steerable before/during execution. LibreChat should show source permissions, an editable plan, phase/progress status, cancellation, and a durable completion state. Avoid “working…” without scope, elapsed time, or a safe exit. |
| 8 | Citations and artifacts | Not captured | Deep Research outputs include citations/source links, a sources-used section, activity history, and export formats. Canvas is documented as a separate right-hand editable surface on web/desktop; it is documented as coming soon for mobile and is incompatible with some models. [Deep research](https://help.openai.com/en/articles/10500283-leep-research-faq) · [Canvas](https://help.openai.com/en/articles/9930697-what-is-canvas) | **Transferable pattern:** pair a rich answer with traceable sources and a reusable artifact. **Risk:** artifacts can become a second, unsynchronized content surface, and platform/model availability may surprise mobile users. LibreChat should keep source-to-claim linking easy to inspect, distinguish generated text from external sources, and provide a mobile-safe artifact handoff/open-in-editor state. |
| 9 | Settings and account | Not captured | On mobile, Data Controls are reached via sidebar → profile icon → Data Controls. Users can control model-improvement participation; the setting syncs across devices. Temporary Chats are not saved in history or used for training and are deleted after 30 days. Shared links are documented as available on web and iOS, with Android “coming soon.” [Data Controls](https://help.openai.com/en/articles/7730893-chatgpt-data-controls) · [Shared links](https://help.openai.com/en/articles/7943621-where-do-i-access-my-settings-to-see-my-shared-links) | **Transferable pattern:** contextual privacy controls must reach mobile navigation, not only a web account portal. **Risk:** settings that affect retention/training/shareability are high-consequence but nested. LibreChat should surface conversation-specific privacy state at creation and provide plain-language confirmation, reversal, and disclosure of sync/retention. |
| 10 | Empty, loading, and error states | Not captured | Official research confirms variable plan/usage limits in the model picker, rolling voice limits with notification, and file-cap errors. It does not provide visual layouts or recovery behavior for those states. [GPT-5.5](https://help.openai.com/en/articles/11909943-gpt-5-3-and-gpt-55-in-chatgpt) · [Voice](https://help.openai.com/en/articles/20001274/) · [File uploads](https://help.openai.com/en/articles/8555545-uploading-images-and-files-in-chatgpt) | Do not infer presentation quality. LibreChat needs deterministic empty states (first chat, no search results, no attachments), recoverable transient errors, rate-limit/reset explanation when available, offline handling, and error messages that state what was preserved and what the user can do next. |

## Transferable patterns worth carrying into a native LibreChat app

1. **A compact chat shell needs two different retrieval paths.** Recents optimize speed; search restores older context. Make the search scope and exclusions legible rather than pretending all content is equally retrievable.
2. **Decision controls belong at decision time.** Mode/model choice near the iPhone conversation header and the web composer is an example of platform-sensitive placement. Native LibreChat should keep the current model/mode visible near send, including its effective capabilities.
3. **Multimodal input is a single task, not three destinations.** Text, files, image, and voice can coexist in the same chat. Use the composer as a calm, progressive disclosure point, but give every non-default capability a labeled state and an understandable availability reason.
4. **Agentic work earns trust through inspectability.** Editable research plans, source choice, running progress, interruption, citations, activity history, and export form a coherent control loop. For LibreChat, plan/reasoning should be separate from private chain-of-thought: expose user-actionable plan/status and source provenance, not hidden reasoning.
5. **A response is stronger when it becomes a reusable object.** Citations make claims checkable; artifacts/canvas make extended editing practical. On iPhone, the handoff must not strand users in a cramped split view—use a dedicated, accessible editor or a clear transition.
6. **Privacy is part of the conversation contract.** A setting is not sufficient when users can be unsure whether a chat is retained, used for improvement, shareable, or temporary. Make the state visible at conversation start and in the overflow menu, with an explicit confirmation for irreversible actions.

## Likely UX and accessibility risks to verify in a live follow-up

These are **verification hypotheses**, not findings against the current ChatGPT UI:

- **Information scent on mobile:** sidebar-only search, profile-routed settings, and response-overflow retry can be hard to discover. Verify VoiceOver rotor/heading structure, control labels, logical focus return, and whether the controls remain reachable at large Dynamic Type sizes.
- **Small icon-only actions:** composer add, voice, send/stop, response overflow, citation affordances, and close/back controls are likely dense on iPhone. Verify a minimum 44×44 pt effective hit target, accessible names, state/value announcements, and no dependence on color or motion alone.
- **Streaming clarity:** verify that a screen reader hears a succinct generation status, a clearly named Stop control, and completion without being flooded by every token; test network loss and cancellation with partial content preservation.
- **Mode restrictions:** verify whether an unavailable tool is disabled with an explanation that can be read by VoiceOver, rather than failing after the user has authored a prompt or attached data.
- **Citations and sources:** verify link purpose, source title/domain, focus order, external-navigation warning/return path, and that superscript-like markers do not become ambiguous unlabeled controls.
- **Voice and permission flow:** verify microphone permission denial, captions, mute/unmute state, audio interruption, and reachable exit control. Captions are documented for iOS/Android, but their visual and assistive-technology behavior was not inspected. [Voice Mode FAQ](https://help.openai.com/en/articles/8400625-voice-mode)
- **Artifacts on a small screen:** verify that the text/chat relationship, unsaved edits, version recovery, and “return to chat” path stay clear. Canvas is officially described as desktop/web today, not a mobile capability. [Canvas](https://help.openai.com/en/articles/9930697-what-is-canvas)
- **Empty/error recovery:** test first-use, empty search, no network, attachment rejected/quota hit, exhausted model/voice usage, tool failure, canceled deep research, and malformed citations. Each must describe cause, preserved work, and next action—not merely show a toast.

## Native LibreChat priorities

### P0 — do before feature parity grows

1. Establish a stable composer state machine: idle, attachment-selecting/uploading, ready, streaming, stopped, failed, and retrying. Pair each state with a visible label, VoiceOver announcement policy, and recovery path.
2. Build conversation search with explicit scope, empty/no-result state, indexing/privacy language, and keyboard/VoiceOver navigation. Do not hide old chats merely because recents are virtualized.
3. Make model/mode capability constraints pre-send visible. Persist user choices deliberately and show a plain-language change summary when switching modes.
4. Treat attachments as first-class objects: preview/name/type/size, upload progress, cancel/retry/remove, error reason, and retention disclosure before send.
5. Put temporary/private-chat status in the compose flow and conversation header. Include a concise explanation of history, sync, sharing, and data use that is specific to LibreChat’s backend.

### P1 — trust and research quality

1. For research/tool runs, expose user-controlled source scope, a reviewable plan, phase-oriented progress, stop/refine, and a completed report with grouped sources.
2. Implement citations as semantically labeled buttons/links with source metadata and a safe return path. Make claim-to-source association understandable without relying on superscript position or color.
3. Provide a dedicated artifact/editor route on iPhone, with autosave/version behavior and explicit unsaved-change recovery, instead of squeezing long-form editing beside chat.

### P2 — validation plan before using this as a design benchmark

1. Capture the live signed-in ChatGPT iOS app (or its mobile web fallback only when iOS is unavailable) across every numbered surface above.
2. Capture desktop web only for split-pane artifacts, settings variants, and high-information research results not available on mobile.
3. Run task-based accessibility checks with VoiceOver, Dynamic Type at accessibility sizes, Reduce Motion, Bold Text, external keyboard, and network/permission/limit failures.
4. Repeat with at least Free and paid accounts, because documented mode, tool, and limit availability differs by plan, region, and rollout.

## Evidence limits and next capture checklist

The following remain unknown until a valid interactive browser or device session is available:

- Actual first-launch and sign-in/onboarding copy, hierarchy, consent, and recovery.
- Actual iPhone placement, target size, labels, contrast, and focus order of every control.
- Screen-reader semantics, keyboard behavior, Dynamic Type reflow, captions behavior, and motion behavior.
- Whether the visual experience matches the official documentation at the account/plan/region used for testing.
- Empty/loading/error screens and whether user draft, attachments, and partial output survive interruption.
- Real citation affordances, artifact synchronization, and search result scanability.

When capture is available, save accepted files here in chronological order:

```text
Documentation/Audits/Assets/ChatGPT/
01-first-launch.png
02-mobile-sidebar-search.png
03-new-chat-model-mode.png
04-composer-attachments.png
05-voice-active-captions.png
06-streaming-stop-retry.png
07-deep-research-plan-progress.png
08-citations-artifact.png
09-settings-data-controls.png
10-empty-loading-error.png
```

Each must be opened and visually accepted before any direct claim is added to this report.

## Official research sources retrieved for this report

- [How do I search my chat history in ChatGPT?](https://help.openai.com/en/articles/10056348-how-do-i-search-my-chat-history-in-chatgpt) — updated 2026-08-02 per retrieved page.
- [ChatGPT Release Notes](https://help.openai.com/en/articles/6825453-chatgpt-apps-on-ios-and-android) — retrieved current release timeline, including mobile/web model-picker placement.
- [GPT-5.5 in ChatGPT](https://help.openai.com/en/articles/11909943-gpt-5-3-and-gpt-55-in-chatgpt) — updated 2026-08-15 per retrieved page.
- [File Uploads FAQ](https://help.openai.com/en/articles/8555545-uploading-images-and-files-in-chatgpt) — updated 2026-08-13 per retrieved page.
- [ChatGPT Voice](https://help.openai.com/en/articles/20001274/) — updated 2026-08-15 per retrieved page.
- [Voice Mode FAQ](https://help.openai.com/en/articles/8400625-voice-mode) — retrieved current mobile captions, transcripts, and settings information.
- [Deep research in ChatGPT](https://help.openai.com/en/articles/10500283-leep-research-faq) — updated 2026-08-12 per retrieved page.
- [What is the canvas feature in ChatGPT and how do I use it?](https://help.openai.com/en/articles/9930697-what-is-canvas) — updated 2026-08-16 per retrieved page.
- [Data Controls FAQ](https://help.openai.com/en/articles/7730893-chatgpt-data-controls) — updated 2026-08-14 per retrieved page.
- [Where do I access my settings to see my shared links?](https://help.openai.com/en/articles/7943621-where-do-i-access-my-settings-to-see-my-shared-links) — updated 2026-08-17 per retrieved page.

