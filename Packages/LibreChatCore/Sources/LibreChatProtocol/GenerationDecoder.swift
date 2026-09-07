import Foundation
import LibreChatDomain

public struct LibreChatGenerationDecoder: Sendable {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    /// Extracts a citation attachment from either standard `attachment` SSE
    /// data or a Responses `librechat:attachment` wrapper. Callers use this
    /// alongside `decode(_:conversationID:)` and feed the result into the
    /// same `CitationAttachmentReducer` used for history attachments.
    public func citationAttachment(from event: ServerSentEvent) -> CitationAttachment? {
        guard let data = event.data.data(using: .utf8),
              let root = try? decoder.decode(JSONValue.self, from: data),
              let object = root.objectValue else { return nil }
        if object["type"]?.stringValue == "librechat:attachment" {
            return try? LibreChatCitationAttachmentDTO.generationAttachment(from: root)
        }
        let eventName = object["event"]?.stringValue ?? event.event
        guard eventName == "attachment" else { return nil }
        let payload = normalizedObject(object["data"]) .map(JSONValue.object) ?? root
        return try? LibreChatCitationAttachmentDTO.generationAttachment(from: payload)
    }

    /// Extracts a generated output attachment from either the legacy
    /// `attachment` event or the Responses `librechat:attachment` wrapper.
    /// Citation attachments deliberately remain on their own typed path.
    public func generatedFileAttachment(from event: ServerSentEvent) -> GeneratedFile? {
        guard let data = event.data.data(using: .utf8),
              let root = try? decoder.decode(JSONValue.self, from: data),
              let object = root.objectValue else { return nil }
        let eventName = object["event"]?.stringValue ?? event.event
        guard object["type"]?.stringValue == "librechat:attachment" || eventName == "attachment" else {
            return nil
        }
        let payload: JSONValue
        if object["type"]?.stringValue == "librechat:attachment" {
            payload = root
        } else {
            payload = normalizedObject(object["data"]).map(JSONValue.object) ?? root
        }
        guard LibreChatGeneratedFileDTO.canDecode(payload) else { return nil }
        return try? LibreChatGeneratedFileDTO.generationAttachment(from: payload)
    }

    public func synchronizationEvent(from status: GenerationStatusDTO) -> SequencedGenerationEvent? {
        var object = status.resumeState?.objectValue ?? [:]
        if object["aggregatedContent"] == nil, let aggregatedContent = status.aggregatedContent {
            object["aggregatedContent"] = .array(aggregatedContent)
        }
        if object["pendingAction"] == nil, let pendingAction = status.pendingAction {
            object["pendingAction"] = pendingAction
        }
        guard !object.isEmpty || status.unrecoveredSteers?.isEmpty == false else { return nil }
        var synchronization = sync(
            from: object,
            fallbackConversationID: status.streamID.map(ConversationID.init(rawValue:))
        )
        synchronization.recoverableSteers = pendingSteers(from: status.unrecoveredSteers ?? [])
        return SequencedGenerationEvent(event: .synchronization(synchronization))
    }

    /// Converts terminal parked-steer projections from status/abort responses
    /// into the same idempotent reducer signal used by FINAL frames.
    public func recoverableSteersEvent(from values: [JSONValue]?) -> SequencedGenerationEvent? {
        guard let values else { return nil }
        let steers = pendingSteers(from: values)
        return SequencedGenerationEvent(event: .recoverableSteers(steers))
    }

    public func decode(_ event: ServerSentEvent, conversationID: ConversationID) -> [SequencedGenerationEvent] {
        if event.event == "error" {
            return [SequencedGenerationEvent(
                id: event.id,
                event: .failed(GenerationFailure(
                    code: "server_stream_error",
                    message: message(from: event.data) ?? "LibreChat ended the response with an error.",
                    isRecoverable: true
                ))
            )]
        }
        if event.data == "[DONE]" {
            return [SequencedGenerationEvent(id: event.id, event: .completed)]
        }
        guard let data = event.data.data(using: .utf8),
              let root = try? decoder.decode(JSONValue.self, from: data),
              let object = root.objectValue else {
            return []
        }

        var result: [SequencedGenerationEvent] = []
        func append(_ value: GenerationEvent) {
            let sequenceID = event.id.map { result.isEmpty ? $0 : "\($0)#\(result.count)" }
            result.append(SequencedGenerationEvent(id: sequenceID, event: value))
        }

        if object["created"]?.boolValue == true {
            let message = object["message"].flatMap { decodeMessage($0, conversationID: conversationID) }
            append(.created(message))
        }

        if let lifecycle = lifecycle(from: object["status"]?.stringValue ?? object["type"]?.stringValue) {
            append(.lifecycle(lifecycle))
        }

        if object["sync"]?.boolValue == true,
           let resumeState = object["resumeState"]?.objectValue {
            append(.synchronization(sync(from: resumeState, fallbackConversationID: conversationID)))
            for replayEvent in resumeState["replayEvents"]?.arrayValue ?? [] {
                guard let replayData = try? JSONEncoder().encode(replayEvent) else { continue }
                let replaySSE = ServerSentEvent(data: String(decoding: replayData, as: UTF8.self))
                result.append(contentsOf: decode(replaySSE, conversationID: conversationID))
            }
            for pendingEvent in object["pendingEvents"]?.arrayValue ?? [] {
                guard let pendingData = try? JSONEncoder().encode(pendingEvent) else { continue }
                let pendingSSE = ServerSentEvent(data: String(decoding: pendingData, as: UTF8.self))
                result.append(contentsOf: decode(pendingSSE, conversationID: conversationID))
            }
        }

        let eventName = object["event"]?.stringValue ?? event.event
        let eventData = normalizedObject(object["data"]) ?? object
        if object["type"]?.stringValue == "librechat:attachment" {
            if let attachment = try? LibreChatCitationAttachmentDTO.generationAttachment(from: root) {
                append(.citationAttachment(attachment))
            } else if LibreChatGeneratedFileDTO.canDecode(root),
                      let generated = try? LibreChatGeneratedFileDTO.generationAttachment(from: root) {
                append(.attachment(.generatedFile(generated)))
            }
        } else if eventName == "on_message_delta",
           let delta = eventData["delta"]?.objectValue,
           let text = delta["content"]?.textValue(), !text.isEmpty {
            append(.textDelta(text))
        } else if eventName?.localizedCaseInsensitiveContains("reasoning") == true,
                  let text = eventData["delta"]?.textValue()
                    ?? object["delta"]?.textValue(), !text.isEmpty {
            append(.reasoningDelta(text))
        } else if eventName == "on_subagent_update",
                  let activity = subagentActivity(from: eventData) {
            append(.activity(activity))
        } else if eventName == "on_activity_label"
                    || eventName == "on_agent_update",
                  let activity = activity(from: eventData, eventName: eventName) {
            append(.activity(activity))
        } else if eventName == "attachment" {
            if let citation = try? LibreChatCitationAttachmentDTO.generationAttachment(from: .object(eventData)) {
                append(.citationAttachment(citation))
            } else if LibreChatGeneratedFileDTO.canDecode(.object(eventData)),
                      let generated = try? LibreChatGeneratedFileDTO.generationAttachment(from: .object(eventData)) {
                append(.attachment(.generatedFile(generated)))
            } else if let attachment = LibreChatMessageDTO.domainAttachment(.object(eventData)) {
                append(.attachment(attachment))
            }
        } else if eventName == "title",
                  let title = eventData["title"]?.stringValue, !title.isEmpty {
            append(.title(title))
        } else if eventName == "on_context_usage",
                  let context = contextUsage(from: eventData) {
            append(.contextUsage(context))
        } else if eventName?.localizedCaseInsensitiveContains("run_step") == true,
                  let step = runStep(from: eventData) {
            append(.runStep(step))
        } else if eventName?.localizedCaseInsensitiveContains("tool") == true,
                  let call = toolCall(from: eventData) {
            append(.toolCall(call))
        } else if eventName == "on_steer_applied",
                  let steer = appliedSteer(from: eventData, fallbackConversationID: conversationID) {
            append(.steer(steer))
        } else if eventName == "on_steer_updated" {
            for update in pendingSteerUpdates(from: eventData) {
                append(.pendingSteerUpdate(update))
            }
        }

        if let pending = pendingInteraction(from: object["pendingAction"] ?? object["pending_action"]) {
            append(.pendingInteraction(pending))
        }
        let usageValue = object["usage"]
            ?? eventData["usage"]
            ?? (eventName == "on_token_usage" ? .object(eventData) : nil)
        if let usage = usage(from: usageValue) {
            append(.usage(usage))
        }

        if object["final"]?.boolValue == true {
            if let response = object["responseMessage"].flatMap({ decodeMessage($0, conversationID: conversationID) }),
               !response.content.isEmpty {
                append(.replaceContent(response.content))
            } else if let text = object["responseMessage"]?.textValue(), !text.isEmpty {
                append(.replaceContent([.text(text)]))
            }

            if let pendingSteerValues = object["pendingSteers"]?.arrayValue {
                let leftovers = pendingSteers(from: pendingSteerValues)
                append(.recoverableSteers(leftovers))
            }

            if object["reconcile"]?.boolValue == true {
                append(.terminal(.reconciliationRequired(
                    reason: object["reconcileReason"]?.stringValue ?? object["code"]?.stringValue
                )))
            } else if object["aborted"]?.boolValue == true
                        || object["responseMessage"]?.objectValue?["unfinished"]?.boolValue == true {
                append(.terminal(.unfinished))
            } else if hasError(object["error"])
                        || hasError(object["responseMessage"]?.objectValue?["error"]) {
                append(.failed(GenerationFailure(
                    code: object["code"]?.stringValue ?? "generation_terminal_error",
                    message: errorText(object["error"])
                        ?? errorText(object["responseMessage"]?.objectValue?["error"])
                        ?? "LibreChat could not complete this response.",
                    isRecoverable: true
                )))
            } else {
                append(.terminal(.completed))
            }
        } else if result.isEmpty,
                  let text = object["text"]?.stringValue ?? object["response"]?.stringValue,
                  !text.isEmpty {
            append(.replaceContent([.text(text)]))
        }

        if result.isEmpty {
            append(.unsupported(kind: eventName ?? object["type"]?.stringValue ?? "unknown"))
        }
        return result
    }

    private func decodeMessage(_ value: JSONValue, conversationID: ConversationID) -> ChatMessage? {
        guard let data = try? JSONEncoder().encode(value),
              let dto = try? decoder.decode(LibreChatMessageDTO.self, from: data) else { return nil }
        return try? dto.domainModel(defaultConversationID: conversationID)
    }

    private func lifecycle(from value: String?) -> GenerationLifecycle? {
        guard let value else { return nil }
        return GenerationLifecycle(rawValue: value)
    }

    private func sync(
        from object: [String: JSONValue],
        fallbackConversationID: ConversationID? = nil
    ) -> GenerationSync {
        let rawAggregatedContent = object["aggregatedContent"]?.arrayValue ?? []
        let aggregatedContent: [MessageContent]
        if !rawAggregatedContent.isEmpty {
            aggregatedContent = LibreChatMessageDTO.domainContent(from: rawAggregatedContent)
        } else if let text = object["aggregatedContent"]?.textValue(), !text.isEmpty {
            aggregatedContent = [.text(text)]
        } else {
            aggregatedContent = []
        }
        let runSteps = object["runSteps"]?.arrayValue?.compactMap { $0.objectValue.flatMap(runStep(from:)) } ?? []
        let toolCalls = object["toolCalls"]?.arrayValue?.compactMap { $0.objectValue.flatMap(toolCall(from:)) } ?? []
        let activities = aggregatedContent.compactMap { content -> MessageActivityContent? in
            switch content {
            case let .activity(activity):
                return activity
            case let .tool(call):
                guard let trace = call.subagentTrace else { return nil }
                return MessageActivityContent(
                    id: "subagent:\(subagentActivityKey(call.id))",
                    label: "Agent finished",
                    status: "stop",
                    isPending: false,
                    subagent: SubagentActivityMetadata(
                        phase: .completed,
                        toolNames: trace.toolNames,
                        hasProducedText: trace.hasResponseText,
                        hasProducedReasoning: trace.hasReasoning
                    )
                )
            default:
                return nil
            }
        }
        let conversationID = object["conversationId"]?.stringValue
            .map(ConversationID.init(rawValue:)) ?? fallbackConversationID
        let responseMessageID = object["responseMessageId"]?.stringValue.map(MessageID.init(rawValue:))
        let appliedSteers = rawAggregatedContent.enumerated().compactMap { index, value in
            appliedSteer(
                fromContentPart: value.objectValue,
                index: index,
                responseMessageID: responseMessageID,
                conversationID: conversationID
            )
        }
        return GenerationSync(
            aggregatedContent: aggregatedContent,
            runSteps: runSteps,
            toolCalls: toolCalls,
            activities: activities,
            pendingInteraction: pendingInteraction(from: object["pendingAction"]),
            usage: usage(from: object["usage"]),
            contextUsage: object["contextUsage"]?.objectValue.flatMap(contextUsage(from:)),
            appliedSteers: appliedSteers,
            pendingSteers: pendingSteers(from: object["pendingSteers"]?.arrayValue ?? []),
            title: object["title"]?.stringValue,
            isComplete: object["isComplete"]?.boolValue ?? object["settled"]?.boolValue ?? false
        )
    }

    private func activity(
        from object: [String: JSONValue],
        eventName: String?
    ) -> MessageActivityContent? {
        let part = object["part"]?.objectValue ?? object
        let label = part["activity_label"]?.stringValue
            ?? part["label"]?.stringValue
            ?? object["message"]?.stringValue
            ?? part["message"]?.stringValue
        guard let label, !label.isEmpty else {
            if part["pending"]?.boolValue == true {
                return MessageActivityContent(
                    id: object["index"]?.intValue.map(String.init)
                        ?? object["runId"]?.stringValue
                        ?? eventName
                        ?? "activity",
                    label: "Working",
                    status: part["status"]?.stringValue,
                    isPending: true,
                    agentID: part["agent_id"]?.stringValue
                )
            }
            return nil
        }
        return MessageActivityContent(
            id: part["id"]?.stringValue
                ?? object["runId"]?.stringValue
                ?? object["index"]?.intValue.map(String.init)
                ?? "\(eventName ?? "activity"):\(label)",
            label: label,
            status: part["status"]?.stringValue ?? object["status"]?.stringValue,
            isPending: part["pending"]?.boolValue ?? false,
            agentID: part["agent_id"]?.stringValue ?? object["agentId"]?.stringValue
        )
    }

    /// Maps LibreChat's child-agent envelope into a deliberately bounded
    /// activity signal. The nested `data` object may contain streamed child
    /// text/reasoning and complete tool arguments/output; none of those raw
    /// values cross this boundary.
    private func subagentActivity(
        from object: [String: JSONValue]
    ) -> MessageActivityContent? {
        guard let rawRunID = object["subagentRunId"]?.stringValue,
              let runID = rawRunID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let parentToolCallID = object["parentToolCallId"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let rawPhase = object["phase"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phase: SubagentActivityPhase = switch rawPhase {
        case "start": .started
        case "run_step": .runningStep
        case "run_step_delta": .updatingStep
        case "run_step_completed": .completedStep
        case "message_delta": .writing
        case "reasoning_delta": .reasoning
        case "stop": .completed
        case "error": .failed
        default: .unknown
        }

        let nested = object["data"]?.objectValue ?? [:]
        let toolNames = subagentToolNames(from: nested)
        let typeLabel = object["subagentType"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let serverLabel = object["label"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let label = serverLabel ?? subagentFallbackLabel(for: phase, toolNames: toolNames)

        return MessageActivityContent(
            id: "subagent:\(subagentActivityKey(parentToolCallID ?? runID))",
            label: label,
            status: rawPhase,
            isPending: phase != .completed && phase != .failed,
            subagent: SubagentActivityMetadata(
                phase: phase,
                typeLabel: typeLabel,
                toolNames: toolNames,
                hasProducedText: phase == .writing,
                hasProducedReasoning: phase == .reasoning
            )
        )
    }

    /// Produces a deterministic correlation key without retaining the server's
    /// tool-call/run identifier in cached or observable activity state. This
    /// is identity deduplication, not a security or authorization primitive.
    private func subagentActivityKey(_ source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func subagentToolNames(from object: [String: JSONValue]) -> [String] {
        let stepDetails = object["stepDetails"]?.objectValue
            ?? object["result"]?.objectValue?["stepDetails"]?.objectValue
        let calls = stepDetails?["tool_calls"]?.arrayValue
            ?? object["result"]?.objectValue?["tool_call"].map { [$0] }
            ?? []
        var seen: Set<String> = []
        return calls.compactMap { value in
            let call = value.objectValue?["tool_call"]?.objectValue ?? value.objectValue
            guard let raw = call?["name"]?.stringValue,
                  let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private func subagentFallbackLabel(
        for phase: SubagentActivityPhase,
        toolNames: [String]
    ) -> String {
        switch phase {
        case .started: "Agent started"
        case .runningStep, .updatingStep:
            toolNames.first.map { "Using \($0)" } ?? "Agent working"
        case .completedStep: "Agent finished a step"
        case .writing: "Agent preparing a response"
        case .reasoning: "Agent planning"
        case .completed: "Agent finished"
        case .failed: "Agent failed"
        case .unknown: "Agent activity"
        }
    }

    private func contextUsage(from object: [String: JSONValue]) -> ContextUsage? {
        let breakdown = object["breakdown"]?.objectValue ?? object
        let usage = ContextUsage(
            maximumTokens: breakdown["maxContextTokens"]?.intValue,
            messageTokens: breakdown["messageTokens"]?.intValue,
            instructionTokens: breakdown["instructionTokens"]?.intValue,
            remainingTokens: object["remainingContextTokens"]?.intValue
                ?? breakdown["remainingContextTokens"]?.intValue,
            toolCount: breakdown["toolCount"]?.intValue,
            messageCount: breakdown["messageCount"]?.intValue
        )
        guard usage.maximumTokens != nil
                || usage.messageTokens != nil
                || usage.remainingTokens != nil else { return nil }
        return usage
    }

    private func appliedSteer(
        from object: [String: JSONValue],
        fallbackConversationID: ConversationID
    ) -> SteerEvent? {
        let part = object["part"]?.objectValue ?? object
        guard let id = object["steerId"]?.stringValue ?? part["steerId"]?.stringValue else { return nil }
        let messageID = object["responseMessageId"]?.stringValue
            .map(MessageID.init(rawValue:))
            ?? object["messageId"]?.stringValue.map(MessageID.init(rawValue:))
        let conversationID = object["conversationId"]?.stringValue
            .map(ConversationID.init(rawValue:)) ?? fallbackConversationID
        return SteerEvent(
            id: id,
            clientSteerID: object["clientSteerId"]?.stringValue ?? part["clientSteerId"]?.stringValue,
            targetMessageID: messageID,
            conversationID: conversationID,
            contentIndex: object["index"]?.intValue,
            text: part["steer"]?.textValue()
                ?? part["text"]?.textValue()
                ?? part["content"]?.textValue()
                ?? object["text"]?.textValue(),
            createdAt: int64(part["createdAt"] ?? object["createdAt"]),
            files: files(from: part["files"])
        )
    }

    private func appliedSteer(
        fromContentPart object: [String: JSONValue]?,
        index: Int,
        responseMessageID: MessageID?,
        conversationID: ConversationID?
    ) -> SteerEvent? {
        guard let object, object["type"]?.stringValue == "steer",
              let id = object["steerId"]?.stringValue else { return nil }
        return SteerEvent(
            id: id,
            clientSteerID: object["clientSteerId"]?.stringValue,
            targetMessageID: responseMessageID,
            conversationID: conversationID,
            contentIndex: index,
            text: object["steer"]?.textValue()
                ?? object["text"]?.textValue()
                ?? object["content"]?.textValue(),
            createdAt: int64(object["createdAt"]),
            files: files(from: object["files"])
        )
    }

    private func pendingSteers(from values: [JSONValue]) -> [PendingSteer] {
        values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["steerId"]?.stringValue,
                  let text = object["text"]?.textValue() else { return nil }
            return PendingSteer(
                id: id,
                clientSteerID: object["clientSteerId"]?.stringValue,
                text: text,
                createdAt: int64(object["createdAt"]),
                files: files(from: object["files"]),
                preempt: object["preempt"]?.boolValue,
                preemptRevision: object["preemptRevision"]?.intValue
            )
        }
    }

    private func pendingSteerUpdates(from object: [String: JSONValue]) -> [PendingSteerUpdate] {
        (object["steers"]?.arrayValue ?? []).compactMap { value in
            guard let update = value.objectValue,
                  let id = update["steerId"]?.stringValue,
                  let preempt = update["preempt"]?.boolValue,
                  let revision = update["preemptRevision"]?.intValue else { return nil }
            return PendingSteerUpdate(
                id: id,
                clientSteerID: update["clientSteerId"]?.stringValue,
                preempt: preempt,
                preemptRevision: revision
            )
        }
    }

    private func files(from value: JSONValue?) -> [UploadedFile] {
        (value?.arrayValue ?? []).compactMap { value in
            guard let data = try? JSONEncoder().encode(value),
                  let file = try? decoder.decode(LibreChatFileDTO.self, from: data) else { return nil }
            return try? file.domainModel(fallbackFilename: "Attachment")
        }
    }

    private func int64(_ value: JSONValue?) -> Int64? {
        // Mirror JSONValue.intValue: reject non-finite and out-of-bounds
        // doubles so a hostile steer event cannot trap Int64 conversion.
        guard let double = value?.doubleValue, double.isFinite,
              double >= Double(Int64.min), double <= Double(Int64.max) else {
            return nil
        }
        return Int64(double)
    }

    private func runStep(from object: [String: JSONValue]) -> RunStep? {
        guard let id = object["id"]?.stringValue ?? object["step_id"]?.stringValue else { return nil }
        return RunStep(
            id: id,
            label: object["label"]?.stringValue ?? object["name"]?.stringValue ?? "Agent step",
            isComplete: object["isComplete"]?.boolValue ?? object["completed"]?.boolValue ?? false
        )
    }

    private func toolCall(from object: [String: JSONValue]) -> ToolCall? {
        guard let id = object["id"]?.stringValue ?? object["tool_call_id"]?.stringValue else { return nil }
        let rawStatus = object["status"]?.stringValue ?? "running"
        let status: ToolCall.Status = switch rawStatus {
        case "pending": .pending
        case "requires_action", "awaiting_approval": .awaitingApproval
        case "completed", "complete", "success": .completed
        case "failed", "error": .failed
        default: .running
        }
        let output = serializedText(object["output"])
        return ToolCall(
            id: id,
            name: object["name"]?.stringValue ?? object["tool"]?.stringValue ?? "Tool",
            status: status,
            summary: object["summary"]?.stringValue ?? output,
            duration: object["duration"]?.doubleValue,
            input: serializedText(object["args"] ?? object["arguments"] ?? object["input"]),
            output: output,
            progress: object["progress"]?.doubleValue,
            authorizationURL: (object["auth_url"]?.stringValue
                ?? object["authorization_url"]?.stringValue).flatMap(safeExternalAuthenticationURL),
            subagentTrace: LibreChatMessageDTO.subagentTrace(from: object)
        )
    }

    private func serializedText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.textValue(), !text.isEmpty { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func pendingInteraction(from value: JSONValue?) -> PendingInteraction? {
        guard let object = value?.objectValue else { return nil }
        guard let id = object["actionId"]?.stringValue ?? object["id"]?.stringValue,
              !id.isEmpty else { return nil }
        let payload = object["payload"]?.objectValue ?? object
        let type = payload["type"]?.stringValue ?? object["type"]?.stringValue ?? ""
        if type == "tool_approval" {
            let actionRequests = payload["action_requests"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let reviews = payload["review_configs"]?.arrayValue?.compactMap(\.objectValue) ?? []
            guard !actionRequests.isEmpty,
                  actionRequests.count <= 64,
                  reviews.count == actionRequests.count else { return nil }
            var decisionsByToolCallID: [String: [ToolApprovalDecision]] = [:]
            for review in reviews {
                guard let toolCallID = review["tool_call_id"]?.stringValue,
                      !toolCallID.isEmpty,
                      decisionsByToolCallID[toolCallID] == nil,
                      let rawDecisions = review["allowed_decisions"]?.arrayValue?.compactMap(\.stringValue),
                      !rawDecisions.isEmpty else { return nil }
                let decisions = rawDecisions.compactMap(ToolApprovalDecision.init(rawValue:))
                guard decisions.count == rawDecisions.count,
                      Set(decisions).count == decisions.count else { return nil }
                decisionsByToolCallID[toolCallID] = decisions
            }
            var seenToolCallIDs: Set<String> = []
            let items = actionRequests.compactMap { request -> ToolApprovalItem? in
                guard let toolCallID = request["tool_call_id"]?.stringValue,
                      !toolCallID.isEmpty,
                      seenToolCallIDs.insert(toolCallID).inserted,
                      let name = request["name"]?.stringValue,
                      !name.isEmpty,
                      let rawArguments = request["arguments"],
                      let arguments = serializedArguments(rawArguments),
                      let allowed = decisionsByToolCallID[toolCallID] else { return nil }
                return ToolApprovalItem(
                    id: toolCallID,
                    name: name,
                    arguments: arguments,
                    summary: request["description"]?.stringValue,
                    allowedDecisions: allowed
                )
            }
            guard items.count == actionRequests.count,
                  Set(decisionsByToolCallID.keys) == Set(items.map(\.id)) else { return nil }
            return .toolApproval(ToolApprovalRequest(
                id: id,
                items: items,
                createdAt: pendingActionDate(object["createdAt"]),
                expiresAt: pendingActionDate(object["expiresAt"]),
                streamID: object["streamId"]?.stringValue,
                conversationID: object["conversationId"]?.stringValue.map(ConversationID.init(rawValue:)),
                runID: object["runId"]?.stringValue,
                interruptID: object["interruptId"]?.stringValue
            ))
        }
        if type == "ask_user_question" {
            let question = payload["question"]?.objectValue
            let batch: [[String: JSONValue]]
            if let batchValue = payload["questions"] {
                guard let rawBatch = batchValue.arrayValue,
                      (1...4).contains(rawBatch.count),
                      rawBatch.allSatisfy({ $0.objectValue != nil }) else { return nil }
                batch = rawBatch.compactMap(\.objectValue)
            } else {
                batch = []
            }
            let items = batch.compactMap(questionItem(from:))
            guard batch.isEmpty || (
                items.count == batch.count
                    && Set(items.map(\.id)).count == items.count
            ) else { return nil }
            let displayed = batch.first ?? question
            guard let displayed,
                  let prompt = displayed["question"]?.stringValue,
                  !prompt.isEmpty else { return nil }
            let (labels, values) = questionOptions(from: displayed)
            return .userQuestion(UserQuestion(
                id: id,
                prompt: prompt,
                detail: displayed["description"]?.stringValue,
                options: labels,
                optionValues: values,
                questionIDs: items.map(\.id),
                items: items.isEmpty ? nil : items,
                allowsMultipleSelection: displayed["multiSelect"]?.boolValue,
                createdAt: pendingActionDate(object["createdAt"]),
                expiresAt: pendingActionDate(object["expiresAt"]),
                streamID: object["streamId"]?.stringValue,
                conversationID: object["conversationId"]?.stringValue.map(ConversationID.init(rawValue:)),
                runID: object["runId"]?.stringValue,
                interruptID: object["interruptId"]?.stringValue
            ))
        }
        // The pinned pending-action protocol has no generic browser-auth
        // interrupt. Unknown action kinds stay non-actionable until LibreChat
        // advertises a profile-bound mobile completion contract.
        return nil
    }

    private func serializedArguments(_ value: JSONValue) -> String? {
        if case let .string(text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func pendingActionDate(_ value: JSONValue?) -> Date? {
        guard let raw = value?.doubleValue, raw.isFinite, raw >= 0 else { return nil }
        let seconds = raw >= 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    /// Pending-action URLs are model/server-controlled input that eventually
    /// reaches `openURL`. Keep them to normal web navigation and the narrow
    /// loopback HTTP exception used by local development; custom schemes,
    /// credentials, and fragments never become actionable domain state.
    private func safeExternalAuthenticationURL(_ rawValue: String) -> URL? {
        ToolAuthenticationURLPolicy.validatedURL(from: rawValue)
    }

    private func questionItem(from object: [String: JSONValue]) -> UserQuestionItem? {
        guard let id = object["id"]?.stringValue, !id.isEmpty,
              id.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
              let prompt = object["question"]?.stringValue, !prompt.isEmpty else { return nil }
        let (labels, values) = questionOptions(from: object)
        return UserQuestionItem(
            id: id,
            header: object["header"]?.stringValue,
            prompt: prompt,
            detail: object["description"]?.stringValue,
            options: labels,
            optionValues: values,
            allowsMultipleSelection: object["multiSelect"]?.boolValue == true
        )
    }

    private func questionOptions(from object: [String: JSONValue]) -> ([String], [String: String]) {
        var labels: [String] = []
        var values: [String: String] = [:]
        for option in object["options"]?.arrayValue ?? [] {
            if let value = option.stringValue {
                labels.append(value)
                values[value] = value
            } else if let option = option.objectValue,
                      let label = option["label"]?.stringValue {
                labels.append(label)
                values[label] = option["value"]?.stringValue ?? label
            }
        }
        return (labels, values)
    }

    private func usage(from value: JSONValue?) -> TokenUsage? {
        guard let object = value?.objectValue else { return nil }
        let input = object["input_tokens"]?.intValue ?? object["prompt_tokens"]?.intValue
        let output = object["output_tokens"]?.intValue ?? object["completion_tokens"]?.intValue
        guard input != nil || output != nil else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    private func normalizedObject(_ value: JSONValue?) -> [String: JSONValue]? {
        if let object = value?.objectValue { return object }
        guard let string = value?.stringValue,
              let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode([String: JSONValue].self, from: data)
    }

    private func message(from value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? decoder.decode([String: JSONValue].self, from: data) else {
            return value.isEmpty ? nil : value
        }
        return object["message"]?.stringValue ?? object["error"]?.stringValue
    }

    private func hasError(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if value.boolValue == true { return true }
        if let string = value.stringValue { return !string.isEmpty }
        return value.objectValue != nil
    }

    private func errorText(_ value: JSONValue?) -> String? {
        value?.stringValue
            ?? value?.objectValue?["message"]?.stringValue
            ?? value?.objectValue?["error"]?.stringValue
            ?? value?.objectValue?["text"]?.stringValue
    }
}
