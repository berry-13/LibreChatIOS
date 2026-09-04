# Claude AI chat experience — evidence-constrained UX and accessibility audit

**Run date:** 2026-08-18  
**Requested surfaces:** Claude for iPhone/mobile, with web/desktop where needed  
**Audit mode:** Combined UX + accessibility  
**Status:** **Capture blocked — this is not a visual product audit.**

## Executive summary

This run could not connect to an in-app, Chrome, or URL-selected browser surface. Therefore no Claude screen was opened, no signed-in or signed-out state was observed, and **no screenshots were accepted**. `Assets/Claude/` is intentionally empty. The product-design audit protocol prohibits treating help-center pages, web search, remembered UI, or old images as live-product audit evidence.

The sections headed **Official-source context** are current, externally researched product facts, not observations of the live UI. The sections headed **Implication for LibreChat iOS** are design recommendations inferred from that context and from the scope requested; they are not findings about Claude's visual implementation.

To complete the intended screenshot-led audit, re-run with a browser that can open `https://claude.ai/` and, for mobile evidence, an accessible iPhone/Claude iOS session. Capture signed-out onboarding and a safe signed-in test account; do not use a real user's private chat history or connected data.

## Scope and evidence log

| # | Requested step / surface | Direct evidence this run | Health | What is known only from official-source research |
|---|---|---|---|---|
| 1 | Onboarding / sign-in | No browser surface available | Blocked | Not assessed |
| 2 | Recents, navigation, and chat search | No browser surface available | Blocked | Claude documents natural-language past-chat search with plan/rollout and project boundaries [1]. |
| 3 | New chat and empty composer | No browser surface available | Blocked | Not assessed |
| 4 | Model and response-style selection | No browser surface available | Blocked | Styles are selected from the chat's “Search and tools” menu; the documented presets are Normal, Concise, Formal, and Explanatory [2]. |
| 5 | Attachments and voice/dictation | No mobile surface available | Blocked | iOS/Android dictation is started with a microphone at the right side of a new-chat input; recorded audio is deleted after transcription [3]. |
| 6 | Streaming, stop, retry, and error recovery | No browser surface available | Blocked | Styles apply to message edits and retries [2], but their controls and feedback were not seen. |
| 7 | Projects | No browser surface available | Blocked | Projects provide scoped instructions/context and are documented as paid-plan functionality [1]. |
| 8 | Artifacts | No browser/mobile surface available | Blocked | Artifact discovery is documented for web, iOS, Android, and desktop, including a mobile “Get inspired” entry [4]. |
| 9 | Tools, connectors, web/advanced research | No browser surface available | Blocked | Web Search is enabled from the chat input's slider menu [5]; Research and integrations provide cited multi-source work [6]. |
| 10 | Citations | No browser surface available | Blocked | Anthropic says web-search responses include citations/source links [5]. Citation interaction, labeling, and mobile reflow were not seen. |
| 11 | Settings, account, billing | No browser/mobile surface available | Blocked | iOS billing is reached through the initials menu in the upper-right, then Billing [7]. |
| 12 | Empty, loading, permission, and error states | No browser surface available | Blocked | Not assessed |

### Accepted screenshots

None. This is deliberate: a screenshot folder with fabricated, stale, or indirect images would make the audit look evidenced when it is not.

## Official-source context (not direct audit evidence)

### Conversation and personalization model

- Claude separates account-wide **profile preferences**, **project instructions**, and response **styles**. That separation is a useful product-information architecture: global defaults should not silently become project rules, and tone should not be confused with task context [1].
- Chat-history retrieval is described as a natural-language capability, bounded to all non-project chats or a single project. It is rolling out by plan; disabling it is in Profile preferences, and deleting a chat is the only documented way to exclude one individual chat [1].
- The style menu is co-located with search/tools rather than exposed as a permanent composer control. This may save composer space, but it makes a consequential response setting less discoverable; this is a **research-led hypothesis**, not a visually confirmed criticism [2].

### Mobile entry and input

- Dictation is a clear mobile pattern: begin a new chat, tap the microphone on the input's right side, choose a language on first use, speak, then send; cancel uses an X [3]. Claude’s documentation says the dictated prompt appears as text and the reply remains text, so this is dictation rather than a full duplex voice conversation [3].
- iOS system surfaces can start a chat, dictation, or photo analysis via widget, Control Center/Lock Screen, Share menu, Siri, Spotlight, and Shortcuts [8]. This reduces friction, but it increases the need for a crisp hand-off screen that makes the active account, selected model, attachment, and usage impact unmistakable.

### Creation, research, and connected data

- Artifacts are framed as a dedicated creation/view space. On mobile, Anthropic documents the Artifacts sidebar area and a “Get inspired” banner; users can open an artifact into a new Claude conversation to customize it [4].
- Research can combine web, workspace, and connected-app data. Anthropic says it indicates searching and returns source links/citations; advanced research is described as taking from minutes to up to 45 minutes [5][6].
- The connector directory is available on web/desktop; remote connectors are documented as paid-plan access, and local desktop extensions as desktop-app access [9]. Entitlement, data scope, and availability should therefore be explained before a user begins a task, not only after a tap fails.

## Transferable patterns for a native LibreChat app

These are recommendations, not assertions that Claude implements them well.

1. **Keep personalization scopes explicit.** Mirror the three-layer idea with separate, plainly named controls: account defaults, workspace/project instructions, and per-chat response style. Show a compact active-scope indicator in the composer so the user can see which rules will apply.
2. **Make capability state visible at the composer.** Group web search, tools, connectors, file creation, and model selection behind a single low-clutter control only if its current state is summarized in the closed control (for example, “Web on · 2 tools”). Do not leave paid, unavailable, or admin-disabled capability states to an after-tap surprise.
3. **Treat long-running research as a job, not typing.** Expose stages, elapsed time, cancel/continue behavior, sources found, and a recoverable error state. Keep a completed report associated with its cited source list and the exact enabled tools.
4. **Use a first-class citation affordance.** A citation tap should open a native, accessible source sheet showing title, publisher/domain, URL, relevant excerpt or context, fetch time, and an external-open action. It needs meaningful VoiceOver labels, not just a bare number.
5. **Design the mobile composer as a state machine.** Empty, typing, attachment-picked, dictating, sending, streaming, stopped, retryable error, and quota/permission blocks need distinguishable visuals, announcements, and escape paths. Avoid moving the Send/Stop target unpredictably.
6. **Preserve provenance when turning chat into an artifact/file.** An artifact should identify its source conversation, version, attachments, model/tools used, and sharing scope. Mobile needs a reliable full-screen presentation—not a cramped side panel copied from desktop.
7. **Offer system entry points deliberately.** Share extension, Action Button/Shortcut, camera, and dictation flows should each land in a confirmation-ready draft rather than silently submitting. Include the selected model, data destination, and tool state before the first send.

## UX risks to validate in a future live audit

These are a targeted test list, **not confirmed defects**.

- **Discoverability versus composer density:** Can a first-time iPhone user find model, style, web/tools, files, and dictation without an overcrowded input row?
- **Scope leakage:** When a user starts a project chat, does the UI make project instructions, knowledge, and connected sources obvious enough to avoid accidental use of the wrong context?
- **Recents and search recovery:** Can users distinguish local navigation search from Claude searching/referencing past chats? Is the privacy toggle understandable at the moment it matters?
- **Long-running work:** Are search/research stages, cancellations, retries, rate limits, and offline errors legible and recoverable without losing prompt text or attachments?
- **Artifact continuity:** Does moving between chat, artifact, and shared artifact preserve wayfinding and a clear “back to conversation” route on narrow screens?
- **Entitlement and authorization:** Does the first connector/research attempt explain plan, organization policy, and data access before login/consent?

## Accessibility risks and verification plan

No accessibility claim below is a compliance finding; screenshots and implementation-level testing are both absent.

| Area | Risk to test | Native LibreChat requirement |
|---|---|---|
| Focus and keyboard | Overflow composer menus, citation popovers, and artifact viewers may lose focus or trap it. | Logical focus return; full hardware-keyboard traversal; visible focus; Escape/Back dismisses the topmost transient UI. |
| VoiceOver semantics | Icon-only controls for mic, stop, tools, citations, attachments, and retry can be ambiguous. | Specific labels plus state/value (for example “Web search, on” and “Stop generating”); announce streaming start/end, research phase, attachment added, and failures. |
| Target size and reach | A dense right-side composer cluster risks targets below a comfortable mobile size. | Minimum 44×44 pt hit targets, generous spacing, and no essential control reachable only by a precision gesture. |
| Dynamic text and reflow | Source cards, code, long citation URLs, models, and artifact controls can clip at large Dynamic Type. | Test largest accessibility sizes, landscape, 200% web-equivalent zoom where applicable, and long localized labels without truncating actions. |
| Colour and non-text cues | Research/searching, quota, connector permission, and citation state can be communicated by color or animation alone. | Text/status icon redundancy and tested contrast; Respect Reduce Motion and provide non-animated progress. |
| Voice / privacy | Microphone flows require understandable permission and cancellation feedback; transcribed data may surprise users. | Explain microphone use before OS permission, show active listening unmistakably, offer cancel/discard, and state retention/data destination in plain language. |
| Errors | Failed uploads, connection/auth failures, and interrupted streams often leave users stranded. | Preserve the draft; name the failure in text; offer retry/alternative action; keep errors discoverable to VoiceOver. |

## Recommended live-capture script for the rerun

Capture each stable screen at iPhone width, inspect the saved image before acceptance, and use a separate test account with no private connectors.

1. Signed-out launch and sign-up/sign-in choice — **not captured**.
2. Signed-in empty home/new-chat state; recents drawer; navigation and chat search — **not captured**.
3. Composer empty, typed, attachment chooser, camera/photo, and dictation states — **not captured**.
4. Model picker, style picker, tools/search menu; enabled and unavailable/upgrade states — **not captured**.
5. A normal streamed answer: generating, Stop, completed, retry/edit, and a forced network/server failure if safely reproducible — **not captured**.
6. A web-search/research run: opt-in, progress, citations, source-sheet behavior, cancel, and completion — **not captured**.
7. Create/open/manage a Project, add instructions/files, then show how a project chat differs — **not captured**.
8. Produce and view an Artifact on mobile; inspect full-screen navigation, share/customize, and return-to-chat — **not captured**.
9. Connector directory/settings and the first authorization/plan/admin-disabled state — **not captured**.
10. Account/settings: profile preference, chat-search privacy, appearance/type, billing, sign-out/deletion confirmation — **not captured**.
11. Repeat the above with VoiceOver and largest Dynamic Type; run a hardware-keyboard pass on web/desktop — **not captured**.

## Evidence limits

- Browser selection and in-app browser startup both reported no available browser during this run. No workaround surface was used because the audit workflow requires a valid captured product state.
- No mobile simulator/device, Claude app, authentication state, or account entitlement was available for inspection.
- Product availability varies by plan, organization policy, country, release wave, platform, and app version. Official source descriptions should not be read as proof that the same controls appear for every account.
- This report does not evaluate visual hierarchy, contrast, focus behavior, target sizing, semantic structure, streaming motion, empty/loading/error states, or interaction success. Those require the capture script above plus assistive-technology testing.

## Official sources

1. [Understanding Claude’s Personalization Features — Anthropic Help Center](https://support.anthropic.com/en/articles/10185728-understanding-claude-s-personalization-features)
2. [Configuring and Using Styles — Anthropic Help Center](https://support.anthropic.com/en/articles/10181068-configuring-and-using-styles)
3. [Using dictation on Claude Mobile — Anthropic Help Center](https://support.anthropic.com/en/articles/10065434-using-dictation-on-claude-mobile)
4. [Discovering, publishing, customizing, and sharing artifacts — Anthropic Help Center](https://support.anthropic.com/en/articles/9547008-publishing-remixing-and-sharing-artifacts)
5. [Enabling and Using Web Search — Anthropic Help Center](https://support.anthropic.com/en/articles/10684626-enabling-and-using-web-search)
6. [Claude can now connect to your world — Anthropic](https://www.anthropic.com/news/integrations)
7. [How do I cancel my paid Claude subscription? — Anthropic Help Center](https://support.anthropic.com/en/articles/8325617-how-do-i-cancel-my-paid-claude-subscription)
8. [Using Claude App Intents, Shortcuts, and Widgets on iOS — Anthropic Help Center](https://support.anthropic.com/en/articles/10263469-using-claude-app-intents-shortcuts-and-widgets-on-ios)
9. [Discover tools that work with Claude — Anthropic](https://www.anthropic.com/news/connectors-directory)
