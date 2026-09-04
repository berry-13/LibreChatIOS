# LibreChat authentication and onboarding contract

Audit target: LibreChat commit `b2128a7d189ac020ebb6e49a57ee986e98326b77` in `/tmp/librechat-knowledge.mI6Evl/LibreChat` (verified with `git rev-parse HEAD`). Client comparison: `Packages/LibreChatCore/Sources/LibreChatProtocol/Authentication.swift`, `LibreChat/App/AppModel.swift`, and the mobile authorization coordinator in `LibreChat/Platform/WebAuthentication/MobileAuthenticationCoordinator.swift`. This is a source audit; no app source was changed.

## Executive result

The existing native client can complete local email/password login, local 2FA challenge login, bearer-authenticated requests, refresh, logout, capability-gated password-reset request and registration, capability-gated email-verification resend, mandatory terms acceptance, and (when a separate server extension exists) authorization-code sign-in. Registration is exposed only when email login and registration are enabled and no Turnstile challenge is advertised; it never retries, does not authenticate the new account, and has no invite-token UI. Password login recognizes only the pinned unverified-email `422` semantic and offers resend only when anonymous configuration advertises email delivery. Raw-token email verification, reset-token completion/deep-link routing, and browser-link interception remain incomplete. The pinned LibreChat server does not implement the mobile authorization-code endpoints that the app probes (`/api/auth/mobile/config`, `/authorize`, `/token`); the app correctly treats those endpoints as optional and disables social/OIDC/SAML native sign-in unless an extension advertises protocol version 1.

The highest-risk remaining gaps are:

1. Refresh relies on an `HttpOnly` cookie and can return either `{token,user}` or a non-JSON string/HTML redirect. The native cookie/session implementation and serialized refresh are fixture-tested, but rotation, revocation, redirect, and expiry behavior still need authenticated live evidence.
2. Verification and reset emails contain browser-origin bearer-like tokens. The native app deliberately does not parse or persist those raw links; arbitrary self-hosted domains cannot be made dynamic Universal Links without a reviewed server handoff contract.
3. Browser OAuth/OIDC/SAML still lacks a mobile authorization-code extension in the pinned server. Provider flags alone cannot authenticate the native `URLSession`.
4. The corrected 2FA setup/verify/confirm/disable/backup-code routes have fixture coverage but no live enrollment, recovery, or accessibility acceptance.

## Endpoint and response contract

All paths below are relative to the server mount `/api`; the source mounts auth at `app.use('/api/auth', ...)` (`api/server/index.js:289`). `DOMAIN_CLIENT` is the browser redirect origin, not a native callback.

| Endpoint | Auth / request | Success | Native implication |
|---|---|---|---|
| `GET /api/config` | Anonymous or JWT cookie/bearer via app middleware | Anonymous payload includes auth flags, labels, `serverDomain`, registration/reset/email flags, social-login map; authenticated adds post-login fields (`api/server/routes/config.js:209-250`) | App discovery is appropriate, but `socialLoginEnabled` is not proof that a native callback exists. |
| `POST /api/auth/login` | JSON `{email,password}`; local middleware (`api/server/routes/auth.js:42-52`) | 200 `{token,user}` or 200 `{twoFAPending:true,tempToken}` (`LoginController.js:5-21`) | Current `Authentication.swift:25-50` matches this. Cookies must be captured. |
| `POST /api/auth/register` | JSON validated registration fields; invite may bypass flag (`auth.js:67-74`, `validateRegistration.js:3-15`) | Usually 200 `{message}` generic verification message; may be 403/404/500 | Native UI is capability-gated to email login + registration enabled + no advertised Turnstile. Invite tokens remain body-only and have no native UI. Registration does not return a session. |
| `POST /api/auth/requestPasswordReset` | JSON `{email}`; reset flag/rate limiter | 200 generic `{message}`; if email unavailable, may return `{link}` (`AuthService.js:430-515`) | Capability-gated native request sheet is implemented; a validated returned web link remains screen-memory-only. |
| `POST /api/auth/resetPassword` | JSON `{userId,token,password}` | 200 `{message:'Password reset was successful'}`; invalid token 400; deletes all sessions (`AuthController.js:136-151`, `AuthService.js:525-556`) | Typed protocol request exists, but there is no raw-token/deep-link UI; universal-link/browser handoff is still required. |
| `POST /api/user/verify` | JSON `{email,token}`; anonymous, rate-limited (`api/server/routes/user.js:21-30`; `AuthService.js:254-322`) | 200 `{message,status:'success'}` or 400 generic invalid/expired | Typed protocol request exists, but no raw-token UI. Email link is `${DOMAIN_CLIENT}/verify?...` (`AuthService.js:219-245`). |
| `POST /api/user/verify/resend` | JSON `{email}`; anonymous, rate-limited | Generic 200 notice; replaces any prior outstanding verification token | Native login recovery calls this once with no automatic retry, only after the exact unverified-login response and advertised email-delivery support. |
| `POST /api/auth/refresh` | No body; `refreshToken` cookie (and `token_provider`) | Local: 200 `{token,user}`; no cookie: 200 plain `Refresh token not provided`; invalid/expired: 401/403 plain text or redirect to `/login` (`AuthController.js:155-303`) | Must preserve cookie jar and accept non-JSON failure. `Authentication.swift:127-140` assumes JSON on every 2xx, so the 200 string becomes decoding error. |
| `POST /api/auth/logout` | Required JWT, normally bearer or cookie | `{message:'Logout successful'}`; clears refresh/OpenID/CloudFront cookies (`auth.js:40-42`, `LogoutController.js:24-...`) | Current logout sends bearer and then clears local cookies; server session deletion depends on refresh cookie being sent. |
| `POST /api/auth/2fa/enable` | Required JWT; body required only when re-enrolling already-enabled 2FA: `{token}` or `{backupCode}` | 200 `{otpauthUrl,backupCodes}` (`TwoFactorController.js:19-58`) | Client currently sends GET and decodes `otpauth_url`; contract mismatch. |
| `POST /api/auth/2fa/verify` | Required JWT; `{token}` or `{backupCode}` | Empty 200; invalid 400 (`TwoFactorController.js:64-92`) | Verifies pending secret but does not enable it. |
| `POST /api/auth/2fa/confirm` | Required JWT; `{token}` | Empty 200; sets `twoFactorEnabled` and promotes pending codes (`TwoFactorController.js:97-129`) | Client has no confirm call and incorrectly expects backup codes from verify. |
| `POST /api/auth/2fa/disable` | Required JWT; `{token}` or `{backupCode}` when enabled | Empty 200 (`TwoFactorController.js:136-165`) | Client sends `{password}`; will fail. |
| `POST /api/auth/2fa/backup/regenerate` | Required JWT; `{token}` or `{backupCode}` when enabled | 200 `{backupCodes,backupCodesHash}` (`TwoFactorController.js:172-201`) | Client path is `/2fa/regenerate` and body is wrong. Never expose/store `backupCodesHash` as plaintext codes. |
| `POST /api/auth/2fa/verify-temp` | Anonymous temp flow `{tempToken, token}` or `{tempToken,backupCode}` | 200 `{token,user}`; temp JWT expires 5 minutes (`TwoFactorAuthController.js:14-54`, `twoFactorService.js:241-247`) | Current `Authentication.swift:52-71` matches. |
| `GET /api/auth/{google,facebook,github,discord,openid,saml}` | Browser Passport redirect | Redirect to IdP | Not a JSON/native contract. |
| Provider callback (`GET` usually; Apple/SAML `POST`) | Browser session/state/callback | Sets cookies then redirects to `DOMAIN_CLIENT` (`oauth.js:63-218`, controller `oauth.js:72-86`) | Cannot deliver a token to iOS safely without a server mobile authorization-code extension. |

## `/api/config` flags and tenant behavior

`buildPreLoginPayload()` is intentionally anonymous and supplies `emailLoginEnabled` (default enabled unless `ALLOW_EMAIL_LOGIN` is explicitly false), `registrationEnabled` (LDAP disables it, and `ALLOW_REGISTRATION` must be enabled), `passwordResetEnabled`, `emailEnabled`, `minPasswordLength`, LDAP config, and provider availability (`api/server/routes/config.js:48-110`). Provider flags require provider credentials; OpenID additionally requires client ID, PKCE or secret, issuer, and session secret (`:55-66`); SAML requires entry point, issuer, certificate, and session secret (`:62-67`). `socialLoginEnabled` is a separate `ALLOW_SOCIAL_LOGIN` feature flag (`:90-98`), so clients should treat both the global flag and provider-specific flag as necessary.

The anonymous route merges tenant/base registration social-login configuration (`config.js:209-247`). Auth routes run through `preAuthTenantMiddleware` and are mounted at `/api/auth` (`api/server/index.js:289`); password registration/reset domain checks resolve base then tenant config (`AuthService.js:349-356`, `:430-460`). A native client must preserve the exact configured base URL, including deployment subdirectory. The server's `DOMAIN_CLIENT` is used to generate email and OAuth links; it may not equal the API origin or an app custom-scheme callback. Do not concatenate a hard-coded `/api` if the deployment has a path prefix: derive the endpoint from the server URL/profile and test a subdirectory deployment.

The native repository now performs a bearer-authenticated post-login config refresh and records whether that account-specific policy was actually verified. It maps the shared-link flags, derives Agent availability from the separately authenticated `/api/endpoints` response, applies exact current-role MCP/Memory/Prompt/Bookmark permissions, and probes speech independently. Anonymous capability state can no longer remain visible after an authenticated refresh failure: account-gated features fail closed, Settings explains the problem, and an explicit retry can restore only fresh evidence. A retry 401 invalidates the session. These values still gate presentation rather than replacing route authorization, and the complete authenticated interface/model-spec policy remains broader than this slice. File opt-in is exposed only from authenticated `sharedLinksSnapshotFilesEnabled` evidence. Package and compile proof do not establish live permission behavior. See [SharingAndPublicSnapshots.md](SharingAndPublicSnapshots.md).

## Native account-access slice (implemented, live acceptance pending)

Anonymous `GET /api/config` is decoded into typed `PreLoginCapabilities`: email-login availability, registration and password-reset flags, email delivery availability, minimum password length, and a Turnstile presentation signal. Registration UI is shown only when email login and registration are enabled and no Turnstile challenge is advertised; it sends the exact non-retriable public registration request, keeps any invite token body-only, and treats the response as a notice rather than a login. The native client also provides a capability-gated **Forgot Password** sheet using non-retriable `POST /api/auth/requestPasswordReset` with generic anti-enumeration success. A server-returned recovery `link`, when present, stays in sheet memory only and is displayed only after scheme validation; it is never persisted or logged.

Public legal configuration is typed separately from authenticated policy. Terms and privacy URLs accept only `http`/`https` or loopback development URLs, reject unsupported schemes and malformed hosts, and are opened as external legal links. Authenticated terms use idempotent `GET /api/user/terms` and non-retriable `POST /api/user/terms/accept`; when the server marks terms as required, the app presents a mandatory terms sheet with explicit accept/decline behavior before normal use.

This slice deliberately does not invent a mobile Turnstile challenge contract. Email-verification **resend** is implemented, but raw-token verification, reset-token completion, and reset/verification universal-link or deep-link routing remain unimplemented. Authenticated/live acceptance of pre-login discovery, registration/reset request, unverified-login resend, legal links, and terms acceptance is still required before release.

## Native profile and account-deletion slice

After authentication, Settings exposes a server-authoritative **Profile and account** screen. It rereads the sanitized user through exact-account `GET /api/user`, uses authenticated `/api/files/config.avatarSizeLimit` to preflight a PNG/JPEG multipart avatar replacement, and presents name, username, email, role, and 2FA status without inventing unsupported edit routes.

Self-deletion is separate from logout. It appears only when a successful authenticated config refresh supplies `allowAccountDeletion: true`; anonymous, stale, or failed policy evidence hides it. The one-shot `DELETE /api/user/delete` sends no body for an unprotected account or exactly `{token}` / `{backupCode}` for a 2FA account. Only exact `200 {"message":"User deleted"}` confirms success. Transport, cancellation, 5xx, malformed 2xx, or account-selection change is outcome-unknown and never automatically reposted. Confirmed deletion clears credentials/cookies, purges or hides the exact account cache namespace, resets active generation/upload ownership, removes the profile's account binding, and returns to signed-out state.

The complete contract, server source anchors, and limits are in [AccountProfileAndDeletion.md](AccountProfileAndDeletion.md). Current evidence is package and compile verification; real avatar storage behavior, destructive-session cleanup, 2FA deletion, accessibility, and iOS 17 runtime behavior remain pending.

## Password login, onboarding and email verification

The login route applies logging, login limiting, ban checking, email validation, and local/LDAP auth middleware before `loginController` (`auth.js:42-52`). A successful local login strips password, TOTP secret and version fields, adds `user.id`, issues a short-lived app JWT, and sets refresh cookies (`LoginController.js:11-21`; `AuthService.js:653-689`). If 2FA is enabled, no access token/cookies are issued yet; only a five-minute signed temp token is returned.

Registration validates via `registerSchema`, checks tenant allowed domains and duplicate email, creates the first user as admin, hashes the password, and returns the same generic verification message for a new or existing address (`AuthService.js:331-402`). If email is configured and unverified, the server sends a 15-minute hashed verification token and a browser link `${DOMAIN_CLIENT}/verify?token=...&email=...`; otherwise it marks the account verified (`:219-245`, `:387-400`). The API does not log the user in. If email is unavailable, registration still marks verified, which is configuration-sensitive.

Password reset likewise uses a 15-minute hashed token, deletes prior tokens, emails `${DOMAIN_CLIENT}/reset-password?token=...&userId=...`, and intentionally returns a generic response for unknown users (`AuthService.js:430-515`). Completing reset invalidates all user sessions (`AuthController.js:146-147`). A native flow needs universal-link/deep-link interception or a secure browser handoff; accepting raw reset tokens inside arbitrary app URLs must be threat-modeled.

## Cookies, access tokens, rotation and logout

For local auth, `setAuthTokens()` creates or reuses a DB session, generates an app JWT with `SESSION_EXPIRY`, and sets:

```text
refreshToken=<opaque/JWT>; Expires=<session expiration>; HttpOnly; Secure when configured; SameSite=Strict
token_provider=librechat; same attributes
```

(`AuthService.js:653-689`). The client JWT is returned in JSON as `token`; it is not itself the refresh credential. On refresh, the server verifies the refresh JWT, finds the hashed DB session, and calls `setAuthTokens()` again (`AuthController.js:258-290`), thereby issuing a new access token and refresh cookie. Rotation is therefore cookie/session-backed and should be treated as single-use-ish state from the mobile transport's perspective; concurrent refreshes need serialization (the client does serialize with `refreshTask`).

OpenID token reuse changes the contract. The server sets `refreshToken`, `token_provider=openid`, and `openid_user_id` cookies; large IdP tokens live in an express session where possible (`AuthService.js:727-842`). The returned app bearer is preferably an ID token, otherwise an access token (`:763-775`). OpenID refresh may reuse a recent, unexpired session token, or call the IdP refresh grant and then rotate cookies/session (`AuthController.js:159-251`). Native code cannot reproduce this from bearer headers; it must retain the cookie/session context established by the browser authorization flow or use the mobile extension.

Logout requires JWT auth, deletes the DB session selected by the incoming refresh cookie, destroys the express session, clears local/OpenID/token-provider/CloudFront cookies, and may construct an OpenID end-session redirect (`LogoutController.js:24-...`; `AuthService.js:178-202`). Sending only bearer without refresh cookie can leave the DB refresh session until expiry even though the app clears local state. `AuthSession.logout()` best-effort sends bearer and clears its cookie jar (`Authentication.swift:172-182`), so the transport must have captured cookies from login/refresh.

Security attributes are strong for browser CSRF (`HttpOnly`, `Secure`, `SameSite=Strict`), but native URLSession cookie behavior must be verified per profile. SameSite is not a substitute for bearer/API authorization, and a cookie jar shared between server profiles would be a credential-confusion bug; the app's `ProfileCookieJar` is correctly profile-scoped (`Authentication.swift:287-313`).

## 2FA state machine

```text
POST /login(email,password)
  ├─ 2FA off  -> {token,user}, refresh cookies -> authenticated
  └─ 2FA on   -> {twoFAPending,tempToken}, no session
                    ├─ POST /2fa/verify-temp {tempToken,token}
                    └─ POST /2fa/verify-temp {tempToken,backupCode}
                         -> {token,user}, refresh cookies -> authenticated

Authenticated, 2FA setup:
  POST /2fa/enable [JWT] -> pending secret + one-time plaintext backupCodes
  POST /2fa/verify {token|backupCode} [JWT] -> empty 200 (verification only)
  POST /2fa/confirm {token} [JWT] -> empty 200; promotes pending secret/codes

Authenticated, enabled 2FA:
  POST /2fa/disable {token|backupCode} -> clears secret/codes
  POST /2fa/backup/regenerate {token|backupCode} -> new plaintext codes
```

The server accepts a backup code by hashing/looking up and marking it used (`twoFactorService.js:160-182`). Setup generates ten eight-character hexadecimal codes and stores only SHA-256 hashes (`:123-147`). The client should display codes once and avoid logging them.

Current iOS comparison: login/temp verification and the authenticated setup → verify → confirm sequence are aligned. Disable and backup-code regeneration use exact `{token}`/`{backupCode}` proof and `/backup/regenerate`; backup codes stay memory-only in the setup surface. These are fixture/build results, not live proof.

## OAuth, OIDC, SAML, social redirects and state

The server's social routes are Passport browser redirects with `session:false`; Google/Facebook/GitHub/Discord use GET callbacks, Apple and SAML use POST callbacks (`api/server/routes/oauth.js:63-218`). The callback handler sets auth cookies and redirects to `DOMAIN_CLIENT` (`api/server/controllers/auth/oauth.js:72-86`). OpenID generates a random state at the start route (`routes/oauth.js:114-129`) and uses a configured callback authenticator. SAML uses express-session-backed state/configuration (`socialLogins.js:110-132`). These flows assume a browser can follow redirects, retain server cookies/session, accept an HTML callback, and land on the web client.

The current iOS coordinator intentionally uses a separate extension: it requests `/api/auth/mobile/config`, launches `ASWebAuthenticationSession` with provider, redirect URI, `response_type=code`, PKCE S256 challenge, random state, and custom `librechat://auth/callback`, then exchanges the code plus verifier at `/api/auth/mobile/token` (`MobileAuthenticationCoordinator.swift:33-94`; `LibreChatRepository.swift:42-93`). The pinned server has no such routes. Therefore direct use of `/api/auth/google` etc. cannot yield a native session; adding a custom URL scheme to the existing browser redirect would be unsafe and would still not solve cookie/session delivery. The required extension must bind authorization code to provider, redirect URI, PKCE verifier, and state; enforce one-time short expiry; then return the same `{token,user}` contract and set refresh cookies.

CSRF/state assumptions differ: web Passport middleware/IdP strategies own state and browser session; the mobile coordinator validates its own callback state but does not currently validate an error parameter or ensure the callback scheme/host/profile is bound beyond the generated state (`MobileAuthenticationCoordinator.swift:62-85`). The mobile server extension must perform server-side state/PKCE checks too; client-only state is not sufficient.

## Native-client gaps and priorities

| Priority | Gap | Evidence | Impact | Recommended resolution |
|---|---|---|---|---|
| P0 | Cookie-backed refresh not explicitly guaranteed/JSON-safe | Server cookie-only refresh and plain-text/redirect outcomes (`AuthController.js:155-303`); client JSON-decodes all 2xx (`Authentication.swift:127-140`) | Session restoration fails or DB session is not revoked on logout | Verify cookie capture/send per profile; model `Refresh token not provided` and redirects as signed-out; add integration tests for rotation/concurrency. |
| P0 | No native OAuth/OIDC/SAML contract in pinned server | Browser-only routes/cookie redirects (`routes/oauth.js:63-218`, controller `oauth.js:72-86`) | Social/enterprise sign-in cannot complete natively | Deploy a reviewed `/api/auth/mobile/*` PKCE authorization-code extension; keep browser fallback explicit. |
| P1 | 2FA management lacks live/accessibility proof | Corrected native routes match `TwoFactorController.js:19-201`, but evidence is fixture/build-only | Enrollment or recovery regressions could strand users despite contract coverage | Live-test authenticator and backup-code setup, confirmation, disable, regeneration, relaunch, and VoiceOver. |
| P1 | Verification/reset completion absent; resend is app-tested but live-unproven | Server routes (`auth.js:67-88`, `user.js:29-30`); native resend uses the public route but raw-token links remain web-origin | Users can request a fresh verification email but cannot securely complete link-token flows inside the app | Live-prove resend; add only a reviewed universal-link/browser handoff contract for token completion. |
| P1 | Email verification/reset links are web-origin links | `AuthService.js:219-245`, `:488-510` | Deep links need domain association and token-safe handling | Configure universal links; do not log/display tokens; handle expired/used states. |
| P1 | Config capability interpretation conflates provider flags and mobile support | `config.js:55-98`; `Capabilities.swift:13-35` | UI may show provider options that cannot return to app | Gate native methods on mobile protocol advertisement, not only `/api/config` provider flags. |
| P1 | Base path/tenant origin assumptions | `/api` mount `index.js:289`; tenant-aware config/reset checks | Subdirectory or tenant deployments can hit wrong endpoint or email origin | Store normalized server origin/base path; test `/chat/api/...` and tenant host routing. |
| P2 | OpenID refresh/session complexity | `AuthService.js:727-842`, `AuthController.js:159-251` | Browser session expiry or missing cookie causes opaque failures | Extension should normalize to a mobile token contract; otherwise retain ASWebAuthenticationSession cookie context. |
| P2 | Logout best-effort hides server failure | `Authentication.swift:172-182` | Local sign-out can leave server refresh session valid | Surface network failure separately while always clearing local credentials; retry/revoke on next connectivity. |

## Minimum acceptance tests for a mobile-compatible deployment

1. Login captures both refresh cookies, refresh returns `{token,user}`, rotates cookies, and two concurrent 401s produce one refresh.
2. Missing/expired refresh returns a typed unauthenticated result rather than a decode error; browser `/login` redirect is never treated as an access token.
3. Local login, temp TOTP, temp backup code, logout, and account switch are isolated per profile.
4. 2FA setup exercises POST enable → verify → confirm; disable and regenerate exercise OTP and backup-code branches and exact paths.
5. Registration with email verification, resend, reset request, universal-link completion, expired token, duplicate email, LDAP, disabled flags, and tenant domain restrictions.
6. Mobile PKCE provider flow rejects state mismatch, wrong redirect URI, reused/expired code, wrong verifier, and provider/tenant mismatch; successful exchange returns `{token,user}` and refresh cookies.
7. Deployment under a non-root base path and OpenID with/without token reuse.
