import Foundation
import Network
import FluidAudio

// Usage: pixie-voice <port> <key-file>
// GET  /tts                        -> 200 when ready (auth required)
// POST /tts {"text","voice","speed"} -> raw PCM int16 LE mono 24 kHz
// Same contract as the Python prototype so LocalBrain is unchanged. Loopback only; exits with its parent.
let args = CommandLine.arguments
guard args.count >= 3, let port = NWEndpoint.Port(args[1]),
      let key = try? String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
    FileHandle.standardError.write(Data("usage: pixie-voice <port> <key-file>\n".utf8)); exit(2)
}
let parent = getppid()
Thread.detachNewThread { while getppid() == parent { sleep(2) }; exit(0) }

let manager = KokoroAneManager(version: .v3)
nonisolated(unsafe) var ready = false
let voices: Set<String> = ["af_heart", "af_bella", "af_nicole", "af_sarah", "bf_emma", "am_michael"]
Task {
    do {
        try await manager.initialize(preloadVoices: voices)
        _ = try await manager.synthesizeDetailed(text: "Warming up.", voice: "af_heart")
        ready = true
        FileHandle.standardError.write(Data("pixie-voice ready\n".utf8))
    } catch { FileHandle.standardError.write(Data("init failed: \(error)\n".utf8)); exit(1) }
}

func respond(_ c: NWConnection, _ status: String, _ body: Data = Data()) {
    var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
    if body.isEmpty && status.hasPrefix("200") { head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" }
    c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
}

func handle(_ c: NWConnection, _ buffer: Data) {
    guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        guard buffer.count < 32_000 else { respond(c, "413 Too Large"); return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, done, _ in
            if let d, !d.isEmpty { handle(c, buffer + d) } else if done { c.cancel() }
        }
        return
    }
    let header = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
    let lines = header.components(separatedBy: "\r\n")
    let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
    var fields: [String: String] = [:]
    for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { fields[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
    guard fields["authorization"] == "Bearer \(key)" else { respond(c, "401 Unauthorized"); return }
    let length = Int(fields["content-length"] ?? "0") ?? 0
    let body = buffer[split.upperBound...]
    guard length <= 20_000 else { respond(c, "413 Too Large"); return }
    if body.count < length {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, done, _ in
            if let d, !d.isEmpty { handle(c, buffer + d) } else if done { c.cancel() }
        }
        return
    }
    if method == "GET" { ready ? respond(c, "200 OK") : respond(c, "503 Loading"); return }
    guard ready, let json = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any],
          let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { respond(c, "400 Bad Request"); return }
    let voice = (json["voice"] as? String).flatMap { voices.contains($0) ? $0 : nil } ?? "af_heart"
    let speed = Float(min(1.4, max(0.7, (json["speed"] as? Double) ?? 1.0)))
    Task {
        do {
            let result = try await manager.synthesizeDetailed(text: String(text.prefix(1500)), voice: voice, speed: speed)
            var pcm = Data(capacity: result.samples.count * 2)
            for s in result.samples { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
            respond(c, "200 OK", pcm)
        } catch { respond(c, "500 Error") }
    }
}

let params = NWParameters.tcp
params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { c in
    c.start(queue: .main)
    c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, _, _ in handle(c, d ?? Data()) }
}
listener.start(queue: .main)
dispatchMain()
