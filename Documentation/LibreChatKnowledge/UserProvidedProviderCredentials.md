# User-provided provider credentials

## Status and source boundary

This document records the native account-scoped provider-credential contract
implemented against the pinned LibreChat source baseline
`b2128a7d189ac020ebb6e49a57ee986e98326b77`.

The slice is implemented and contract/build verified. It has **not** been
accepted against an authenticated live deployment. No test or build read a real
provider secret.

## Server routes

LibreChat mounts the authenticated key router at `/api/keys`:

| Operation | Wire contract | Success | Retry rule |
|---|---|---|---|
| Read non-secret status | `GET /api/keys?name=<endpoint>` | `200 {"expiresAt": <ISO date | "never" | null>}` | Idempotent reads may retry under normal transport policy. |
| Save or replace | `PUT /api/keys` with `{name,value,expiresAt}` | empty `201` | Never automatically retry. A lost response can leave delivery uncertain. |
| Remove one | `DELETE /api/keys/:name` | empty `204` | Never automatically retry. Reconcile with a status read. |
| Remove all | `DELETE /api/keys?all=true` | empty `204` | Not exposed by the native app because a broad destructive action is unnecessary for target recovery. |

Every route uses `requireJwtAuth`; the authenticated user ID comes from the
server session, never from the request body. Sources:
`api/server/routes/keys.js:1-52` and
`api/server/routes/__tests__/keys.spec.js`.

The key model encrypts `value` before persistence. `getUserKeyExpiry` returns
only expiry metadata; there is no route that returns the decrypted secret to
the client. An omitted/falsey expiry unsets the TTL date and is reported as
`"never"`; an absent record reports `null`. Sources:
`packages/data-schemas/src/methods/key.ts:22-112` and
`packages/data-schemas/src/schema/key.ts`.

## Capability discovery

There is no separate global “user keys supported” capability. The authenticated
`GET /api/endpoints` response is authoritative for which provider entries need
an account credential. Native discovery considers:

- `userProvide`
- `userProvideAccessKeyId`
- `userProvideSecretAccessKey`
- `userProvideSessionToken`
- `userProvideBearerToken`

`userProvideURL` changes the compatible editor but does not by itself prove a
secret is required. Assistant endpoint families remain unsupported rather than
being made selectable merely because they advertise a key form.

Azure-backed endpoint configurations use LibreChat's shared `azureOpenAI` key
slot. The repository normalizes both credential management and target
availability evidence to that slot, while preserving per-endpoint evidence for
the target-catalog mapper. This prevents an Azure target from remaining hidden
after its valid shared credential has been saved.

Native source:
`Packages/LibreChatCore/Sources/LibreChatProtocol/UserKeys.swift` and
`LibreChat/Data/Repositories/LibreChatRepository.swift`.

## Exact provider envelopes

LibreChat stores one opaque string per endpoint name. Some providers consume a
raw key; others expect the web client's exact nested JSON convention:

| Provider form | Stored `value` shape |
|---|---|
| Simple provider such as Anthropic | Raw trimmed secret string. |
| OpenAI or compatible custom endpoint | JSON string `{"apiKey":"…","baseURL":"…"}`. `baseURL` is empty when unused. |
| Azure OpenAI | Outer `{"apiKey":"<nested JSON>","baseURL":""}`; nested JSON contains `azureOpenAIApiKey`, `azureOpenAIApiInstanceName`, `azureOpenAIApiDeploymentName`, and `azureOpenAIApiVersion`. |
| Google | JSON object with optional `GOOGLE_API_KEY` and `GOOGLE_SERVICE_KEY`; the latter remains a string containing canonical service-account JSON. At least one is required. |
| Amazon Bedrock | Outer `{"apiKey":"<nested JSON>","baseURL":""}`. Nested JSON contains either `bearerToken` alone or the server-required subset of `accessKeyId`, `secretAccessKey`, and `sessionToken`. |

Web construction evidence:
`client/src/components/Input/SetKeyDialog/SetKeyDialog.tsx:190-365`,
`OpenAIConfig.tsx`, `CustomEndpoint.tsx`, `BedrockConfig.tsx`,
`GoogleConfig.tsx`, and `client/src/hooks/Input/useMultipleKeys.ts`.

Server consumption evidence includes
`packages/api/src/endpoints/google/initialize.ts:35-75`,
`packages/api/src/endpoints/google/llm.ts:394-430`, and
`packages/api/src/endpoints/bedrock/initialize.ts`.

The Google server accepts the decrypted value as a JSON string and parses a
string-valued `GOOGLE_SERVICE_KEY` again. The Bedrock initializer accepts the
corresponding web wrapper. Native does not invent a different mobile protocol.

## Native domain and repository policy

Stable metadata types live in `LibreChatDomain`:

- `UserKeyEndpointID`
- `UserKeyAvailability`
- `UserKeyCredentialForm`
- `UserKeyRequirement`
- `UserKeyCatalog`
- `UserKeyUpdateInput`
- `UserKeyExpirationPreset`
- `UserKeyMutationResult`

`UserKeyCredentials` is intentionally `Sendable` and `Equatable` but **not
`Codable`**. It cannot enter SwiftData, scene restoration, or configuration
snapshots through the normal domain path.

`UserKeyRepository` exposes only:

```swift
func userKeyCatalog() async throws -> UserKeyCatalog
func saveUserKey(_ input: UserKeyUpdateInput) async throws -> UserKeyMutationResult
func revokeUserKey(_ endpointID: UserKeyEndpointID) async throws -> UserKeyMutationResult
```

Catalog reads refresh authenticated endpoint policy and then fetch non-secret
expiry evidence. No offline or stale cache is used. Profile/account identity is
captured before suspension and rechecked before a result is accepted.

Mutation requests use `.never` retry policy:

- An empty `201` confirms a save. The repository then refreshes status.
- If a save response is lost, status can prove a first save from a previously
  missing record or a changed exact expiry. It cannot prove that an already
  present secret was rotated, so that case remains `deliveryUncertain` and is
  never reposted automatically.
- If a delete response is lost, a subsequent `missing` status proves removal.
  Any other status remains `deliveryUncertain`.
- `401` remains session-invalidating authority. Definite `4xx` responses are
  surfaced instead of being converted into ambiguity.

## Native Settings interaction

Settings exposes **Provider credentials** for the authenticated repository. It:

- fetches live account policy and non-secret status;
- shows configured, expired, absent, and unavailable states;
- opens a provider-specific native editor;
- uses secure fields for every secret-bearing value;
- supports 30 minutes, 2 hours, 12 hours, 1 day, 7 days, 30 days, and no expiration;
- confirms destructive revocation;
- explains that LibreChat encrypts the value and the app cannot read it back;
- shows delivery uncertainty without performing an automatic replay.

Secret fields are owned only by the editor view. It constructs a one-shot
`UserKeyCredentials` value, clears every bound field before the first network
suspension point, and clears again when the scene becomes inactive or the sheet
disappears. `UserKeysModel` retains only metadata, mutation identity, and a
bounded user-facing status.

Native UI source:
`LibreChat/Features/Settings/UserKeysView.swift` and
`LibreChat/Features/Settings/SettingsView.swift`.

## Verification

The package suite passes **350 Swift Testing tests across 43 suites plus 4
XCTest checks (354 package checks)** at
`/private/tmp/librechat-visual-audit-core`. The new eight-case contract suite
covers endpoint-policy mapping, Azure slot collapse, exact status/update/delete
requests, expiration semantics, every supported provider envelope, unsafe URL
rejection, incomplete Google credentials, and wrong-form failure.

Five repository and four model tests compile in the successful generic
Simulator build-for-testing at `/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Derived`.
They cover fresh status, exact mutation wire, lost-rotation uncertainty without
repost, lost-delete reconciliation, unauthorized clearing, offline behavior,
confirmed refresh, and metadata-only observable state. They did not execute
because no Simulator was booted. The iOS 17-baseline device build passed at
`/private/tmp/LibreChatIOS-CompetitiveVisual-20260819-Device-Derived`.

Still pending:

- authenticated live save/replace/revoke with a disposable provider key;
- server-side target reappearance after save and disappearance after revoke;
- expiration behavior over real time;
- VoiceOver, Dynamic Type, and background field-clearing acceptance;
- provider authentication itself—a stored key does not prove the third-party
  provider will accept it.
