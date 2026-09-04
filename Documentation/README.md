# LibreChat iOS product knowledge

This directory is the working product and protocol memory for the native LibreChat app. It exists to keep implementation decisions grounded in evidence instead of rediscovering the same backend behavior or copying a competitor screen by screen.

## Evidence rules

1. **LibreChat source is authoritative for protocol behavior.** The deployment audited for this project reports commit `b2128a7d189ac020ebb6e49a57ee986e98326b77`. Source references in `LibreChatKnowledge/` target that exact commit unless a document says otherwise.
2. **The live server is authoritative for enabled capability.** Source proves what the build can do; `/api/config`, `/api/endpoints`, `/api/models`, authenticated discovery, permissions, and generation negotiation prove what this account may do.
3. **Competitive product claims have an evidence class.** A captured, inspected product screen is direct audit evidence. Official documentation is research. A design recommendation derived from either is an inference. These are never conflated.
4. **The native app does not mirror TypeScript types as its domain.** Transport DTOs follow server contracts; domain models describe stable user-facing concepts.
5. **Unknown is not unsupported.** Capability uncertainty triggers safe discovery or negotiation. Only explicit evidence disables a feature.
6. **Server state is authoritative.** Local persistence is a namespaced cache, recovery journal, and draft store—not a second source of truth.

## Current verification boundary

The 2026-08-19 verification passed **367 Swift Testing tests across 44 suites plus 4 XCTest checks (371 package checks)** at [`/private/tmp/librechat-skill-management-core`](/private/tmp/librechat-skill-management-core). Generic physical-device and Simulator build-for-testing passed at [`/private/tmp/LibreChatIOS-SkillManagement-Device-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Device-Derived) and [`/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived`](/private/tmp/LibreChatIOS-SkillManagement-Simulator-Derived). **126 newer app/model/repository tests** compile but have not executed because no Simulator was booted; no UI tests ran and no authenticated live server call occurred. The newest slice adds live-only native account Skill activation with ambiguity reconciliation; live interaction remains pending.

Native attachments now have one composer menu for Photo Library, full-screen camera capture, and Files. Camera permission/availability is checked before presentation and denied access offers Settings. Camera and Photo Library images are always decoded through the orientation-normalizing, metadata-free JPEG encoder capped at 4096px with `.88` quality; advertised `clientImageResize` may then apply an additional server-configured resize/quality step. Arbitrary HEIC/PNG bytes are never relabelled as JPEG. Dimensioned non-Assistants images use `/api/files/images`, Assistants/non-images use `/api/files`, and upload acknowledgement binds the client UUID to `temp_file_id` while retaining the server `file_id`. One owner-scoped reconciliation handles lost/5xx/malformed acknowledgements; unresolved delivery becomes `deliveryUncertain` with blind retry disabled, while the user-facing Check performs only that GET reconciliation and never reposts bytes. Native speech now fetches authenticated capability evidence, records bounded temporary M4A, sends exact no-retry multipart STT, projects only finished visible assistant prose into exact no-retry manual TTS, arbitrates recording/playback through one process-wide audio lease, exposes foreground pause/resume/stop without caching audio, and persists a validated server-backed reading voice per profile/account. This is compile/package evidence only; microphone/provider/audible-playback/voice-picker behavior, automatic/streaming TTS, background/full-duplex voice, live camera/upload, image-detail, background URLSession, and app-test execution remain pending.

This snapshot package-tests steering observation/recovery, exact v2 steer/cancel/arm request paths, stable `clientSteerId`, full-handle/profile/account/epoch fences, no-automatic-retry finite ambiguity, authoritative preempt downgrade, queued/replayed/settled/leftover projections, durable terminal leftovers, and the FIFO exact-handle lane. Pending chips expose cancel/apply-sooner actions, while a one-shot Guide Response sheet and uncertain-operation lock have executed model/presentation coverage. Phase C package-tests a V2 SwiftData queue journal/migration, exact completed-signal/authoritative-graph/target proof, reserve-before-POST, durable reserve/commit transitions without synthetic handles, ambiguity lock/no repost, atomic blocking on 4xx/429/conflict/handoff, explicit retained-status reconciliation, attachment identity freezing, and jobless delivered-without-epoch blocking. The app invokes reconciliation during restoration, foreground, and connectivity recovery; ChatModel queues text and completed same-target attachments, transfers/restores durable upload ownership, chains one follower after exact clean completion, blocks unsafe followers, and presents keep/send-next/server-confirmed-dismiss terminal-leftover choices. Temporary Chat now has a separate [retention and native privacy contract](LibreChatKnowledge/TemporaryChat.md): exact authenticated config plus role gating, generation/upload propagation, history exclusion, local cache purge, and truthful in-chat disclosure are implemented; its newest app regressions are compile-only. File-bearing terminal recovery, quotes, skills, new-chat queueing, background initiation, and live acceptance remain absent. The complete app unit/model/repository target passed 371/371; the deterministic UI target passed 7/7; authenticated live acceptance remains pending. See the [source baseline](LibreChatKnowledge/SourceBaseline.md), [steering contract](LibreChatKnowledge/SteeringQueuesAndBranchActions.md), and [traceability matrix](TraceabilityMatrix.md) for the exact boundary.
Terminal-leftover discard is exact: only a matching server response with `removed:true` acknowledges local recovery ownership. False, missing, unauthorized, conflicting, or ambiguous responses preserve the local row; acknowledgement never implies resend or drain.

The combined workspace also package-tests the authoritative `TargetCatalogSnapshot` mapping contract. New Chat refreshes authenticated configuration/endpoints/models and ACL/key evidence, fails closed on refresh errors, and never silently replaces a selection removed by policy. Its recent target is a validated 1...2,048 UTF-16-unit option ID in the existing account-scoped `recent-chat-target-v1` configuration payload; a fresh catalog uses it only if the option still exists, and New Chat writes it only after successfully creating a local draft. This adds no SwiftData V1 column or migration. Existing chats require authoritative conversation routing and history before send; uploads require authoritative routing. Cached browsing and local drafts remain available on failure, and canonical identity promotion triggers a refetch. `GenerationRecoveryRecord.isTerminal` is retained because it is part of the shipped V1 model checksum; recovery logic still decodes the snapshot blob for authoritative terminal state. Removing that compatibility column prevents existing stores from reaching the V1-to-V2 migration.

The capability-gated Agents library is permission aware. Browsing and Start Chat retain the view-safe ACL boundary. Authenticated-online `AGENTS.USE + CREATE` proof unlocks basic private creation after a fresh `/api/models` reviewed provider/model check, as well as metadata-only edit, server-side duplicate, safe version-history review/revert, and deletion. Basic creation is a strict allowlisted one-shot `POST /api/agents`, confirmed only by a generated-ID/request-echo `201`; one owner GET handles ambiguity before a finite no-repost lock. It excludes tools, actions, files, MCP, skills, subagents, credentials, avatar, and sharing/ACL data. Expanded/version payloads are immediately projected to safe metadata; original version-array indices remain exact; public agent IDs remain distinct from Mongo ACL resource IDs; `.never` mutation 401/browser-redirect responses are never automatically replayed, while GET/idempotent auth recovery remains available. Advanced/full configuration, avatar, action/tool, and sharing/ACL management remain absent. No authenticated Agents flow has executed. See [Saved-agent management](LibreChatKnowledge/SavedAgentManagement.md).

The native Memory center is gated by both authenticated feature evidence and the exact role permission set. Package tests cover personal/agent partitions, legacy user/role decoding, UTF-16 limits, exact non-retried request contracts, and strict acknowledgement mapping; repository/model tests compile in the app bundle. Private memory values remain live-only and are never cached or logged. Authenticated Memory CRUD/preference, offline, permission, VoiceOver, and Dynamic Type acceptance remain pending.

Prompt handling is a live-only private-resource boundary. The composer library appears only after authenticated `PROMPTS.USE` evidence, browses the ACL-filtered production-group cursor, revision-fences search/paging, expands supported variables locally, and appends into—not over—the editable draft without sending. Settings separately requires `USE` plus `CREATE` and manages the owned-category metadata and version set: create, add version, edit metadata, and explicit production promotion are wired with exact identity checks, no automatic mutation retries, and ambiguity locks/reconciliation. Prompt contents are not cached or logged. Delete, labels, sharing/ACL administration, and authenticated/accessibility acceptance remain pending; see [Prompts and templates](LibreChatKnowledge/PromptsAndTemplates.md).

HITL safety now rejects response, Stop, and stream operations for a foreign profile/account handle before networking; preserves each typed tool item and decision; requires a non-retried resume acknowledgement with exact conversation, stream, `status:"resuming"`, and negotiated protocol; clears terminal interactions; and treats fatal stream failures as non-retriable. Ambiguous resume outcomes reconcile exact state and never blindly repost. External-auth URLs are actionable only over HTTPS or loopback HTTP. The direct tool-approval body, ownership, acknowledgement, and app repository fixtures passed in the complete 371/371 app test run; pending interaction drafts are still view-lifetime only and authenticated live proof remains pending.

Message-tree navigation is now explicit and client-local: the server's sibling order is authoritative, the default projection chooses the last child at each level, send/share target the exact selected projected tail, and duplicate/missing/self-parent/cycle anomalies fail closed. Root sentinels (`nil`, zero UUID, `NO_PARENT`) normalize to the root. A native conversation-actions menu copies or system-shares only the selected visible branch as privacy-bounded Markdown, and individual message actions copy cleaned visible text; hidden identifiers, target metadata, files, and tool payloads are omitted. Save-only message editing is implemented behind exact `(profile, account, conversation, message, raw part index/kind)` coordinates: it uses `{text}` or `{text,index}`, never automatically retries, reconciles an ambiguous outcome against the exact authoritative coordinate, installs the complete history on success, and never generates a new answer. The sheet remains open on failure and warns that the server has no compare-and-swap revision. Bounded response regeneration is a separate one-shot sheet for a selected persisted finished plain-text assistant/direct-user pair; it verifies exact branch/target identity, resumable v2 and idle status, sends exact wire coordinates with stable request identity, preserves the original subtree, proves a new assistant sibling, excludes attachments/skills/quotes/rich/citations/artifacts, and fails closed without repost on ambiguity. Assistant resubmit, Continue, and server branch actions remain separate future work.
Whole-conversation duplication is available from the visible conversation-row overflow menu and the existing context action. It performs authoritative nonempty source/history preflight, submits exactly one non-retried `POST /api/convos/duplicate`, requires fresh conversation/message identities and a valid remapped tree, caches the returned copy, and navigates to it. A transport/5xx/cancellation/malformed-success outcome is deliberately locked until explicit list refresh because the server exposes no idempotency key or unique reconciliation coordinate. This flow is package- and build-verified, not runtime/live-proven.

Text-only prompt edit-and-resubmit is a separate native branch action. It is offered only for the selected persisted authoritative user prompt with exactly one primary plain-text slot and no attachments, rich content, artifacts, or citations. The original prompt and replies remain unchanged; ordinary generation creates a sibling under the exact original parent with stable validated caller IDs. Admission requires verified resumable v2 and an authoritative idle preflight, with model/UI fences against stale graph or operation state. Ambiguous starts are never blindly reposted; a losing handoff never attributes the winner. Accepted streaming/terminal outcomes focus the new branch or reload authoritative history; 401 hides cached history. Regenerate, Continue, assistant resubmit, and direct-path fork remain distinct; broader fork modes remain deferred.

Response regeneration is implemented separately for a selected persisted finished plain-text assistant that is the direct child of the exact user source. The action verifies the authoritative branch and target fingerprint, resumable v2, and idle status; sends exact source/override-parent/preliminary-response coordinates with stable request identity and retry semantics; preserves the original subtree while creating an assistant sibling; excludes attachments, skills, quotes, rich content, citations, and artifacts; shows the current target; rejects ambiguity without reposting; proves the exact new sibling for settled/failed outcomes; never attributes a typed losing handoff; hides history on 401; and uses a one-shot sheet/review lock. Continue, assistant resubmit, and direct-path fork remain distinct; broader fork modes remain deferred.

Direct-path conversation fork is now a separate one-shot native review/navigation action over `POST /api/convos/fork`. Before transport, the repository performs authoritative source-conversation/message preflight and rejects invalid parent graphs; the original conversation remains unchanged and the fork uses fresh identities. The request uses `.never` retry, distinguishes typed preflight failures from delivery ambiguity, and does not reclassify a cache-after-success failure as a failed fork. The action is available only for the `directPath` mode; `includeBranches`, `targetLevel`, and `splitAtTarget` remain unimplemented or unproven. App presentation tests and the deterministic one-shot review/cancel XCUITest executed; live network acceptance remains pending.

## Library

### Competitive product research

- [ChatGPT audit and research](Audits/ChatGPT.md)
- [Claude audit and research](Audits/Claude.md)
- [Gemini, Perplexity, Copilot, Poe, Grok, and DeepSeek scan](Audits/OtherMajorAIApps.md)
- [Competitive native visual capture audit (2026-08-18)](ProductDesign/CompetitiveVisualAudit-2026-08-18.md)
- [Screenshot-led competitive native visual audit (2026-08-19)](ProductDesign/CompetitiveVisualAudit-2026-08-19.md)

The initial competitive pass was capture-blocked because no controllable browser surface was available. A later pass captured and inspected eighteen current first-party Apple promotional frames across ChatGPT, Claude, Gemini, Perplexity, Poe, and Grok. Those images support visible hierarchy comparisons only; no authenticated competitor flow, motion, accessibility behavior, or iPad adaptation is claimed. Microsoft Copilot was excluded after its consumer listing returned an error in both attempted storefronts.

### LibreChat protocol and product behavior

- [Privacy-safe live acceptance runbook](LiveAcceptanceRunbook.md)
- [Authentication and onboarding](LibreChatKnowledge/AuthenticationAndOnboarding.md)
- [Account profile, avatar, and self-deletion](LibreChatKnowledge/AccountProfileAndDeletion.md)
- [User-provided provider credentials](LibreChatKnowledge/UserProvidedProviderCredentials.md)
- [Generation protocol v2](LibreChatKnowledge/GenerationProtocolV2.md)
- [Steering, queued follow-ups, and branch actions](LibreChatKnowledge/SteeringQueuesAndBranchActions.md)
- [Conversations, messages, and files](LibreChatKnowledge/ConversationsMessagesAndFiles.md)
- [Owner file catalog and native Files library](LibreChatKnowledge/FileCatalogAndLibrary.md)
- [Presets and native application](LibreChatKnowledge/PresetsAndNativeApplication.md)
- [Speech and native voice input](LibreChatKnowledge/SpeechAndVoice.md)
- [Message feedback](LibreChatKnowledge/MessageFeedback.md)
- [Conversation tags, bookmarks, and permissions](LibreChatKnowledge/ConversationTagsBookmarksAndPermissions.md)
- [Memories and personalization](LibreChatKnowledge/MemoriesAndPersonalization.md)
- [Prompts and templates](LibreChatKnowledge/PromptsAndTemplates.md)
- [Shared links and public snapshots](LibreChatKnowledge/SharingAndPublicSnapshots.md)
- [Citations, artifacts, code output, Mermaid, and UI resources](LibreChatKnowledge/CitationsArtifactsAndInteractiveContent.md)
- [Capabilities, agents, and advanced features](LibreChatKnowledge/CapabilitiesAgentsAndAdvancedFeatures.md)
- [Skills and manual invocation](LibreChatKnowledge/SkillsAndManualInvocation.md)
- [Saved-agent management](LibreChatKnowledge/SavedAgentManagement.md)
- [Source and capability baseline](LibreChatKnowledge/SourceBaseline.md)
- [Native client gap matrix](LibreChatKnowledge/NativeClientGapMatrix.md)
- [Product/protocol/implementation traceability matrix](TraceabilityMatrix.md)

### Product direction

- [Competitive synthesis and product principles](ProductDesign/CompetitiveSynthesis.md)
- [Native AI product design decision framework](ProductDesign/DesignDecisionFramework.md)
- `ProductDesign/InteractionArchitecture.md` — to be produced after the source audits converge.
- `ProductDesign/VisualDirections.md` — exactly three visual directions will be produced before the SwiftUI shell is redesigned.
- `ProductDesign/DecisionLog.md` — durable design choices, alternatives, and evidence.

## Maintenance rhythm

Update this library when any of these happen:

- the live server commit changes;
- generation negotiation returns a new protocol version or mismatch;
- `/api/config`, `/api/endpoints`, or `/api/models` changes shape;
- a route produces an unrecognized response or event;
- the native client adds a capability;
- a competitive product is directly recaptured;
- a visual direction is selected or rejected.

Every implementation PR or working session should be able to answer:

1. Which user outcome does this change improve?
2. Which live capability or source contract enables it?
3. What is the offline/recovery behavior?
4. What happens when the server does not support it?
5. What does VoiceOver announce and what happens at large Dynamic Type?
6. What evidence proves the interaction works in Simulator and against a real deployment?
