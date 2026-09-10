# LibreChat for iOS

A fully native SwiftUI client for self-hosted [LibreChat](https://github.com/danny-avila/LibreChat) servers. It targets iOS 17, compiles under Swift 6 with complete concurrency checking, and progressively adopts the iOS 26 Liquid Glass design language for application chrome.

The product goal is a calm, Apple-platform chat workspace — not a compressed web dashboard — that makes target, scope, provenance, and recovery legible.

## Features

**Accounts & authentication**

- Multiple profiles, including multiple accounts on the same host, with isolated Keychain-backed cookies, cache namespaces, and generation state.
- Password login, TOTP and backup-code 2FA, account registration, email-verification recovery, and serialized token refresh with offline restoration from the last verified session.
- Optional OAuth/OIDC/SAML/social login through `ASWebAuthenticationSession` with a single-use authorization-code + S256 PKCE mobile extension (see [Server compatibility](#server-compatibility)).

**Chat & generation**

- Cache-first conversations and messages: offline browsing, safe partial-page reconciliation, explicit deletion, archive/pin/rename, duplication, forking, and share links.
- Resumable streaming generation (protocol v2) with reconnects, replay deduplication, periodic checkpoints, and foreground/relaunch recovery — plus manual Resume as a fallback.
- Branch-aware message-tree navigation, prompt edit-and-resubmit, response regeneration, steering, follow-up queueing, and human-in-the-loop tool approvals and questions.
- Native Markdown and code rendering, `web_search`/`file_search` citations with a source directory, and expandable agent-activity cards.
- Attachments from Photo Library, camera, and Files — with orientation-normalized metadata-free JPEG encoding, staging, retry/cancel, and upload usage holds.
- Capability-gated dictation and Read Aloud.

**Content libraries**

- Agents: browse/search, creation, metadata editing, version history with revert, duplication, and permission-gated deletion.
- Prompt Library and personal templates, Presets, Skills, Memory, and a read-only MCP Connections screen.
- Files: search, sort, preview, protected download, and single-owner deletion.
- Projects with scoped chats and conversation assignment; full conversation and message search with exact branch navigation.

**Platform**

- Adaptive layout: `NavigationStack` on iPhone, `NavigationSplitView` on iPad.
- Device-auth app lock, accessibility support (VoiceOver, Reduce Motion, Dynamic Type), and privacy-safe observability that never logs credentials, prompts, or message content.

## Architecture

`Packages/LibreChatCore` is the protocol boundary:

| Target | Contents |
| --- | --- |
| `LibreChatDomain` | Stable IDs, models, repository protocols, generation state |
| `LibreChatProtocol` | DTOs, explicit mappers, REST/SSE transports, cookie jar, `AuthSession`, capability detection |
| `LibreChatTestSupport` | Fixtures and transport/storage doubles |
| `DesignKit` | Semantic SwiftUI components; glass is limited to controls and navigation chrome |

The application target owns feature models, the SwiftData cache (with a V1→V2 migration plan), the composition root, and platform integrations. Networking, authentication refresh, cookie handling, SSE framing, generation ordering, retries, and reconciliation live in the package — not in SwiftUI models.

## Requirements

- Xcode 26+ (CI pins Xcode 26.6)
- iOS 17 deployment target; Liquid Glass chrome requires iOS 26
- A LibreChat v0.8.x server (developed and fixture-tested against v0.8.8-rc1)

## Getting started

1. Clone the repository.
2. Open `LibreChatIOS.xcodeproj` and select the **LibreChat** scheme.
3. Set your signing team and bundle identifier before installing on a device.
4. Build and run on an iOS Simulator or a connected device.

To sign in, point the app at your LibreChat instance. Loopback HTTP is supported for local development; remote hosts must use HTTPS.

## Testing

Run the core-package contract tests:

```sh
cd Packages/LibreChatCore
swift test
```

Run the application and SwiftData tests:

```sh
xcodebuild -project LibreChatIOS.xcodeproj \
  -scheme LibreChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

CI (GitHub Actions, macOS 26 runners with Xcode 26.6) runs three workflows on every push and pull request: core-package tests, app build & analyze, and the iOS unit-test suite — plus a nightly run that includes UI tests. UI tests are known-flaky locally; run them individually for evidence.

## Server compatibility

Mobile browser-based login (OAuth/OIDC/SAML/social) relies on optional server extensions:

```text
GET  /api/auth/mobile/config
GET  /api/auth/mobile/authorize
POST /api/auth/mobile/token
```

When these endpoints are absent, browser-only login methods are shown as unavailable; password login continues to work.

### Rate limiting and IP bans

LibreChat's `uaParser.js` middleware flags any User-Agent it cannot parse as a browser. The default violation score equals `BAN_INTERVAL`, so **one** request with a non-browser User-Agent (such as URLSession's default) causes an instant IP + account ban (`BAN_DURATION`, default 2 hours). Every build configuration therefore sends a Safari-profile User-Agent with a trailing `LibreChatiOS/1.0` token (`UserAgentPolicy` in `LibreChatProtocol/HTTP.swift`), applied to both REST and SSE sessions.

To clear an existing ban and its violation counters:

```sh
# MongoDB (default violation/ban store; database "LibreChat", collection "keyv")
mongosh LibreChat --eval 'db.keyv.deleteMany({ key: { $regex: /^(bans:|violations:)/ } })'

# Redis (when USE_REDIS=true)
redis-cli --scan --pattern 'ban_cache:*' | xargs redis-cli del
redis-cli --scan --pattern 'violations:*' | xargs redis-cli del
```

Other limits reachable from a shared egress IP: `LOGIN_MAX` (default 7 per 5 minutes) and `MESSAGE_IP_MAX` (default 40 per minute). The app never auto-retries login, mutations, or 403/429 responses; only transport failures and `SERVER_NOT_READY` are retried.

## Status

The app is functionally complete against the protocol surface above and verified by package contract tests, app unit/model tests, and deterministic Simulator UI-test fixtures. Authenticated live-server acceptance, external universal links, and server branch actions remain pending; treat pre-release validation against a real deployment as required before shipping.
