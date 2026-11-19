import Foundation

/// Which brain answers a chat.
enum ChatModelChoice: String, Codable, CaseIterable, Sendable {
    case homie, max
    var title: String { self == .homie ? "homie" : "homie max" }
    /// Small print under the name in the picker.
    @MainActor var detail: String {
        switch self {
        case .homie: return (LocalBrain.tier == .lite ? "Qwen3.5 2B" : "Qwen3.5 4B") + " · on this Mac · free"
        case .max: return ChatBackends.max == nil ? "cloud · coming soon" : "cloud · most powerful"
        }
    }
    @MainActor var available: Bool {
        switch self {
        case .homie: return ChatBackends.local != nil
        case .max: return ChatBackends.max != nil
        }
    }
    /// Rough character budget for the history we send (local context is 12k tokens, lite 8k).
    var historyBudget: Int { self == .max ? 60_000 : (LocalBrain.tier == .lite ? 14_000 : 24_000) }
}

/// The app plugs real brains in at launch. Each takes OpenAI-style messages ([role, content]) and yields text deltas.
/// Keeping these as plain closures means the chat UI never depends on LocalBrain, LiveSession or the gateway directly.
@MainActor enum ChatBackends {
    typealias Stream = ([[String: Any]]) -> AsyncThrowingStream<String, Error>
    static var local: Stream?
    /// True when the local brain loaded its vision add-on, so attached pictures can go to it as pictures.
    static var localVision: () -> Bool = { false }
    static var max: Stream?
    static func stream(_ model: ChatModelChoice) -> Stream? { model == .homie ? local : max }
}

enum ChatError: LocalizedError {
    case unavailable(ChatModelChoice)
    var errorDescription: String? {
        switch self {
        case .unavailable(.homie): return "homie’s brain isn’t ready on this Mac yet."
        case .unavailable(.max): return "Chat with homie max is coming soon."
        }
    }
}

enum ChatPrompt {
    static func system(name: String, vision: Bool = false) -> String {
        """
        You are homie, a friendly AI that lives on the user's Mac.\(name.isEmpty ? "" : " The user's name is \(name).")
        This is a text chat: you can talk and help think, but you can't take actions on the Mac from here.
        Be warm, direct and brief. Answer in a few sentences unless the user asks for more.
        Use light markdown only when it helps: short lists, **bold**, `code`.
        The user can attach files. You get the text read from them on this Mac: a PDF's text, a text file, or for a picture
        the words recognized in it plus a rough label of what it shows.
        \(vision ? "Pictures attached to their latest message come as the image itself too, so you can look at them. Pictures from earlier messages are only their recognized text." : "You can't see the picture itself, so don't describe details you weren't given.")
        """
    }

    /// System prompt plus the most recent turns that fit the model's budget. Never drops the newest message.
    /// With `vision`, the newest user message carries up to `maxPictures` attached images as image parts; everything else is text.
    static let maxPictures = 2
    static func messages(_ history: [ChatMessage], model: ChatModelChoice, name: String, vision: Bool = false) -> [[String: Any]] {
        var kept: [[String: Any]] = [], used = 0
        for message in history.reversed() where !message.text.isEmpty || message.attachments != nil {
            let content = self.content(message)
            used += content.count
            // Local re-reads the thread each turn, so keep it to the last ~20 messages.
            if !kept.isEmpty && (used > model.historyBudget || (model == .homie && kept.count >= 20)) { break }
            let pictures = vision && kept.isEmpty && message.role == .user
                ? (message.attachments ?? []).compactMap { $0.kind == .image ? $0.picture : nil }.prefix(maxPictures) : []
            if pictures.isEmpty { kept.append(["role": message.role.rawValue, "content": content]) }
            else {
                let parts: [[String: Any]] = pictures.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] }
                kept.append(["role": message.role.rawValue, "content": parts + [["type": "text", "text": content]]])
            }
        }
        return [["role": "system", "content": system(name: name, vision: vision)]] + kept.reversed()
    }

    /// A message as the brain reads it: what they typed, then each attachment's text, labelled.
    static func content(_ message: ChatMessage) -> String {
        var parts = message.text.isEmpty ? [] : [message.text]
        for file in message.attachments ?? [] {
            let what = file.kind == .pdf ? "PDF" + (file.pages.map { ", \($0) page\($0 == 1 ? "" : "s")" } ?? "") : file.kind == .image ? "image" : "file"
            parts.append("[Attached \(what): \(file.name)\(file.truncated ? " (only the first part fit)" : "")]\n" + file.text)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Per-file text budget, so a couple of attachments still leave room for the conversation.
    static func attachmentBudget(_ model: ChatModelChoice) -> Int { model.historyBudget / 2 }
}

/// One open conversation: sends, streams, stops. UI updates are batched (~20/s) so long replies stay smooth.
@MainActor final class ChatSession: ObservableObject {
    @Published private(set) var thread: ChatThread
    @Published private(set) var streaming = false
    var name: () -> String = { "" }
    private let store: ChatStore
    private var task: Task<Void, Never>?

    init(store: ChatStore? = nil, model: ChatModelChoice? = nil) {
        self.store = store ?? .shared
        thread = ChatThread(model: model ?? Self.lastModel)
    }

    nonisolated static var lastModel: ChatModelChoice {
        get { ChatModelChoice(rawValue: UserDefaults.standard.string(forKey: "homie.chat.model") ?? "") ?? .homie }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "homie.chat.model") }
    }

    func setModel(_ model: ChatModelChoice) {
        guard model.available || model == thread.model else { return }
        thread.model = model; Self.lastModel = model
    }

    func newChat() { stop(); thread = ChatThread(model: Self.lastModel) }

    func open(_ id: UUID) {
        guard id != thread.id, let loaded = store.load(id) else { return }
        stop(); thread = loaded
    }

    func delete(_ id: UUID) {
        if id == thread.id { stop(); thread = ChatThread(model: Self.lastModel) }
        store.delete(id)
    }

    /// Sends a message. If a reply is still streaming, it's stopped (and kept as "Stopped") first.
    func send(_ raw: String, attachments: [ChatAttachment] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if streaming { stop() }
        if thread.messages.isEmpty { thread.title = Self.title(from: text.isEmpty ? attachments[0].name : text) }
        thread.messages.append(ChatMessage(role: .user, text: text, attachments: attachments))
        let history = thread.messages
        let reply = ChatMessage(role: .assistant, text: "")
        thread.messages.append(reply)
        thread.updated = Date()
        guard let backend = ChatBackends.stream(thread.model) else { activeReply = reply.id; finish(note: ChatError.unavailable(thread.model).localizedDescription); return }
        let wire = ChatPrompt.messages(history, model: thread.model, name: name(), vision: thread.model == .homie && ChatBackends.localVision())
        activeReply = reply.id
        streaming = true
        let id = reply.id
        task = Task { [weak self] in
            var buffer = "", lastFlush = Date.distantPast
            do {
                for try await delta in backend(wire) {
                    try Task.checkCancellation()
                    buffer += delta
                    // Batch UI updates (~20/s): only the last message's text changes.
                    if Date().timeIntervalSince(lastFlush) > 0.05 { self?.setReply(buffer, id: id); lastFlush = Date() }
                }
                self?.setReply(buffer, id: id)
                if self?.activeReply == id { self?.finish(note: buffer.isEmpty ? "No reply. Try again?" : nil) }
            } catch is CancellationError {
                // stop() already finalized this reply.
            } catch {
                self?.setReply(buffer, id: id)
                if self?.activeReply == id { self?.finish(note: error.localizedDescription) }   // backend errors are written for users
            }
        }
    }

    /// Stops the current reply right away and keeps what arrived so far, marked "Stopped".
    func stop() {
        guard let task else { return }
        task.cancel(); self.task = nil
        finish(note: "Stopped")
    }

    private var activeReply: UUID?

    /// Updates the streaming reply only if it's still the active one in the open thread.
    private func setReply(_ text: String, id: UUID) {
        guard id == activeReply, let last = thread.messages.indices.last, thread.messages[last].id == id else { return }
        thread.messages[last].text = text
    }

    private func finish(note: String?) {
        if let id = activeReply, let i = thread.messages.lastIndex(where: { $0.id == id }) {
            if thread.messages[i].text.isEmpty && (note == nil || note == "Stopped") { thread.messages.remove(at: i) }
            else { thread.messages[i].note = note }
        }
        activeReply = nil
        streaming = false; task = nil
        thread.updated = Date()
        store.save(thread)
    }

    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 42 ? String(line.prefix(40)) + "…" : line
    }
}
