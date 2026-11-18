import Foundation

/// One message in a chat. `text` grows while the assistant is streaming.
struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    let date: Date
    /// Set when a reply failed or was stopped, so the UI can say so instead of showing a half answer as complete.
    var note: String?
    init(role: Role, text: String, note: String? = nil) { id = UUID(); self.role = role; self.text = text; date = Date(); self.note = note }
}

/// A whole conversation, stored as one small JSON file.
struct ChatThread: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var model: ChatModelChoice
    var messages: [ChatMessage]
    let created: Date
    var updated: Date
    init(model: ChatModelChoice) { id = UUID(); title = "New chat"; self.model = model; messages = []; created = Date(); updated = created }
    var summary: ChatSummary { ChatSummary(id: id, title: title, updated: updated) }
}

/// What the sidebar needs; kept in one index file so the list never loads every conversation.
struct ChatSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var updated: Date
}

/// Saves chats on this Mac only: ~/Library/Application Support/Pixie/Chats, readable by this user only.
/// Reads happen once per thread; writes are debounced and done off the main thread so typing and streaming stay smooth.
@MainActor final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published private(set) var summaries: [ChatSummary] = []

    private let folder: URL
    private let io = DispatchQueue(label: "homie.chat.store", qos: .utility)
    private var pending: [UUID: ChatThread] = [:]
    private var scheduled: DispatchWorkItem?
    /// How many disk flushes ran (tests check that rapid saves coalesce).
    private(set) var flushes = 0
    /// Blocks until queued writes are on disk (tests and shutdown).
    func drain() { io.sync {} }
    private let encoder = JSONEncoder()   // default date format keeps full precision (ISO-8601 drops sub-seconds)
    private static let decoder = JSONDecoder()

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pixie/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.folder.path)
        if let data = try? Data(contentsOf: indexURL), let list = try? Self.decoder.decode([ChatSummary].self, from: data) {
            summaries = list.sorted { $0.updated > $1.updated }
        }
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    func load(_ id: UUID) -> ChatThread? {
        if let unsaved = pending[id] { return unsaved }
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? Self.decoder.decode(ChatThread.self, from: data)
    }

    /// Records the thread and schedules a write. Empty threads are never saved.
    func save(_ thread: ChatThread) {
        guard !thread.messages.isEmpty else { return }
        pending[thread.id] = thread
        if let i = summaries.firstIndex(where: { $0.id == thread.id }) { summaries[i] = thread.summary } else { summaries.insert(thread.summary, at: 0) }
        summaries.sort { $0.updated > $1.updated }
        scheduleFlush()
    }

    func delete(_ id: UUID) {
        pending[id] = nil
        summaries.removeAll { $0.id == id }
        let file = url(id)
        io.async { try? FileManager.default.removeItem(at: file) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard scheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Writes everything pending now (also called when the window closes).
    func flush() {
        scheduled?.cancel(); scheduled = nil
        flushes += 1
        let threads = Array(pending.values), index = summaries, folder = folder, encoder = encoder
        pending.removeAll()
        io.async {
            func write(_ data: Data, _ name: String) {
                let url = folder.appendingPathComponent(name)
                guard (try? data.write(to: url, options: .atomic)) != nil else { return }
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // this user only
            }
            for thread in threads { if let data = try? encoder.encode(thread) { write(data, thread.id.uuidString + ".json") } }
            if let data = try? encoder.encode(index) { write(data, "index.json") }
        }
    }
}
