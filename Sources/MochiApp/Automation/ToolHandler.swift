import Foundation
import MochiAutomation
import MochiCore
import MochiKernel

/// Runs Mochi tool calls, from a voice reply or the MCP helper, as app actions and shapes their results:
/// argument decoding, revision and modal checks, scheduling after a reply, result budgets and idempotency.
/// It holds no state of its own: it reads the app on every call, and its caches live in `AutomationController`.
@MainActor struct ToolHandler {
    let app: AppModel
    func executeVoice(_ name: String, arguments: [String: Any], operationID: UUID) throws -> [String: Any] {
        let tool = try MochiTools.validate(name: name, arguments: arguments, origin: .voice)
        if tool.readOnly { return try run(tool, arguments: arguments, origin: .voice) }
        let key = operationID.uuidString + ":" + (try MochiTools.signature(name: name, arguments: arguments))
        if var result = app.automation.voiceResults[key] {
            result["status"] = "previously_completed"
            result["revision"] = revision
            return result
        }
        if app.deferredToolAction != nil, app.automation.scheduledVoiceToolKey == key {
            return ["ok": true, "status": "scheduled_after_reply", "revision": revision]
        }
        app.automation.voiceToolKey = key
        defer { app.automation.voiceToolKey = nil }
        let result = try run(tool, arguments: arguments, origin: .voice)
        if result["status"] as? String != "scheduled_after_reply" {
            app.automation.voiceResults.insert(result, for: key)
        }
        return result
    }
    func handleControlRequest(_ data: Data) -> Data {
        var result: [String: Any]
        do {
            guard app.externalControlEnabled else { throw AppFailure("External control is disabled.") }
            guard data.count <= LocalControl.maxFrame,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let name = object["name"] as? String, let arguments = object["arguments"] as? [String: Any],
                let requestID = object["request_id"] as? String, !requestID.isEmpty, requestID.count <= 300
            else { throw AppFailure("Invalid control request.") }
            let signature = try MochiTools.encode(["name": name, "arguments": arguments])
            if let cached = app.automation.externalResults[requestID] {
                guard cached.signature == signature else {
                    throw AppFailure("A request ID was reused with different arguments.")
                }
                return cached.response
            }
            do { result = try execute(name, arguments: arguments, origin: .external) } catch {
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
            app.automation.externalResults.insert((signature, response), for: requestID)
            return response
        } catch { result = MochiTools.error(AppFailure.message(for: error, fallback: "Invalid control request.")) }
        return (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
    }

    /// The app state external writes must name, so a call made against an older state is refused.
    var revision: String {
        [
            app.libraryRevision.uuidString, app.selectedID?.uuidString ?? "none", app.turn.epoch.uuidString,
            String(app.practice), String(app.history.managerOpen),
            app.customization.instructionsID?.uuidString ?? "none",
            app.customization.templatePresentation?.rawValue ?? "none",
            app.history.renameID?.uuidString ?? "none", String(app.history.permanentDeleteIDs.count),
            String(app.audio.paused),
            app.playbackFile ?? "none",
        ].joined(separator: ":")
    }

    func execute(_ name: String, arguments: [String: Any], origin: ToolOrigin) throws -> [String: Any] {
        try run(
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
    private func run(_ tool: MochiTool, arguments: [String: Any], origin: ToolOrigin) throws -> [String: Any] {
        if origin == .external && !app.externalControlEnabled {
            throw AppFailure("External control is disabled in Mochi Settings.")
        }
        if origin == .voice, app.turn.activity == .generating, app.deferredToolAction != nil,
            tool.deferredDuringVoiceReply
        {
            throw AppFailure("A view or playback action is already scheduled for this reply.")
        }
        let requestedID = (arguments["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
        let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 30
        if tool.scope == .conversation {
            guard let requestedID, let chat = app.library.conversations.first(where: { $0.id == requestedID }),
                !chat.archived, !chat.isDeleted
            else { throw AppFailure("An active conversation is required.") }
            if tool.name != .openConversation, requestedID != app.selectedID {
                throw AppFailure("That conversation is not currently open. Read get_session again.")
            }
        }
        if !tool.readOnly && tool.scope != .catalog {
            if origin == .external {
                guard arguments["expected_revision"] as? String == revision else {
                    throw AppFailure("Mochi's state changed. Read get_session and retry with the new revision.")
                }
                guard !app.automationModal else {
                    throw AppFailure("Finish or close the current conversation editing or practice panel, then retry.")
                }
                guard !app.busy || app.turn.activity == .playing else {
                    throw AppFailure("Mochi is busy. Wait until the current activity finishes.")
                }
            } else {
                guard !app.automationModal, app.turn.mode == .conversation,
                    !app.busy || app.turn.activity == .generating || app.turn.activity == .playing
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
            result["revision"] = revision
            return result
        }
        func persist(_ candidate: Library) throws {
            guard app.commitHistory(candidate) else {
                throw AppFailure("The app action could not be saved; nothing was changed.")
            }
        }
        let scheduledConversationID = app.selectedID
        func schedule(_ action: @escaping () throws -> Void) throws -> [String: Any] {
            if origin == .voice && app.turn.activity == .generating {
                guard app.deferredToolAction == nil else {
                    throw AppFailure("A view or playback action is already scheduled for this reply.")
                }
                let key = app.automation.voiceToolKey
                app.automation.scheduledVoiceToolKey = key
                app.deferredToolAction = { [weak app] in
                    do {
                        guard let app else { return }
                        guard app.selectedID == scheduledConversationID, app.writableConversation,
                            !app.automationModal, !app.busy
                        else {
                            throw AppFailure(
                                "The conversation or activity changed; the scheduled action was cancelled.")
                        }
                        try action()
                        if let key {
                            app.automation.voiceResults.insert(
                                ["ok": true, "status": "completed", "revision": ToolHandler(app: app).revision],
                                for: key)
                        }
                    } catch {
                        MochiLog.failure(MochiLog.automation, "Scheduled voice action", error, level: .info)
                        app?.error = AppFailure.message(
                            for: error, fallback: "The scheduled action could not complete.")
                    }
                }
                return success(["status": "scheduled_after_reply"])
            }
            if origin == .external && [.prepareExpression, .startPractice].contains(tool.name) {
                app.revealWorkspace?()
            }
            // Existing playback is allowed for an immediate external seek/replay.
            guard app.selectedID == scheduledConversationID, app.writableConversation, !app.automationModal else {
                throw AppFailure("The conversation changed; the action was cancelled.")
            }
            try action()
            return success(["status": "completed"])
        }
        switch tool.name {
        case .getSession:
            var result: [String: Any] = [
                "ok": true, "revision": revision, "activity": app.turn.activity.rawValue,
                "mode": app.practice ? "practice" : "conversation", "modal": app.automationModal,
                "paused": app.audio.paused,
                "playback_seconds": app.audio.position, "playback_duration": app.audio.duration,
            ]
            if let chat = app.conversation {
                result["conversation_id"] = chat.id.uuidString
                result["title"] = chat.title
                result["writable"] = !chat.archived && !chat.isDeleted
                var untrusted = ["title"]
                if !chat.archived && !chat.isDeleted {
                    let preview = chat.instructions.bounded(
                        characters: origin == .voice ? 1000 : 8000, bytes: origin == .voice ? 6000 : 12000)
                    result["instructions"] = preview
                    result["instructions_truncated"] = preview != chat.instructions
                    result["coaching"] = chat.preferences.coaching.rawValue
                    result["language"] = chat.preferences.language.rawValue
                    result["character_name"] =
                        chat.characterName.map { $0.bounded(characters: 80, bytes: 1024) } as Any?
                        ?? NSNull()
                    result["character_name_needs_review"] = chat.characterNameNeedsReview
                    result["character_name_truncated"] =
                        chat.characterName.map { $0.bounded(characters: 80, bytes: 1024) != $0 }
                        ?? false
                    result["display_character_name"] = chat.displayCharacterName
                    if let source = chat.sourceTemplateID {
                        result["source_template_id"] = source.uuidString
                        result["source_template_revision"] = chat.sourceTemplateRevision
                    }
                    result["speed"] = chat.preferences.speed ?? app.settings.conversationVoiceOptions.speed
                    result["audio_message_ids"] = chat.messages.filter { $0.audio != nil }.suffix(
                        origin == .voice ? 20 : 100
                    ).map { $0.id.uuidString }
                    result["expression_ids"] = app.library.expressions.filter { $0.conversationID == chat.id }.sorted {
                        $0.date > $1.date
                    }.prefix(origin == .voice ? 20 : 100).map { $0.id.uuidString }
                    untrusted += ["instructions", "character_name", "display_character_name"]
                }
                result["untrusted_fields"] = untrusted
            }
            if let expression = app.help.expression { result["selected_expression_id"] = expression.id.uuidString }
            return result
        case .listConversations:
            return [
                "ok": true, "revision": revision,
                "conversations": app.library.history(in: .active).prefix(limit).map {
                    ["id": $0.id.uuidString, "title": $0.title]
                }, "untrusted_fields": ["conversations.title"],
            ]
        case .getMessages:
            let source = Array(app.conversation?.messages.suffix(origin == .voice ? min(limit, 10) : limit) ?? [])
            let budget = origin == .voice ? 6000 : 110000
            let messages = try fitted(Array(source.reversed()), budget: budget) { message, bytes in
                let text = message.contextText ?? ""
                let shown = text.bounded(characters: 2000, bytes: bytes)
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
                "has_more": (app.conversation?.messages.count ?? 0) > messages.count,
                "untrusted_fields": ["messages.text"],
            ])
        case .searchExpressions:
            let search = try MochiTools.decode(SearchArguments.self, from: arguments)
            let found = app.library.expressions.filter {
                $0.conversationID == app.selectedID
                    && (search.query.isEmpty || $0.english.localizedCaseInsensitiveContains(search.query)
                        || $0.meaning.localizedCaseInsensitiveContains(search.query))
            }
            let count = origin == .voice ? min(limit, 10) : limit
            let newest = Array(found.sorted(by: { $0.date > $1.date }).prefix(count))
            let expressions = try fitted(newest, budget: origin == .voice ? 6000 : 110000) { item, bytes in
                let english = item.english.bounded(characters: 1000, bytes: bytes)
                let meaning = item.meaning.bounded(characters: 1000, bytes: bytes)
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
            let patch = try ConversationSettingsPatch(toolArguments: arguments)
            var chat: Conversation
            if let templateID = create.templateID {
                // Overrides apply to the template snapshot first, so a replaced invalid field never blocks the start.
                var source = try app.templates.template(id: templateID)
                if let expected = create.expectedTemplateRevision, expected != source.revision {
                    throw AppFailure("Template changed. Read it again before starting.")
                }
                try patch.apply(to: &source)
                chat = try source.conversation(title: create.title)
            } else {
                chat = app.freshConversation()
                try patch.apply(to: &chat)
            }
            if let title = create.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                chat.title = title
                chat.customTitle = true
            }
            var candidate = app.library
            if create.templateID == nil, let current = app.conversation, !current.archived, !current.isDeleted,
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
            app.select(chat.id)
            app.history.scope = .active
            app.revealWorkspace?()
            return success(["conversation_id": chat.id.uuidString])
        case .openConversation:
            let id = try conversationID()
            app.select(id)
            app.history.scope = .active
            app.revealWorkspace?()
            return success(["conversation_id": id.uuidString])
        case .setConversationInstructions, .setConversationPreferences:
            try app.updateConversationSettings(
                try conversationID(),
                ConversationSettingsPatch(toolArguments: arguments))
            return success()
        case .saveExpression, .prepareExpression:
            let input = try MochiTools.decode(ExpressionArguments.self, from: arguments)
            let chatID = try conversationID()
            guard app.language(of: chatID).isPractised else {
                throw AppFailure("Expressions need a conversation language. This conversation matches the user's.")
            }
            let english = input.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = input.meaning ?? ""
            var candidate = app.library
            if tool.name == .saveExpression {
                let item =
                    candidate.expressions.first {
                        $0.conversationID == chatID && $0.english == english && $0.meaning == meaning
                    }
                    ?? PracticeExpression(
                        conversationID: chatID, meaning: meaning, english: english, language: app.language(of: chatID))
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
            guard let chat = app.conversation, !hasDraft(chat) else {
                throw AppFailure(
                    "This conversation already has a Help draft. Finish or discard it before preparing another expression."
                )
            }
            let openID = chat.id
            return try schedule { [weak app] in
                guard let app, app.selectedID == openID, app.writableConversation, !app.automationModal,
                    let ci = app.library.conversations.firstIndex(where: { $0.id == openID }),
                    !hasDraft(app.library.conversations[ci])
                else { throw AppFailure("The conversation changed; your existing Help draft was kept.") }
                var next = app.library
                next.conversations[ci].helpDraft = HelpDraft(meaning: meaning, english: english)
                guard app.commitHistory(next) else {
                    throw AppFailure("The expression could not be prepared; your draft was kept.")
                }
                app.startHelp()
            }
        case .startPractice:
            let id = try MochiTools.decode(ExpressionReferenceArguments.self, from: arguments).expressionID
            guard
                let item = app.library.expressions.first(where: { $0.id == id && $0.conversationID == app.selectedID })
            else {
                throw AppFailure("Expression not found in this conversation.")
            }
            return try schedule { [weak app] in
                guard let app,
                    let current = app.library.expressions.first(where: {
                        $0.id == item.id && $0.conversationID == app.selectedID
                    })
                else { throw AppFailure("The expression is no longer available in this conversation.") }
                app.openExpression(current)
            }
        case .pauseAudio, .resumeAudio:
            guard app.playbackFile != nil else { throw AppFailure("No audio is playing.") }
            if (tool.name == .pauseAudio && !app.audio.paused) || (tool.name == .resumeAudio && app.audio.paused) {
                app.audio.togglePause()
            }
            if tool.name == .resumeAudio, app.playbackFile == nil || app.audio.paused {
                throw AppFailure("Playback could not resume.")
            }
            return success()
        case .playAudio, .seekAudio:
            let input = try MochiTools.decode(AudioArguments.self, from: arguments)
            var file: String?
            var mochi = false
            if let id = input.messageID, let message = app.conversation?.messages.first(where: { $0.id == id }) {
                file = message.audio
                mochi = message.role == "assistant"
            }
            if let id = input.expressionID {
                file =
                    app.library.expressions.first(where: { $0.id == id && $0.conversationID == app.selectedID })?
                    .reference
            }
            guard let file, file == URL(fileURLWithPath: file).lastPathComponent,
                FileManager.default.fileExists(atPath: app.store.root.appendingPathComponent(file).path)
            else { throw AppFailure("Audio is unavailable for that item.") }
            let seconds = input.seconds
            return try schedule { [weak app] in
                guard let app else { return }
                if let seconds {
                    app.seekPlayback(file, to: seconds, mochi: mochi)
                } else {
                    app.play(file, mochi: mochi)
                }
                guard app.playbackFile == file else { throw AppFailure("This recording could not be played.") }
            }
        case .listConversationTemplates, .getConversationTemplate, .createConversationTemplate,
            .updateConversationTemplate, .deleteConversationTemplate:
            return try executeTemplateTool(tool.name, arguments: arguments)
        }
    }

    var templateCatalogRevision: String {
        // Sorted signatures avoid UI activity/locale affecting pagination.
        (try? MochiTools.signature(
            name: "template_catalog",
            arguments: [
                "templates": app.templates.all.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    ["id": $0.id.uuidString, "revision": $0.revision]
                }
            ])) ?? ""
    }

    func executeTemplateTool(_ name: MochiToolName, arguments: [String: Any]) throws -> [String: Any] {
        let request = try MochiTools.decode(TemplateArguments.self, from: arguments)
        switch name {
        case .listConversationTemplates: return try listTemplates(arguments: arguments)
        case .createConversationTemplate: return try createTemplateOnce(arguments: arguments, request: request)
        case .getConversationTemplate, .updateConversationTemplate, .deleteConversationTemplate:
            guard let id = request.templateID else { throw AppFailure("A template ID is required.") }
            if name == .getConversationTemplate {
                return templateResult(["template": try app.templates.template(id: id).representation()])
            }
            guard let revision = request.expectedTemplateRevision else {
                throw AppFailure("Read the template revision first.")
            }
            if name == .updateConversationTemplate {
                return templateResult([
                    "template": try app.templates.update(
                        id: id, revision: revision, ConversationTemplate.Patch(toolArguments: arguments)
                    ).representation()
                ])
            }
            try app.templates.delete(id: id, revision: revision)
            return templateResult(["deleted_template_id": id.uuidString], untrusted: [])
        default: throw AppFailure("This is not a template action.")
        }
    }
    private static let templateFields = [
        "template.title", "template.description", "template.character_name", "template.instructions",
    ]
    /// `untrusted` names the fields of `fields` that hold library text; by default those of one `template`.
    /// `catalogRevision` lets a caller that builds many candidate responses compute it once.
    private func templateResult(
        _ fields: [String: Any], untrusted: [String]? = nil,
        catalogRevision: String? = nil
    ) -> [String: Any] {
        fields.merging([
            "ok": true, "revision": revision, "catalog_revision": catalogRevision ?? templateCatalogRevision,
            "untrusted_fields": untrusted ?? Self.templateFields,
        ]) { _, new in new }
    }
    private func listTemplates(arguments: [String: Any]) throws -> [String: Any] {
        let list = try MochiTools.decode(TemplateListArguments.self, from: arguments)
        let catalogRevision = templateCatalogRevision
        if let expected = list.expectedCatalogRevision, expected != catalogRevision {
            throw AppFailure("Template catalog changed. Restart listing from offset 0.")
        }
        let query = (list.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = list.origin ?? "all"
        let values = app.templates.all.filter {
            (origin == "all" || ($0.isBuiltin ? "built_in" : "user") == origin)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
            if $0.title != $1.title { return $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }
            return $0.id.uuidString < $1.id.uuidString
        }
        let untrusted = ["templates.title", "templates.description", "templates.character_name"]
        func page(_ items: [[String: Any]], next: Int?) -> [String: Any] {
            templateResult(
                ["templates": items, "next_offset": next.map { $0 as Any } ?? NSNull()], untrusted: untrusted,
                catalogRevision: catalogRevision)
        }
        let offset = min(list.offset ?? 0, values.count)
        let limit = list.limit ?? 30
        var items: [[String: Any]] = []
        var index = offset
        while index < values.count && items.count < limit {
            let item = values[index].representation(includeInstructions: false)
            if try JSONSerialization.data(withJSONObject: page(items + [item], next: index + 1)).count >= 110000 {
                break
            }
            items.append(item)
            index += 1
        }
        return page(items, next: index < values.count ? index : nil)
    }
    /// A retried request with the same key returns the first result instead of creating a duplicate.
    private func createTemplateOnce(arguments: [String: Any], request: TemplateArguments) throws -> [String: Any] {
        let signature = try MochiTools.signature(
            name: MochiToolName.createConversationTemplate.rawValue, arguments: arguments)
        if let key = request.idempotencyKey, let previous = app.automation.templateCreations[key] {
            guard previous.signature == signature else {
                throw AppFailure("This idempotency_key was already used for a different template.")
            }
            return templateResult(["template": previous.template, "replayed": true])
        }
        let template = try app.templates.create(ConversationTemplate.Patch(toolArguments: arguments)).representation()
        if let key = request.idempotencyKey { app.automation.templateCreations.insert((signature, template), for: key) }
        return templateResult(["template": template])
    }
}
