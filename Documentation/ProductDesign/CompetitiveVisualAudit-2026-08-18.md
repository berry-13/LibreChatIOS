# Competitive native AI visual audit

**Capture date:** 2026-08-18  
**Scope:** ChatGPT, Claude, Gemini, Perplexity, Microsoft Copilot, and Le Chat/Vibe on iPhone and iPad  
**Evidence rule:** Direct, attributable, current screenshots of controllable signed-in app surfaces are required for visual claims. Official App Store pages are catalogued below as source research only; their promotional images and descriptions are not accepted evidence of exact layout, spacing, motion, accessibility semantics, or interaction behavior.

## Executive result

No accepted direct native-app capture was possible in this run. The available official pages identify the current apps and advertise capabilities, but they do not expose a controllable signed-in session in the available capture environment. Consequently, all visual and interaction rows are explicitly marked **Unavailable — direct native capture required**.

This is an evidence boundary, not a product judgment. Do not use this report to copy a competitor’s visual treatment. Use the official-source capability notes only to prioritize later hands-on capture and protocol support.

## Capture method and limits

| Field | Result |
|---|---|
| Preferred source | Official Apple App Store product page for each app |
| Surface reached | Public product listing and metadata |
| Platform/viewport | Web App Store listing; no native iPhone/iPad viewport was controllable |
| Authentication | No signed-in competitor account was available; no credentials were entered |
| Accepted screenshots | None |
| Saved reference assets | None; App Store promotional images are not accepted visual evidence under the project evidence standard |
| What can be asserted | Publisher, app identity, listed device compatibility, and explicitly advertised capabilities |
| What cannot be asserted | Current screen hierarchy, control placement, spacing, typography, hit targets, motion, streaming states, tool cards, attachment flow, VoiceOver order, or iPad layout |

## Direct-capture status by product

| Product | Official source | Direct signed-in capture | Accepted visual evidence |
|---|---|---:|---:|
| ChatGPT | [Apple App Store](https://apps.apple.com/us/app/chatgpt/id6448311069) | Unavailable | None |
| Claude | [Apple App Store](https://apps.apple.com/us/app/claude/id6473753684) | Unavailable | None |
| Gemini | [Apple App Store](https://apps.apple.com/us/app/google-gemini/id6477489729) | Unavailable | None |
| Perplexity | [Apple App Store](https://apps.apple.com/us/app/perplexity-ai-search-chat/id1668000334) | Unavailable | None |
| Microsoft Copilot | [Apple App Store](https://apps.apple.com/us/app/microsoft-copilot/id6472538445) | Unavailable | None |
| Le Chat / Vibe | [Apple App Store](https://apps.apple.com/us/app/le-chat-by-mistral-ai/id6740410176) | Unavailable | None |

## Interaction evidence matrix

The matrix is intentionally repetitive: a missing capture must not be turned into a presumed pattern. “Listed” means the capability is named by the official product listing; it does not mean the native interaction was observed.

| Surface to inspect | ChatGPT | Claude | Gemini | Perplexity | Copilot | Le Chat/Vibe |
|---|---|---|---|---|---|---|
| Onboarding / sign-in | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Library / sidebar / history | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Empty New Chat | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Composer and send/stop states | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Model / agent / mode selection | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Streaming response state | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Tool / research progress state | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Attachments / files / camera | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Voice session | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Artifact / report / rich result | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Navigation and back behavior | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| Accessibility behavior | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |
| iPad adaptation | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |

## Official-source capability inventory

These are catalog facts and vendor claims from the linked pages, not observed UI behavior.

### ChatGPT

The listing identifies iPhone and iPad support and names image generation, advanced voice, photo upload, and synchronized history. The listing does not expose the current authenticated library, composer, model picker, streaming treatment, or iPad layout.

### Claude

The listing identifies iPhone and iPad support and names writing, coding, web research with citations, connected Google services, visual/PDF analysis, SVG generation, and voice dictation. Exact placement and behavior of those capabilities are unobserved.

### Gemini

The listing identifies iPhone and iPad support and names Gemini Live, screen/camera sharing, proactive agents, and responses containing images, timelines, and interactive visuals. The listing is not sufficient evidence for how those states are navigated or rendered.

### Perplexity

The listing identifies iPhone and iPad support and names Pro Search, Deep Research, thread follow-ups, Assistant actions, Labs, Voice, Discover, and a Library. No live search/result or source-citation surface was captured.

### Microsoft Copilot

The listing identifies iPhone and iPad support and names chat, voice, file discovery, Researcher/Analyst agents, content creation, Notebooks, and document uploads. The Microsoft 365 Copilot listing is a separate product surface and should not be substituted for the standalone Copilot app without a future capture.

### Le Chat / Vibe

The listing identifies iPhone and iPad support. It records the product transition from Le Chat to Vibe and names long-horizon agentic tasks, connected knowledge/tools, deep research, sourced analysis, spreadsheet analysis, reports, projects, image generation, voice, and OCR. The exact transition UI and current Vibe experience were not captured.

## Required future capture script

When a controllable iOS device or simulator session becomes available, capture each product at the same evidence states and save the exact images under `Documentation/ProductDesign/References/`:

1. Signed-out launch and sign-in boundary.
2. Authenticated library/history with navigation chrome visible.
3. Empty New Chat with keyboard dismissed and active composer.
4. Target/model/agent picker opened.
5. Attachment picker and staged attachment chip.
6. Normal response while streaming and after completion.
7. Research/tool activity and one pending approval or confirmation state, if supported.
8. Rich result/artifact/report route and return path.
9. iPad portrait and regular-width adaptation.
10. Dynamic Type, VoiceOver focus order, Reduce Motion, and Reduce Transparency checks.

For each capture record: product version, OS version, device, viewport, account state, exact action sequence, timestamp, source URL or app identity, and whether the frame is accepted or rejected. Reject frames that are loading, cropped, blank, blocked, promotional-only, or from an unverified product.

## Implications for LibreChat

No competitor visual direction should be selected from this artifact. The existing LibreChat-native decisions remain grounded in server protocol evidence and native platform constraints. A future visual phase should begin only after accepted captures exist, then compare the native LibreChat app against the same state script rather than against App Store marketing images.

