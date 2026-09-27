import Foundation

private final class LoginProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.absoluteString == "https://recording.example/api/login")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-test-token")
        precondition(request.httpMethod == "POST")
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: String]
        precondition(body?["token"] == "private-test-token")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "bean_session=test; HttpOnly; Secure; SameSite=Strict; Path=/"])
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct CloudPlaybackSmoke {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginProtocol.self]
        let client = try CloudClient(origin: "https://recording.example", token: "private-test-token",
                                     session: URLSession(configuration: configuration))
        let id = String(repeating: "a", count: 32)
        let grant = try await client.playbackGrant(recordingId: id)
        precondition(grant.url.absoluteString == "https://recording.example/api/recordings/\(id)/audio?format=mp3")
        precondition(grant.setCookie.hasPrefix("bean_session="))
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": grant.setCookie], for: grant.url)
        precondition(cookies.count == 1 && cookies[0].isSecure && cookies[0].domain == grant.url.host)
        let transcript = try JSONDecoder().decode(TranscriptResult.self, from: Data(
            #"{"text":"测试转写","coverage":{"status":"partial"}}"#.utf8))
        precondition(transcript.text == "测试转写" && transcript.coverage?.status == "partial")
        let summary = try JSONDecoder().decode(SummaryResult.self, from: Data(
            #"{"summary":"摘要","decisions":[],"actions":[{"task":"跟进","owner":null,"due_date":null}],"uncertainties":[]}"#.utf8))
        precondition(summary.actions.count == 1 && summary.actions[0].owner == nil)
        print("Authenticated playback grant smoke passed")
    }
}
