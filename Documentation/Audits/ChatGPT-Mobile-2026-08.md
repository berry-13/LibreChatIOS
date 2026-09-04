# ChatGPT mobile (iPhone) — full-feature audit vs LibreChatIOS

**Audited version:** 1.2026.223 (current App Store listing, US, 2026-08-22)
**Evidence classes used:**

1. **Listing screenshots (analyzed)** — six publisher iPhone frames at full 1242×2688 resolution, saved to [`Assets/ChatGPT/`](Assets/ChatGPT/) and inspected with image analysis. They show the chat screen: sidebar hamburger top-left, **model picker pill top-center** (dropdown), composer at bottom with +/attachments and voice — consistent with our current top-bar architecture.
2. **Official release notes (complete 2022→Aug 2026)** and Help Center research — authoritative feature inventory, including the Aug 2026 state.
3. **Live app inspection — blocked.** The installed `ChatGPT Classic.app` (com.openai.chat 1.2026.160) is the **native Mac build, not mobile**, and shell screen capture is Screen-Recording-permission-blocked. The user's paired iPhone 17 Pro is currently unreachable. Live mobile capture remains pending; treat pixel-level layout claims below as listing/notes-sourced, not interaction-verified.

---

## 1. ChatGPT mobile feature inventory (Aug 2026)

### Chat shell & navigation
| Feature | Notes |
|---|---|
| Sidebar (hamburger, top-left) | Simplified Mar 2026: horizontal experience bar (**Images, Codex, Pulse, Apps**) above chats & projects |
| Search | Sidebar entry; searches chats, projects, images, documents with **content-type filters** (Jul 2026) |
| Pinned chats + projects | Synced iOS↔desktop (Aug 20); one **Pinned** section |
| Recents list | Combined or grouped-by-project |
| Table of contents | Conversations with >5 responses (web, watch for mobile) |
| Temporary chat | Toggle from model-pill popup; **reversible** — convert temp↔regular (2026) |

### Model / mode selection
| Feature | Notes |
|---|---|
| **Model picker top-center of conversation** | Verified in listing screenshots — same placement as our pill |
| Modes | Instant / Medium / High / Extra High (Pro) / Pro Standard / Pro Extended; simplified Jun 10, 2026 |
| "How much thought" slider | GPT-5.6 era |
| Think button | Free/Go tiers |
| Auto-switch Instant→Medium | Setting toggle |
| **Long-press send → one-off model choice** | iOS, paid tiers |
| Plan-gated entries with reasons | Disabled-with-reason pattern |

### Composer & input
| Feature | Notes |
|---|---|
| Text + attachments + dictation together | 20 files/message |
| Autocorrect before send | Applies fixes at send time |
| Large paste → attachment | >10k chars becomes file with "Show in text field" |
| Edit sent message with attachments | iOS |
| Immediate image previews | Post-send |
| Dictation | Auto-retry, new STT model Jun 2026, coexists with text/attachments |

### Answer surfaces
| Feature | Notes |
|---|---|
| Interactive charts | Bar/line/pie/scatter (Jun 2026) |
| Interactive code blocks | Write/edit/preview diagrams & mini-apps, split screen |
| Visual answers | Highlights people/places/products → side panel with facts |
| Inline web images | In answers |
| Pronunciation guidance | Text + audio, 60+ languages |
| Interactive quizzes & study mode | Aug 2026 |
| Learning modules | Math/science 70+ topics |
| Fast answers mode | Apr 2026 |
| Full-screen writing blocks | Long text surfaces |
| Sources / memory attribution | Sources icon below response → saved memories, past chats, custom instructions; edit/delete/mark-irrelevant |

### Projects
| Feature | Notes |
|---|---|
| Create project before chat | From composer |
| Project memory | Three-dot → Project settings; project-only memory on/off |
| Shared projects | Colors, icons, sources |
| Deep research in projects | |
| Sources | From apps, chats, ad-hoc text |

### Files & library
| Feature | Notes |
|---|---|
| File library | Recent files in composer, Library tab, storage management (500MB–100GB by plan) |
| Google Drive | Web-only (watch for mobile) |

### Voice
| Feature | Notes |
|---|---|
| GPT-Live-1 | Listen+speak simultaneously; **spoken response WITH streamed text in chat**; widgets/maps/weather visuals |
| Text + images in same voice convo | Uses web search + memory |
| Voice in Projects; file uploads in voice | Aug 7 |
| Background conversation safeguards | Settings → Voice |
| CarPlay | iOS 26.4+ |
| Advanced Voice entry | Soundwave icon in composer |

### Agent / work
| Feature | Notes |
|---|---|
| ChatGPT Work agent on mobile | Longer tasks |
| Scheduled Tasks page | Sidebar; pause/resume/edit/delete |
| Deep research | Focus websites, editable plan, fullscreen report, PDF export, citations/sources/activity history |
| Codex remote from phone | QR pairing, approve actions remotely |
| Reservations / shopping / Instant Checkout | Agentic commerce |

### Hubs (sidebar tabs)
| Feature | Notes |
|---|---|
| Health tab | iOS, Jul 2026 |
| Finances page | 2026 |
| Images (Sora 2 app separate; ChatGPT Images 2.0) | My images tab |
| Location sharing | Precise-location toggle |

### Settings & account
| Feature | Notes |
|---|---|
| Personalization | Personality presets + sliders (warmth, enthusiasm, formatting, emoji); custom instructions 5000 chars; applies immediately |
| Memory | Reference chat history; editable/deletable memory summary |
| Active sessions; Advanced Account Security; Lockdown Mode | Jun 2026 |
| Accent colors | Personalization → Color Scheme |
| App permission controls | "Always ask / ask before changes / only important" |
| Data controls, ads on Free/Go | |

### OS integration
| Feature | Notes |
|---|---|
| Home-screen widget | |
| Shortcuts (temporary chat, actions) | |
| Safari default search engine | |
| No-signup instant use; Sign in with Apple | |

---

## 2. LibreChatIOS parity matrix

Legend: ✅ implemented · 🟡 partial · ❌ absent · **n/a** = OpenAI-specific, no LibreChat equivalent (do not copy)

| ChatGPT mobile feature | LibreChatIOS | Mapping note |
|---|:---:|---|
| Model picker top-center pill | ✅ | 2-page anchored dropdown; placement matches ChatGPT |
| Provider→models 2-page dropdown | ✅ | ChatGPT uses flat mode list; ours maps to LibreChat's provider structure |
| Sidebar hamburger + recents (date-grouped) | ✅ | Matches |
| Pinned section (chats + projects) | ✅ | Pin implemented; pinned projects not shown in one section |
| Search (chats + messages) | ✅ | No content-type filters |
| Temporary chat toggle (silent, clock) | ✅ | Reversible temp↔regular ❌ (worth adding — server supports conversation update?) |
| Edit sent message (with attachments) | 🟡 | Text-only edit+resubmit; attachments excluded |
| Long-press send → one-off model | ❌ | Could map to per-message model override (LibreChat: no direct equivalent) |
| Dictation | ✅ | STT; no auto-retry loop |
| Files: 20/message, previews, cancel/retry | ✅ | Upload pipeline with holds |
| File library + storage mgmt | 🟡 | Owner Files library exists; no storage quota UI (LibreChat has quotas) |
| Interactive charts/code blocks | 🟡 | Rendered code surfaces exist; not interactive |
| Citations/sources | ✅ | web_search/file_search citations |
| Artifacts/canvas | ✅ | Native workspace |
| Quizzes/study/learning modules | n/a | OpenAI product surface |
| Pronunciation | n/a | |
| Fast answers / thought slider | n/a | Model-side |
| Projects: create-before-chat, memory, shared, colors | 🟡 | Projects CRUD + assignment; no project memory toggle/shared/colors |
| Deep research | 🟡 | web_search tool + activity surface; no editable plan |
| Scheduled tasks page | ❌ | LibreChat has schedules server-side (api/server/routes/schedules.js) — candidate |
| Voice: spoken response + streamed text | ❌ | Manual Read Aloud only; no streaming TTS |
| Voice in projects / file uploads in voice | ❌ | |
| CarPlay / widgets / Shortcuts | ❌ | Candidates for later |
| Agent (Work) / Codex remote | n/a | LibreChat parallel = our Agents + steering/HITL approvals ✅ |
| Reservations/commerce | n/a | |
| Health/Finances hubs | n/a | |
| Images 2.0 / image generation | n/a | LibreChat: provider images via DALL-E tools — not in app |
| Location sharing | n/a | |
| Personalization: personality presets/sliders | n/a | LibreChat: custom instructions → our prompt presets cover part |
| Memory center | ✅ | Native Memory + account preference |
| Active sessions / Lockdown | ❌ | LibreChat has sessions API (api/server/routes/auth.js) — candidate |
| Accent colors | 🟡 | Monochrome by design direction |
| Data controls | 🟡 | Server-side in LibreChat |
| Sign in with Apple / no-signup | n/a | We have provider OAuth + guest mode ✅ |
| Safari default search | n/a | |
| Permission-ask settings | 🟡 | Camera/mic in-context prompts exist |

## 3. Recommended native gaps worth building next (LibreChat-mappable)

1. **Reversible temporary chat** — convert a temporary conversation to saved (server `POST /api/convos/update` exists; temp flag is client+server contract — verify in reference clone before building).
2. **Pinned section unifying chats + projects** in the sidebar.
3. **Search content-type filters** (chats/messages/files) — we already have scoped search UI precedent.
4. **Streaming Read Aloud (voice-with-text)** — extends existing TTS; large effort.
5. **Scheduled tasks page** — server exposes schedules routes; small native read-only surface first.
6. **Active sessions list + remote sign-out** — server sessions API exists.
7. **Edit sent message with attachments** — currently text-only by safety design; needs upload-ownership review.

## 4. Live-capture follow-up (pending)

- Plug the paired iPhone in (it was unreachable) to drive the real app and verify layout claims, or
- Grant Screen Recording to the terminal to inspect the installed Mac build (desktop UI — low value for mobile parity).
