# Account profile, avatar, and self-deletion

**Pinned LibreChat source:** `b2128a7d189ac020ebb6e49a57ee986e98326b77`  
**Native status:** implemented and fixture/build-verified; authenticated live acceptance pending

## Product boundary

The native **Profile and account** screen is an account-security surface, not a second user database. It refreshes the signed-in account from LibreChat, displays the server-owned identity, permits a profile-image replacement, and exposes self-deletion only when authenticated server policy allows it.

The pinned server does not expose a self-service native mutation for changing `name`, `username`, `email`, or password. Those values, plus role, are therefore read-only in the app. The client must not invent an identity-edit/password route or imply that editing local cache would update the LibreChat account.

## Exact server contract

| Operation | Wire contract | Native rule |
|---|---|---|
| Refresh profile | Bearer-authenticated `GET /api/user`; response is the server's sanitized user shape. [Route](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/user.js#L21-L30), [response allowlist and S3 refresh](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/UserController.js#L31-L80) | Accept only the exact active account ID. A different identity never replaces the selected profile/account namespace. |
| Read avatar limit | Bearer-authenticated `GET /api/files/config`; `avatarSizeLimit` is already expressed in bytes. [Route](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/files/files.js#L135-L143), [default and dynamic merge](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/packages/data-provider/src/file-config.ts#L476-L516) | Use fresh server evidence when available, fall back to the pinned 2 MiB default when configuration cannot be read, and treat an explicit zero as uploads disabled. |
| Replace avatar | Bearer-authenticated, rate-limited `POST /api/files/images/avatar`, multipart field `file` plus `manual=true`; response `{url}`. [Authenticated file router](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/files/index.js#L20-L33), [avatar upload](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/files/avatar.js#L11-L52) | Accept only byte-validated PNG/JPEG, enforce the configured limit before POST, never retry automatically, and accept only a safe HTTP(S) returned URL. |
| Discover deletion permission | Authenticated `/api/config` adds `allowAccountDeletion`; anonymous config omits the account policy. Admin capability can restore permission when global self-deletion is disabled. [Post-login field](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/config.js#L137-L154), [admin override](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/config.js#L322-L341) | Show Delete Account only from freshly authenticated capability evidence. Unknown, anonymous, stale, and refresh-failed policy all fail closed. |
| Delete account | Bearer-authenticated `DELETE /api/user/delete`; optional JSON is exactly `{token}` or `{backupCode}` for a 2FA account; exact success is `200 {"message":"User deleted"}`. [Route and policy middleware](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/routes/user.js#L21-L30), [permission check](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/middleware/canDeleteAccount.js#L17-L43), [2FA and deletion cascade](https://github.com/danny-avila/LibreChat/blob/b2128a7d189ac020ebb6e49a57ee986e98326b77/api/server/controllers/UserController.js#L352-L419) | One attempt only. A transport, cancellation, 5xx, malformed success, or identity switch becomes outcome-unknown and must not offer a blind repost. |

## Native state and recovery policy

- Avatar bytes exist only in the picker/upload task. They are not written to SwiftData, Keychain, logs, or a conversation record.
- The multipart request is `.never` retry. PNG/JPEG signatures are checked before transport; MIME labels alone are not trusted.
- Success and post-dispatch ambiguity reconcile through authoritative `GET /api/user`; state/cache commits only when that response proves the exact selected account. A finite unknown outcome remains locked and is never replayed.
- Avatar identity ignores signed-URL query parameters. Profile and selection epochs fence every picker, POST, reconciliation, and cache/state commit so an old profile cannot install its avatar into a newly selected account.
- Account deletion requires typing `DELETE`. A 2FA-enabled account additionally requires a transient authenticator or backup-code proof.
- A confirmed deletion checkpoints/detaches generation work, clears the native auth session and profile cookie jar, purges or hides the exact account namespace, resets repository/upload state, removes the profile's account binding, and returns to signed-out state.
- An ambiguous deletion remains locked on the confirmation screen. The user is told to verify the account in a fresh session instead of repeating a potentially completed destructive request.

## Deliberate limits

- No name, username, email, password, role, provider, or tenant mutation is claimed.
- The Photos picker has no crop/rotate editor in this slice.
- The image is loaded into memory before the protocol size check; the default is small, but staged-file decoding remains a production-hardening opportunity for unusually large source assets.
- A 2xx avatar response with a missing or unsafe URL is rejected, although the server may already have changed the avatar; the app does not automatically repost.
- Avatar rendering through every storage strategy and signed-URL refresh behavior still need authenticated live proof.

## Verification boundary

The 2026-08-19 Core run passed **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)**. Exact profile, capability, multipart, size, safe-URL, deletion-body, acknowledgement, identity-fence, authoritative avatar reconciliation, signed-URL identity normalization, and one-shot ambiguity contracts are covered. Five avatar repository ambiguity cases and three AppModel avatar state/cache-fencing cases compile in the successful generic Simulator build-for-testing at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`; they were not executed because no Simulator was booted. The iOS 17 minimum-target device build passed at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`.

This evidence does not prove a live avatar upload, real 2FA-protected deletion, storage-provider URL behavior, rate limiting, VoiceOver, Dynamic Type, or post-deletion server/session state. Those are explicit acceptance gates.
