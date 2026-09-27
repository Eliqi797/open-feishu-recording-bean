import CryptoKit
import Foundation

public enum CloudError: Error, Equatable {
    case invalidOrigin, unauthorized, invalidResponse, receiptMismatch, fileChanged, server(Int, String)
}

public struct RecordingReference: Codable, Sendable {
    public let deviceId: String
    public let sourceId: String
    public let title: String
    public init(deviceId: String, sourceId: String, title: String) {
        self.deviceId = deviceId; self.sourceId = sourceId; self.title = title
    }
}

public struct UploadChunk: Decodable, Sendable {
    public let idx: Int
    public let sha256: String
    public let size: Int
}

public struct UploadSession: Decodable, Sendable {
    public let upload_id: String
    public let recording_id: String
    public let size: Int64
    public let sha256: String
    public let chunk_size: Int
    public let stored: Bool
    public let chunks: [UploadChunk]
}

public struct UploadReceipt: Decodable, Sendable {
    public let recording_id: String
    public let stored: Bool
    public let verified: Bool
    public let sha256: String
    public let size: Int64
}

public struct ServerSettings: Decodable, Sendable {
    public let revision: Int
    public let values: [String: String]
    public let secrets_configured: [String: Bool]
}

public struct PlaybackGrant: Sendable {
    public let url: URL
    public let setCookie: String
}

public struct CloudRecording: Decodable, Sendable, Identifiable {
    public let id: String
    public let device_id: String
    public let source_id: String
    public let source_devices: [String]
    public let title: String
    public let created: Double
    public let recorded_at: Double?
    public let size: Int64
    public let stored: Bool
    public let jobs: [CloudJob]
    public let publications: [CloudPublication]
    private enum CodingKeys: String, CodingKey {
        case id, device_id, source_id, source_devices, title, created, recorded_at, size, stored, jobs, publications
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        device_id = try box.decode(String.self, forKey: .device_id)
        source_id = try box.decode(String.self, forKey: .source_id)
        source_devices = try box.decodeIfPresent([String].self, forKey: .source_devices) ?? []
        title = try box.decode(String.self, forKey: .title)
        created = try box.decode(Double.self, forKey: .created)
        recorded_at = try box.decodeIfPresent(Double.self, forKey: .recorded_at)
        size = try box.decode(Int64.self, forKey: .size)
        stored = try box.decode(Int.self, forKey: .stored) != 0
        jobs = try box.decode([CloudJob].self, forKey: .jobs)
        publications = try box.decode([CloudPublication].self, forKey: .publications)
    }
}

public struct CloudJob: Decodable, Sendable {
    public let stage: String
    public let status: String
    public let error: String?
}

public struct CloudPublication: Decodable, Sendable {
    public let document_id: String?
    public let part: Int
    public let status: String
}

public struct TranscriptResult: Decodable, Sendable {
    public let text: String
    public let coverage: TranscriptCoverage?
}

public struct TranscriptCoverage: Decodable, Sendable {
    public let status: String
}

public struct SummaryAction: Decodable, Sendable {
    public let task: String
    public let owner: String?
    public let due_date: String?
}

public struct SummaryResult: Decodable, Sendable {
    public let summary: String
    public let decisions: [String]
    public let actions: [SummaryAction]
    public let uncertainties: [String]
}

public struct LiveStatus: Decodable, Sendable {
    public let session_id: String
    public let status: String
    public let received_ms: Int
    public let text: String
    public let segments: [LiveStatusSegment]
}

public struct LiveStatusSegment: Decodable, Sendable {
    public let idx: Int
    public let status: String
    public let duration_ms: Int
    public let error: String?
    public let text: String
}

public struct LiveReceipt: Decodable, Sendable {
    public let verified: Bool
    public let sha256: String
    public let idx: Int
    public let size: Int
}

private struct RecordingList: Decodable { let recordings: [CloudRecording] }
private struct ErrorEnvelope: Decodable { let error: String }

private final class CloudNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Uses only normal, system-validated HTTPS. D3200's device-local certificate exception
/// is deliberately confined to the device transport and cannot affect this client.
public actor CloudClient {
    nonisolated public let origin: URL
    private let token: String
    private let session: URLSession

    public init(origin: String, token: String, session: URLSession? = nil) throws {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw CloudError.invalidOrigin }
        self.origin = url
        self.token = token
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: CloudNoRedirects(), delegateQueue: nil)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                         extraHeaders: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw CloudError.invalidOrigin }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error) ?? "HTTP_ERROR"
            throw CloudError.server(response.statusCode, code)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudError.invalidResponse }
    }

    public func recordings() async throws -> [CloudRecording] {
        try await send(request("/api/recordings"), as: RecordingList.self).recordings
    }

    public func recording(id: String) async throws -> CloudRecording {
        guard Self.validId(id) else { throw CloudError.invalidResponse }
        return try await send(request("/api/recordings/\(id)"), as: CloudRecording.self)
    }

    public func transcript(recordingId: String) async throws -> TranscriptResult {
        guard Self.validId(recordingId) else { throw CloudError.invalidResponse }
        return try await send(request("/api/recordings/\(recordingId)/result/asr"), as: TranscriptResult.self)
    }

    public func summary(recordingId: String) async throws -> SummaryResult {
        guard Self.validId(recordingId) else { throw CloudError.invalidResponse }
        return try await send(request("/api/recordings/\(recordingId)/result/summary"), as: SummaryResult.self)
    }

    public func settings() async throws -> ServerSettings {
        try await send(request("/api/settings"), as: ServerSettings.self)
    }

    public func saveSettings(revision: Int, values: [String: String], clearSecrets: [String] = []) async throws -> ServerSettings {
        let body = try JSONSerialization.data(withJSONObject: ["revision": revision, "values": values, "clear_secrets": clearSecrets])
        return try await send(request("/api/settings", method: "POST", body: body, contentType: "application/json"), as: ServerSettings.self)
    }

    public func check() async throws {
        _ = try await recordings()
    }

    public func liveBegin(source: RecordingReference, originalSourceId: String, startMs: Int,
                          windowMs: Int) async throws -> LiveStatus {
        guard [2000, 5000, 10000, 20000].contains(windowMs), startMs >= 0 else { throw CloudError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["device_id": source.deviceId,
            "source_id": source.sourceId, "title": source.title, "original_source_id": originalSourceId,
            "start_ms": startMs, "window_ms": windowMs])
        return try await send(request("/api/live", method: "POST", body: body, contentType: "application/json"),
                              as: LiveStatus.self)
    }

    public func liveStatus(sessionId: String) async throws -> LiveStatus {
        guard Self.validId(sessionId) else { throw CloudError.invalidResponse }
        return try await send(request("/api/live/\(sessionId)"), as: LiveStatus.self)
    }

    public func livePut(sessionId: String, index: Int, audio: Data, durationMs: Int) async throws {
        guard Self.validId(sessionId), (0...54000).contains(index), durationMs > 0,
              durationMs <= 20000, durationMs.isMultiple(of: 20), audio.count <= 1_048_576,
              audio.starts(with: Data("OggS".utf8)) else { throw CloudError.invalidResponse }
        let sha = Self.digest(audio)
        let receipt: LiveReceipt = try await send(request("/api/live/\(sessionId)/segments/\(index)",
            method: "PUT", body: audio, contentType: "audio/ogg", extraHeaders: [
                "X-Chunk-SHA256": sha, "X-Audio-Duration-Ms": String(durationMs)]), as: LiveReceipt.self)
        guard receipt.verified, receipt.sha256 == sha, receipt.idx == index, receipt.size == audio.count else {
            throw CloudError.receiptMismatch
        }
    }

    public func liveFinish(sessionId: String, recordingId: String, count: Int) async throws -> LiveStatus {
        guard Self.validId(sessionId), Self.validId(recordingId), count > 0 else { throw CloudError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["recording_id": recordingId,
            "segment_count": count, "device_end_observed": true])
        return try await send(request("/api/live/\(sessionId)/finish", method: "POST", body: body,
                                      contentType: "application/json"), as: LiveStatus.self)
    }

    private static func validId(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func startPipeline(recordingId: String) async throws {
        guard recordingId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw CloudError.invalidResponse }
        let request = try request("/api/recordings/\(recordingId)/pipeline", method: "POST", body: Data("{}".utf8), contentType: "application/json")
        _ = try await send(request, as: CloudRecording.self)
    }

    public func audio(recordingId: String) async throws -> URL {
        guard recordingId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw CloudError.invalidResponse }
        let (download, response) = try await session.download(for: request("/api/recordings/\(recordingId)/audio"))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw CloudError.invalidResponse }
        let destination = FileManager.default.temporaryDirectory.appending(path: "recordingbean-\(recordingId).ogg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: download, to: destination)
        return destination
    }

    public func playbackGrant(recordingId: String) async throws -> PlaybackGrant {
        guard Self.validId(recordingId) else { throw CloudError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["token": token])
        let login = try request("/api/login", method: "POST", body: body, contentType: "application/json")
        let (_, response) = try await session.data(for: login)
        guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.unauthorized }
        guard response.statusCode == 200,
              let cookie = response.value(forHTTPHeaderField: "Set-Cookie"),
              cookie.hasPrefix("bean_session="),
              let url = URL(string: "/api/recordings/\(recordingId)/audio?format=mp3", relativeTo: origin)?.absoluteURL else {
            throw CloudError.invalidResponse
        }
        return PlaybackGrant(url: url, setCookie: cookie)
    }

    public func upload(file: URL, source: RecordingReference, progress: @Sendable (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { throw CloudError.fileChanged }
        let digest = try Self.digest(file: file)
        let recordedAt = source.sourceId.count >= 9 && source.sourceId.count <= 10
            ? Int(source.sourceId) : nil
        let metadata: [String: Any] = ["device_id": source.deviceId, "source_id": source.sourceId,
                                       "title": source.title, "size": size, "sha256": digest, "mime": "audio/ogg",
                                       "recorded_at": recordedAt.map { (946_684_800...4_102_444_800).contains($0) ? $0 as Any : NSNull() } ?? NSNull()]
        let session: UploadSession = try await send(
            request("/api/uploads", method: "POST", body: JSONSerialization.data(withJSONObject: metadata), contentType: "application/json"),
            as: UploadSession.self)
        guard session.size == size, session.sha256 == digest, session.chunk_size > 0,
              session.chunk_size <= 16 * 1024 * 1024 else { throw CloudError.receiptMismatch }
        if !session.stored {
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            let received = Dictionary(session.chunks.map { ($0.idx, $0.sha256) }, uniquingKeysWith: { first, _ in first })
            var offset: Int64 = 0
            var index = 0
            while offset < size {
                try Task.checkCancellation()
                try reader.seek(toOffset: UInt64(offset))
                let count = Int(min(Int64(session.chunk_size), size - offset))
                guard let bytes = try reader.read(upToCount: count), bytes.count == count else { throw CloudError.fileChanged }
                let chunkHash = Self.digest(bytes)
                if received[index] != chunkHash {
                    let request = try request("/api/uploads/\(session.upload_id)/chunks/\(index)", method: "PUT", body: bytes,
                                              contentType: "application/octet-stream", extraHeaders: ["X-Chunk-SHA256": chunkHash])
                    let _: UploadSession = try await send(request, as: UploadSession.self)
                }
                offset += Int64(count)
                index += 1
                progress(offset, size)
            }
        }
        guard try Self.digest(file: file) == digest else { throw CloudError.fileChanged }
        let receipt: UploadReceipt = try await send(request("/api/uploads/\(session.upload_id)/complete", method: "POST", body: Data("{}".utf8), contentType: "application/json"), as: UploadReceipt.self)
        guard receipt.verified, receipt.stored, receipt.recording_id == session.recording_id,
              receipt.size == size, receipt.sha256 == digest else { throw CloudError.receiptMismatch }
        return receipt
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
