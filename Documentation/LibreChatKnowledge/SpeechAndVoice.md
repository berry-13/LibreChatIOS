# Speech, dictation, and Read Aloud

This document records the speech contract verified against the pinned LibreChat
source baseline `b2128a7d189ac020ebb6e49a57ee986e98326b77` and the bounded native iOS
implementation. It deliberately separates server configuration, dictation, and
full voice conversation: they are different capabilities with different recovery
and privacy semantics.

## Route family and authentication

LibreChat mounts speech below the authenticated files router. `requireJwtAuth`,
configuration middleware, ban checks, and user-agent parsing run before the speech
router.

| Operation | Contract | Native status |
| --- | --- | --- |
| Discover speech settings | `GET /api/files/speech/config/get` | Implemented and used as authenticated capability proof |
| Transcribe audio | `POST /api/files/speech/stt` multipart | Implemented for explicit native dictation |
| Manual TTS | `POST /api/files/speech/tts/manual` | Implemented for explicit response Read Aloud |
| Streaming/cached TTS | `POST /api/files/speech/tts` | Not implemented |
| List voices | `GET /api/files/speech/tts/voices` | Implemented and used by the native account-scoped voice picker |

Evidence: `api/server/routes/files/index.js:20-31`,
`api/server/routes/files/speech/index.js:1-14`, and
`packages/data-provider/src/api-endpoints.ts:306-335`.

## Authenticated capability proof

Anonymous or general startup configuration is only a hint. The app enables native
dictation only after authenticated `GET /api/files/speech/config/get` returns
`sttExternal: true` and does not explicitly disable `speechToText`. Older cached
capabilities decode with this proof absent and therefore fail closed.

The sanitized response can contain:

```json
{
  "sttExternal": true,
  "ttsExternal": false,
  "speechToText": true,
  "engineSTT": "openai",
  "languageSTT": "en-US",
  "autoTranscribeAudio": false
}
```

The client preserves only stable proof needed by the native feature:

- external STT/TTS availability;
- explicit speech-to-text/text-to-speech disablement;
- a validated optional ISO-639 locale for STT;
- a validated optional preferred synthesis voice; and
- an optional playback rate only within `0.25...4`.

It does not receive provider secrets. A positive `sttExternal` value proves that
an STT section exists, not that the provider will successfully process a request;
the authenticated STT response remains authoritative.

Evidence: `api/server/services/Files/Audio/getCustomConfigSpeech.js:16-77` and
`packages/data-provider/src/config.ts:1285-1319`.

## STT wire contract

The request is exactly:

```text
POST /api/files/speech/stt
Authorization: Bearer <access token>
Content-Type: multipart/form-data; boundary=<client boundary>

audio: <binary audio file>
language: <optional two-letter locale such as en or en-US>
```

The multipart file field is `audio`, not the general upload field `file`. The
success body is `{ "text": "..." }`. Missing audio returns HTTP 400. Provider
configuration and provider-processing failures collapse to HTTP 500. The server
normalizes a valid language to its two-letter prefix and ignores an invalid one;
native validation instead fails before dispatch so the UI cannot imply a language
that the server silently ignored.

The current iOS encoder emits mono 16 kHz MPEG-4 AAC as `.m4a` with `audio/mp4`.
That format is accepted by both pinned providers. Native capture is bounded to
five minutes and 25 MiB, even though the deployment's general upload limit may be
higher or lower. The real server limit remains authoritative.

Evidence: `client/src/hooks/Input/useSpeechToTextExternal.ts:112-126`,
`api/server/routes/files/index.js:27-31`,
`api/server/services/Files/Audio/STTService.js:20-114,194-275,334-397`, and
`packages/data-provider/src/types/files.ts:207-209`.

## Manual TTS wire contract

The explicit Read Aloud request is:

```text
POST /api/files/speech/tts/manual
Authorization: Bearer <access token>
Content-Type: multipart/form-data; boundary=<client boundary>

input: <visible finished assistant prose>
voice: <optional configured voice>
```

Success is a nonempty `audio/mpeg` response body, not JSON. Missing input is a
plain-text HTTP 400. The app also supports authenticated
`GET /api/files/speech/tts/voices`, whose response is a flat string array; it
trims, validates, and deduplicates those opaque names without inventing provider
metadata. A missing or unavailable preferred voice is ultimately resolved by the
server's configured voice policy.

The native picker preserves these strings as opaque identifiers. It does not
capitalize them, infer a language, provider, accent, or gender, or manufacture
sample metadata the route does not return. `ALL` is a provider wildcard rather
than a selectable voice and is filtered out. The explicit **Server default**
choice stays distinct from a named voice: it honors the authenticated speech-tab
preference when present and otherwise omits `voice` so the server selects from
its configured provider list. A previously selected identifier that disappears
from a freshly loaded catalog is reset to Server default with a visible notice;
it is never silently displayed as still selected.

The choice is stored in the existing SwiftData configuration-snapshot envelope,
namespaced by exact profile and account. It survives cache reopen, is hidden from
other accounts on the same host, and is removed by that namespace's Clear Cache
or profile purge. Voice discovery is an idempotent GET; selecting a voice never
synthesizes audio. Saving rejects any named identifier not present in the current
catalog, while changing the preference during playback affects only future
synthesis requests.

The pinned server handles input below 4,096 characters with one provider request.
Longer input is split into roughly 1,000-character segments and concatenated into
one response stream. There is no range, resumable-download, or playback-position
protocol. Native therefore receives and validates the complete response before
creating `AVAudioPlayer`; a partial otherwise-200 MP3 may still fail only when the
player prepares it.

Exactly one configured provider is required: OpenAI, Azure OpenAI, ElevenLabs, or
LocalAI. Provider credentials and upstream URLs remain server-side. Manual TTS is
limited by the server's TTS rate limiters, whose defaults are 100 requests per IP
per minute and 50 per authenticated user per minute.

Evidence: `api/server/routes/files/speech/tts.js:12-41`,
`api/server/services/Files/Audio/TTSService.js:48-82,110-369`,
`api/server/services/Files/Audio/getVoices.js:15-53`, and
`api/server/middleware/limiters/ttsLimiters.js:6-74`.

## Provider and rate-limit behavior

The pinned server supports exactly one configured STT provider:

- `openai`, using the configured model and optional URL;
- `azureOpenAI`, using configured instance, deployment, and API version.

Zero or multiple configured providers fail. Azure additionally enforces 25 MiB
and accepts `flac`, `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `ogg`, `wav`, and `webm`.
The native app intentionally does not expose broader MIME choices merely because
the initial Multer audio filter accepts them.

Dedicated STT limit defaults are 100 requests per IP per minute and 50 requests
per user per minute. A limit response is HTTP 429 with a message and may include
`Retry-After`; the UI presents that duration without scheduling a retry.

Evidence: `api/server/services/Files/Audio/STTService.js:145-174,194-275` and
`api/server/middleware/limiters/sttLimiters.js:6-74`.

## Retry, ambiguity, and privacy policy

STT has no request ID, status lookup, or durable job record. A lost response may
already have consumed provider work. Therefore:

- multipart STT uses `.never` transport retry;
- 401 recovery may refresh once because the rejected request was not authorized;
- transport, 5xx, malformed success, and lost-response outcomes never repost
  automatically;
- an explicit user retry may submit the same in-memory recording again, with
  copy explaining that provider work may repeat;
- the transcript is inserted into the editable composer and is never auto-sent;
- audio is not a chat attachment and is not cached in SwiftData;
- the local temporary file is removed when capture finishes, is cancelled, the
  sheet closes, or the app becomes inactive;
- an in-flight transcription task is cancelled on inactivity/dismissal;
- no audio bytes, transcript, cookie, bearer token, profile/account identity, or
  multipart body is logged.

Server-side Multer stores a temporary per-user upload and `STTService` deletes it
in `finally` after success or failure. No LibreChat file record is created.

Evidence: `api/server/routes/files/multer.js:14-28` and
`api/server/services/Files/Audio/STTService.js:340-372`.

## Native interaction state machine

The native sheet owns its interaction and presents explicit states:

```text
capability check
  → microphone permission
  → recording
  → user stop / duration limit / interruption
  → explicit transcription
  → editable composer draft
```

Failure branches retain honest ownership:

- denied permission offers the system Settings path;
- an interruption or duration limit offers Transcribe or Discard while stating
  that audio has not yet been sent;
- a network/5xx ambiguity retains only the in-memory captured audio for an
  explicit retry or dismissal;
- backgrounding discards temporary audio and cancels in-flight work;
- authorization failure routes through the app's existing session-expiry path.

The mic control appears only for an authenticated, online profile whose refreshed
speech capability explicitly proves external STT. Recording does not depend on an
active AI generation and transcription never calls `ChatRepository.send`.

The native session also fences its asynchronous finish path: lifecycle invalidation
and the operation identity are checked synchronously before a suspended
transcription result can mutate the sheet or draft. A process-wide actor owns the
`AVAudioSession`/microphone lease across scenes, so competing recordings are
rejected rather than sharing or replacing the active capture. Dismissal,
backgrounding, and a newer operation therefore cannot install a stale transcript.

## Native Read Aloud state machine

Read Aloud is a response action, not a separate voice-conversation screen. It is
offered only while authenticated and online, after TTS capability evidence, for
a persisted, finished assistant message with nonempty visible prose. The speech
projection removes citation markers and Markdown decoration and excludes
reasoning, fenced/typed code, artifacts, tool/activity/error payloads, attachment
transcripts, user/system content, unfinished output, and local optimistic rows.
The resulting text has a stable revision so branch, edit, regenerate, and history
replacement cannot leave audio attached to stale content.

```text
idle
  → preparing exact message revision
  → playing
  ↔ paused / interrupted
  → completed or stopped
  → failed (explicit retry only when meaningful)
```

The message context menu and VoiceOver actions use the same semantic operation.
They also expose **Choose reading voice**, while the active compact player shows
the current choice and opens the same item-driven native sheet. The sheet owns
loading, retry, draft selection, save, and dismissal; every row is a native
44-point action with selected-state accessibility. While active, the compact
composer-adjacent status capsule exposes progress, pause/resume, stop, explicit
retry, and the voice entry point. A process-wide `AppAudioSessionCoordinator`
serializes recording and spoken playback across scenes; a second recorder/player
cannot silently replace the current system audio mode. Starting a different
response stops the first. Leaving the chat, changing the message revision, or
making the scene inactive cancels reception, releases in-memory audio, and stops
playback. Version 1 is foreground-only and does not advertise lock-screen or
background continuation.

Manual synthesis uses `.never` transport retry. A 401 may perform the existing
single refresh-and-replay before provider work begins; transport loss, malformed
audio, 429, and 5xx never trigger an automatic repost. The failure copy explains
when an explicit retry may repeat provider work. No synthesized bytes, source
text, raw request, or playback record is stored in SwiftData or logged.

The separate `POST /api/files/speech/tts` route is automatic assistant-output
streaming keyed by message/run IDs. It is not a full-duplex or bidirectional voice
protocol and is intentionally not used by this slice. Captions, barge-in,
conversation mode, background audio, remote controls, and full-duplex voice remain
separate work.

## Verification and remaining work

The final package evidence is **350 Swift Testing tests across 43 suites plus 4 XCTest checks (354 package checks)** at [`/private/tmp/librechat-visual-audit-core`](/private/tmp/librechat-visual-audit-core). The complete app unit/model/repository target passed **371/371** at [`/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult`](/private/tmp/LibreChatIOS-AccessibilityFullUnit-20260819.xcresult), and generic Simulator/iOS 17 device builds passed. The separate 7/7 UI suite does not exercise speech. No microphone or audio output was used and no authenticated live network/provider acceptance was performed.

Contract coverage includes authenticated config mapping, legacy capability
decoding, exact multipart fields/headers/body, optional language omission,
filename/MIME/size validation, nonempty transcript mapping, permission policy,
server-disabled preflight, one-shot transcription, explicit-only retry after a
lost response, inactive-scene discard, and draft merge behavior. TTS coverage adds
safe preference mapping, exact manual multipart and voices contracts, no-retry
policy, binary content validation, assistant-prose projection, unsupported/401/
lost-response behavior, one-player replacement, pause/resume/stop, content-revision
fencing, scene-inactive cleanup, completion reset, opaque voice selection,
removed-voice fallback, exact catalog admission, namespace isolation, on-disk
reopen, and purge. The eleven app model/player/preference tests compiled in the
iOS bundle but did not execute.

Current evidence is package and compile evidence. A real device is required to
prove microphone permission, audio-session interruption/route behavior, actual
M4A encoding, audible playback, VoiceOver/Dynamic Type, and server/provider
behavior. Automatic/streaming playback, captions, background audio, remote
controls, and a full-duplex voice session remain separate, unimplemented
capabilities. Voice-list loading, selection persistence, largest Dynamic Type,
and VoiceOver still require runtime acceptance.
