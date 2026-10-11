import Foundation
import MochiAutomation
import MochiCore
import MochiKernel

extension AppModel {
    var controlSocketPath: String { LocalControl.path(forLibraryRoot: store.root) }
    var mcpExecutablePath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mochi-mcp").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("mochi-mcp").path
    }
    var mcpConfigurationAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: mcpExecutablePath)
            && !Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }
    var mcpConfiguration: String {
        (try? MochiTools.encode([
            "mcpServers": ["mochi": ["command": mcpExecutablePath, "env": ["MOCHI_CONTROL_SOCKET": controlSocketPath]]]
        ])) ?? ""
    }
    func configureAutomation() {
        InstanceEvidence.record("automation-configured")
        automation.configure(
            enabled: externalControlEnabled && (!demo || allowDemoAutomation), path: controlSocketPath,
            recheck: { [weak self] in self?.configureAutomation() },
            handler: { [weak self] data in self?.handleControlRequest(data) ?? Data() })
    }
    func executeVoiceTool(_ name: String, arguments: [String: Any], operationID: UUID) throws -> [String: Any] {
        let tool = try MochiTools.validate(name: name, arguments: arguments, origin: .voice)
        if tool.readOnly { return try executeTool(tool, arguments: arguments, origin: .voice) }
        let key = operationID.uuidString + ":" + (try MochiTools.signature(name: name, arguments: arguments))
        if var result = automation.voiceResults[key] {
            result["status"] = "previously_completed"
            result["revision"] = controlRevision
            return result
        }
        if deferredToolAction != nil, automation.scheduledVoiceToolKey == key {
            return ["ok": true, "status": "scheduled_after_reply", "revision": controlRevision]
        }
        automation.voiceToolKey = key
        defer { automation.voiceToolKey = nil }
        let result = try executeTool(tool, arguments: arguments, origin: .voice)
        if result["status"] as? String != "scheduled_after_reply" { automation.voiceResults.insert(result, for: key) }
        return result
    }
    func handleControlRequest(_ data: Data) -> Data {
        var result: [String: Any]
        do {
            guard externalControlEnabled else { throw AppFailure("External control is disabled.") }
            guard data.count <= LocalControl.maxFrame,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let name = object["name"] as? String, let arguments = object["arguments"] as? [String: Any],
                let requestID = object["request_id"] as? String, !requestID.isEmpty, requestID.count <= 300
            else { throw AppFailure("Invalid control request.") }
            let signature = try MochiTools.encode(["name": name, "arguments": arguments])
            if let cached = automation.externalResults[requestID] {
                guard cached.signature == signature else {
                    throw AppFailure("A request ID was reused with different arguments.")
                }
                return cached.response
            }
            do { result = try executeTool(name, arguments: arguments, origin: .external) } catch {
                MochiLog.failure(
                    MochiLog.automation, "External tool \(MochiToolName(rawValue: name)?.rawValue ?? "unknown")", error,
                    level: .info)
                result = MochiTools.error(AppFailure.message(for: error, fallback: "The app action failed."))
            }
            var response = try JSONSerialization.data(withJSONObject: result)
            if response.count > 120000 {
                response = try JSONSerialization.data(
                    withJSONObject: MochiTools.error("Result is too large. Request fewer items."))
            }
            automation.externalResults.insert((signature, response), for: requestID)
            return response
        } catch { result = MochiTools.error(AppFailure.message(for: error, fallback: "Invalid control request.")) }
        return (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
    }

    var controlRevision: String {
        [
            libraryRevision.uuidString, selectedID?.uuidString ?? "none", turn.epoch.uuidString,
            String(practice), String(managerOpen),
            instructionsID?.uuidString ?? "none", templatePresentation?.rawValue ?? "none",
            renameID?.uuidString ?? "none", String(permanentDeleteIDs.count), String(audio.paused),
            playbackFile ?? "none",
        ].joined(separator: ":")
    }
    var automationModal: Bool {
        templatePresentation != nil || practice || managerOpen || instructionsID != nil || renameID != nil
            || !permanentDeleteIDs.isEmpty
    }
    var canOpenConversationInstructions: Bool { !busy && !automationModal }
    func openConversationInstructions(_ id: UUID) {
        guard canOpenConversationInstructions,
            library.conversations.contains(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        instructionsID = id
    }
    @discardableResult func setConversationInstructions(
        _ id: UUID, instructions: String, preferences: ConversationPreferences
    ) -> Bool {
        setConversationInstructions(
            id, instructions: instructions, preferences: preferences,
            characterName: library.conversations.first(where: { $0.id == id })?.characterName)
    }
    /// The settings sheet's save. Oversized legacy instructions are kept unless the user edits them.
    @discardableResult func setConversationInstructions(
        _ id: UUID, instructions: String, preferences: ConversationPreferences, characterName: String?
    ) -> Bool {
        do {
            guard !busy, !practice, !managerOpen, renameID == nil, permanentDeleteIDs.isEmpty,
                let current = library.conversations.first(where: { $0.id == id && !$0.archived && !$0.isDeleted })
            else { throw AppFailure("This conversation cannot be edited right now.") }
            let patch = ConversationSettingsPatch(
                instructions: instructions == current.instructions ? nil : instructions,
                characterName: characterName.map { .set($0) } ?? .clear,
                speed: preferences.speed.map { .set($0) } ?? .clear,
                coaching: preferences.coaching)
            try updateConversationSettings(id, patch)
            error = nil
            return true
        } catch {
            self.error = AppFailure.message(for: error, fallback: "Could not save conversation instructions.")
            return false
        }
    }
    /// The one path that changes a conversation's settings. Callers decide whether a change is allowed now.
    func updateConversationSettings(_ id: UUID, _ patch: ConversationSettingsPatch) throws {
        guard let index = library.conversations.firstIndex(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { throw AppFailure("An active conversation is required.") }
        var candidate = library
        try patch.apply(to: &candidate.conversations[index])
        do { try commitLibraryCandidate(candidate) } catch {
            throw AppFailure(
                verbatim: persistenceMessage(
                    error, action: "Save conversation settings",
                    fallback: "The settings could not be saved. Nothing was changed.",
                    diskFull: "The settings could not be saved because the disk is full. Nothing was changed."),
                underlying: error)
        }
    }
    func executeTool(_ name: String, arguments: [String: Any], origin: ToolOrigin) throws -> [String: Any] {
        try executeTool(
            MochiTools.validate(name: name, arguments: arguments, origin: origin), arguments: arguments, origin: origin)
    }
    /// `items` in order while their serialized size fits `budget`. `make` builds an item whose texts are bounded
    /// by a byte allowance; the first item is shortened to fit when it does not fit whole, so one long message
    /// never leaves the result empty. Later items that do not fit whole end the list.
    private func fitted<Item>(
        _ items: [Item], budget: Int, _ make: (Item, Int) -> [String: Any]
    ) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var used = 0
        func size(_ object: [String: Any]) throws -> Int { try JSONSerialization.data(withJSONObject: object).count }
        for item in items {
            let remaining = budget - used
            let whole = make(item, remaining)
            let wholeSize = try size(whole)
            if wholeSize <= remaining {
                result.append(whole)
                used += wholeSize
                continue
            }
            guard result.isEmpty else { break }
            // Serialized size grows with the allowance, so the largest allowance that fits is found by bisection.
            var low = 0
            var high = remaining
            var best: [String: Any]?
            while low <= high {
                let mid = (low + high) / 2
                let candidate = make(item, mid)
                if try size(candidate) <= remaining {
                    best = candidate
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            if let best { result.append(best) }
            break
        }
        return result
    }
    private func executeTool(_ tool: MochiTool, arguments: [String: Any], origin: ToolOrigin) throws -> [String: Any] {
        if origin == .external && !externalControlEnabled {
            throw AppFailure("External control is disabled in Mochi Settings.")
        }
        if origin == .voice, turn.activity == .generating, deferredToolAction != nil, tool.deferredDuringVoiceReply {
            throw AppFailure("A view or playback action is already scheduled for this reply.")
        }
        let requestedID = (arguments["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
        let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 30
        if tool.scope == .conversation {
            guard let requestedID, let chat = library.conversations.first(where: { $0.id == requestedID }),
                !chat.archived, !chat.isDeleted
            else { throw AppFailure("An active conversation is required.") }
            if tool.name != .openConversation, requestedID != selectedID {
                throw AppFailure("That conversation is not currently open. Read get_session again.")
            }
        }
        if !tool.readOnly && tool.scope != .catalog {
            if origin == .external {
                guard arguments["expected_revision"] as? String == controlRevision else {
                    throw AppFailure("Mochi's state changed. Read get_session and retry with the new revision.")
                }
                guard !automationModal else {
                    throw AppFailure("Finish or close the current conversation editing or practice panel, then retry.")
                }
                guard !busy || turn.activity == .playing else {
                    throw AppFailure("Mochi is busy. Wait until the current activity finishes.")
                }
            } else {
                guard !automationModal, turn.mode == .conversation,
                    !busy || turn.activity == .generating || turn.activity == .playing
                else { throw AppFailure("This action is unavailable during the current activity.") }
            }
        }
        func conversationID() throws -> UUID {
            guard let requestedID else { throw AppFailure("An active conversation is required.") }
            return requestedID
        }
        func success(_ fields: [String: Any] = [:]) -> [String: Any] {
            var result = fields
            result["ok"] = true
            result["revision"] = controlRevision
            return result
        }
        func persist(_ candidate: Library) throws {
            guard commitHistory(candidate) else {
                throw AppFailure("The app action could not be saved; nothing was changed.")
            }
        }
        let scheduledConversationID = selectedID
        func schedule(_ action: @escaping () throws -> Void) throws -> [String: Any] {
            if origin == .voice && turn.activity == .generating {
                guard deferredToolAction == nil else {
                    throw AppFailure("A view or playback action is already scheduled for this reply.")
                }
                let key = automation.voiceToolKey
                automation.scheduledVoiceToolKey = key
                deferredToolAction = { [weak self] in
                    do {
                        guard let self else { return }
                        guard self.selectedID == scheduledConversationID, self.writableConversation,
                            !self.automationModal, !self.busy
                        else {
                            throw AppFailure(
                                "The conversation or activity changed; the scheduled action was cancelled.")
                        }
                        try action()
                        if let key {
                            self.automation.voiceResults.insert(
                                ["ok": true, "status": "completed", "revision": self.controlRevision], for: key)
                        }
                    } catch {
                        MochiLog.failure(MochiLog.automation, "Scheduled voice action", error, level: .info)
                        self?.error = AppFailure.message(
                            for: error, fallback: "The scheduled action could not complete.")
                    }
                }
                return success(["status": "scheduled_after_reply"])
            }
            if origin == .external && [.prepareExpression, .startPractice].contains(tool.name) { revealWorkspace?() }
            // Existing playback is allowed for an immediate external seek/replay.
            guard selectedID == scheduledConversationID, writableConversation, !automationModal else {
                throw AppFailure("The conversation changed; the action was cancelled.")
            }
            try action()
            return success(["status": "completed"])
        }
        switch tool.name {
        case .getSession:
            var result: [String: Any] = [
                "ok": true, "revision": controlRevision, "activity": turn.activity.rawValue,
                "mode": practice ? "practice" : "conversation", "modal": automationModal, "paused": audio.paused,
                "playback_seconds": audio.position, "playback_duration": audio.duration,
            ]
            if let chat = conversation {
                result["conversation_id"] = chat.id.uuidString
                result["title"] = chat.title
                result["writable"] = !chat.archived && !chat.isDeleted
                var untrusted = ["title"]
                if !chat.archived && !chat.isDeleted {
                    let preview = MochiTools.boundedText(
                        chat.instructions, characters: origin == .voice ? 1000 : 8000,
                        bytes: origin == .voice ? 6000 : 12000)
                    result["instructions"] = preview
                    result["instructions_truncated"] = preview != chat.instructions
                    result["coaching"] = chat.preferences.coaching.rawValue
                    result["character_name"] =
                        chat.characterName.map { MochiTools.boundedText($0, characters: 80, bytes: 1024) } as Any?
                        ?? NSNull()
                    result["character_name_needs_review"] = chat.characterNameNeedsReview
                    result["character_name_truncated"] =
                        chat.characterName.map { MochiTools.boundedText($0, characters: 80, bytes: 1024) != $0 }
                        ?? false
                    result["display_character_name"] = chat.displayCharacterName
                    if let source = chat.sourceTemplateID {
                        result["source_template_id"] = source.uuidString
                        result["source_template_revision"] = chat.sourceTemplateRevision
                    }
                    result["speed"] = chat.preferences.speed ?? settings.conversationVoiceOptions.speed
                    result["audio_message_ids"] = chat.messages.filter { $0.audio != nil }.suffix(
                        origin == .voice ? 20 : 100
                    ).map { $0.id.uuidString }
                    result["expression_ids"] = library.expressions.filter { $0.conversationID == chat.id }.sorted {
                        $0.date > $1.date
                    }.prefix(origin == .voice ? 20 : 100).map { $0.id.uuidString }
                    untrusted += ["instructions", "character_name", "display_character_name"]
                }
                result["untrusted_fields"] = untrusted
            }
            if let expression { result["selected_expression_id"] = expression.id.uuidString }
            return result
        case .listConversations:
            return [
                "ok": true, "revision": controlRevision,
                "conversations": library.history(in: .active).prefix(limit).map {
                    ["id": $0.id.uuidString, "title": $0.title]
                }, "untrusted_fields": ["conversations.title"],
            ]
        case .getMessages:
            let source = Array(conversation?.messages.suffix(origin == .voice ? min(limit, 10) : limit) ?? [])
            let budget = origin == .voice ? 6000 : 110000
            let messages = try fitted(Array(source.reversed()), budget: budget) { message, bytes in
                let text = message.contextText ?? ""
                let shown = MochiTools.boundedText(text, characters: 2000, bytes: bytes)
                var item: [String: Any] = [
                    "id": message.id.uuidString, "role": message.role, "text": shown,
                    "text_truncated": shown != text, "has_audio": message.audio != nil,
                ]
                if message.audio != nil {
                    item["transcription_state"] = message.transcriptionState?.rawValue ?? "not_required"
                }
                return item
            }
            return success([
                "messages": Array(messages.reversed()),
                "has_more": (conversation?.messages.count ?? 0) > messages.count, "untrusted_fields": ["messages.text"],
            ])
        case .searchExpressions:
            let search = try MochiTools.decode(SearchArguments.self, from: arguments)
            let found = library.expressions.filter {
                $0.conversationID == selectedID
                    && (search.query.isEmpty || $0.english.localizedCaseInsensitiveContains(search.query)
                        || $0.meaning.localizedCaseInsensitiveContains(search.query))
            }
            let count = origin == .voice ? min(limit, 10) : limit
            let newest = Array(found.sorted(by: { $0.date > $1.date }).prefix(count))
            let expressions = try fitted(newest, budget: origin == .voice ? 6000 : 110000) { item, bytes in
                let english = MochiTools.boundedText(item.english, characters: 1000, bytes: bytes)
                let meaning = MochiTools.boundedText(item.meaning, characters: 1000, bytes: bytes)
                return [
                    "id": item.id.uuidString, "english": english, "meaning": meaning,
                    "text_truncated": english != item.english || meaning != item.meaning,
                    "has_reference": item.reference != nil, "attempt_count": item.attempts.count,
                ]
            }
            return success([
                "expressions": expressions, "has_more": found.count > expressions.count,
                "untrusted_fields": ["expressions.english", "expressions.meaning"],
            ])
        case .createConversation:
            let create = try MochiTools.decode(CreateConversationArguments.self, from: arguments)
            let patch = ConversationSettingsPatch(
                try MochiTools.decode(ConversationSettingsArguments.self, from: arguments))
            var chat: Conversation
            if let templateID = create.templateID {
                // Overrides apply to the template snapshot first, so a replaced invalid field never blocks the start.
                var source = try template(id: templateID)
                if let expected = create.expectedTemplateRevision, expected != source.revision {
                    throw AppFailure("Template changed. Read it again before starting.")
                }
                try patch.apply(to: &source)
                chat = try source.conversation(title: create.title)
            } else {
                chat = Conversation()
                try patch.apply(to: &chat)
            }
            if let title = create.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                chat.title = title
                chat.customTitle = true
            }
            var candidate = library
            if create.templateID == nil, let current = conversation, !current.archived, !current.isDeleted,
                current.isPristine,
                let index = candidate.conversations.firstIndex(where: { $0.id == current.id })
            {
                var reused = current
                reused.title = chat.title
                reused.customTitle = chat.customTitle
                reused.instructions = chat.instructions
                reused.characterName = chat.characterName
                reused.preferences = chat.preferences
                chat = reused
                candidate.conversations[index] = reused
            } else {
                candidate.conversations.insert(chat, at: 0)
            }
            candidate.selectedConversationID = chat.id
            try persist(candidate)
            select(chat.id)
            historyScope = .active
            revealWorkspace?()
            return success(["conversation_id": chat.id.uuidString])
        case .openConversation:
            let id = try conversationID()
            select(id)
            historyScope = .active
            revealWorkspace?()
            return success(["conversation_id": id.uuidString])
        case .setConversationInstructions, .setConversationPreferences:
            try updateConversationSettings(
                try conversationID(),
                ConversationSettingsPatch(try MochiTools.decode(ConversationSettingsArguments.self, from: arguments)))
            return success()
        case .saveExpression, .prepareExpression:
            let input = try MochiTools.decode(ExpressionArguments.self, from: arguments)
            let chatID = try conversationID()
            let english = input.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = input.meaning ?? ""
            var candidate = library
            if tool.name == .saveExpression {
                let item =
                    candidate.expressions.first {
                        $0.conversationID == chatID && $0.english == english && $0.meaning == meaning
                    } ?? PracticeExpression(conversationID: chatID, meaning: meaning, english: english)
                if !candidate.expressions.contains(where: { $0.id == item.id }) {
                    candidate.expressions.insert(item, at: 0)
                    try persist(candidate)
                }
                return success(["expression_id": item.id.uuidString])
            }
            func hasDraft(_ chat: Conversation) -> Bool {
                guard let draft = chat.helpDraft else { return false }
                return !draft.meaning.isEmpty || !draft.english.isEmpty || draft.recording != nil
                    || draft.transcriptReview != nil || draft.expressionID != nil || draft.clarification != nil
            }
            guard let chat = conversation, !hasDraft(chat) else {
                throw AppFailure(
                    "This conversation already has a Help draft. Finish or discard it before preparing another expression."
                )
            }
            let openID = chat.id
            return try schedule { [weak self] in
                guard let self, self.selectedID == openID, self.writableConversation, !self.automationModal,
                    let ci = self.library.conversations.firstIndex(where: { $0.id == openID }),
                    !hasDraft(self.library.conversations[ci])
                else { throw AppFailure("The conversation changed; your existing Help draft was kept.") }
                var next = self.library
                next.conversations[ci].helpDraft = HelpDraft(meaning: meaning, english: english)
                guard self.commitHistory(next) else {
                    throw AppFailure("The expression could not be prepared; your draft was kept.")
                }
                self.startHelp()
            }
        case .startPractice:
            let id = try MochiTools.decode(ExpressionReferenceArguments.self, from: arguments).expressionID
            guard let item = library.expressions.first(where: { $0.id == id && $0.conversationID == selectedID }) else {
                throw AppFailure("Expression not found in this conversation.")
            }
            return try schedule { [weak self] in
                guard let self,
                    let current = self.library.expressions.first(where: {
                        $0.id == item.id && $0.conversationID == self.selectedID
                    })
                else { throw AppFailure("The expression is no longer available in this conversation.") }
                self.openExpression(current)
            }
        case .pauseAudio, .resumeAudio:
            guard playbackFile != nil else { throw AppFailure("No audio is playing.") }
            if (tool.name == .pauseAudio && !audio.paused) || (tool.name == .resumeAudio && audio.paused) {
                audio.togglePause()
            }
            if tool.name == .resumeAudio, playbackFile == nil || audio.paused {
                throw AppFailure("Playback could not resume.")
            }
            return success()
        case .playAudio, .seekAudio:
            let input = try MochiTools.decode(AudioArguments.self, from: arguments)
            var file: String?
            var mochi = false
            if let id = input.messageID, let message = conversation?.messages.first(where: { $0.id == id }) {
                file = message.audio
                mochi = message.role == "assistant"
            }
            if let id = input.expressionID {
                file = library.expressions.first(where: { $0.id == id && $0.conversationID == selectedID })?.reference
            }
            guard let file, file == URL(fileURLWithPath: file).lastPathComponent,
                FileManager.default.fileExists(atPath: store.root.appendingPathComponent(file).path)
            else { throw AppFailure("Audio is unavailable for that item.") }
            let seconds = input.seconds
            return try schedule { [weak self] in
                guard let self else { return }
                if let seconds {
                    self.seekPlayback(file, to: seconds, mochi: mochi)
                } else {
                    self.play(file, mochi: mochi)
                }
                guard self.playbackFile == file else { throw AppFailure("This recording could not be played.") }
            }
        case .listConversationTemplates, .getConversationTemplate, .createConversationTemplate,
            .updateConversationTemplate, .deleteConversationTemplate:
            return try executeTemplateTool(tool.name, arguments: arguments)
        }
    }
}
