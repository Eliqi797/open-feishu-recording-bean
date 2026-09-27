import CryptoKit
import Foundation
import Network
import Security

private final class ConnectionStart: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, Error>
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resolve(_ result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

private final class PinDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    func reject() { lock.lock(); rejected = true; lock.unlock() }
    var wasRejected: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
}

/// The D3200's known expired, IP-mismatched leaf certificate is accepted only
/// on the fixed device hotspot endpoint, and only when its SHA-256 DER pin matches.
public final class PinnedRecorderLink: @unchecked Sendable {
    public static let host = "192.168.43.1"
    public static let port: UInt16 = 443
    private static let certificatePin = "3f2667135cafff135614944392d6b3bc0e991b2ca55dbe9e469caca44d5a0125"
    private let queue = DispatchQueue(label: "xyz.recordingbean.device.link")
    private var connection: NWConnection?
    private var udp: NWConnection?
    private var keepAlive: DispatchSourceTimer?
    private var decoder = RecorderWebSocketFrames()
    private var messages: [RecorderMessage] = []
    private var received = Data()

    public init() {}

    public static func endpoint(_ payload: Data) throws -> (String, UInt16) {
        guard payload.count >= 6 else { throw RecorderSocketError.invalidEndpoint }
        let host = "\(payload[3]).\(payload[2]).\(payload[1]).\(payload[0])"
        let port = UInt16(payload[4]) | UInt16(payload[5]) << 8
        guard host == Self.host, port == Self.port else { throw RecorderSocketError.invalidEndpoint }
        return (host, port)
    }

    public func connect(endpoint payload: Data) async throws {
        let (host, port) = try Self.endpoint(payload)
        let pinDecision = PinDecision()
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, finish in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = chain.first else { pinDecision.reject(); finish(false); return }
            let der = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            if digest != Self.certificatePin { pinDecision.reject() }
            finish(digest == Self.certificatePin)
        }, queue)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        self.connection = connection
        do {
        try await Self.start(connection, on: queue)
        try await startKeepAlive(host: host)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let accept = RecorderWebSocketFrames.accept(for: key)
        let request = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nAccept-Encoding: gzip\r\nUser-Agent: okhttp/3.12.13.18\r\n\r\n"
        try await sendRaw(Data(request.utf8))
        while true {
            let chunk = try await receiveRaw()
            received.append(chunk)
            guard received.count <= 16_384 else { throw RecorderSocketError.invalidUpgrade }
            guard let end = received.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = received.prefix(upTo: end.lowerBound)
            guard let text = String(data: header, encoding: .utf8) else { throw RecorderSocketError.invalidUpgrade }
            try RecorderWebSocketFrames.verifyUpgrade(text, accept: accept)
            let remainder = Data(received.suffix(from: end.upperBound))
            received.removeAll()
            messages.append(contentsOf: try decoder.push(remainder))
            break
        }
        } catch {
            teardown()
            if pinDecision.wasRejected { throw RecorderSocketError.wrongCertificate }
            throw error
        }
    }

    private static func start(_ connection: NWConnection, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let starter = ConnectionStart(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: starter.resolve(.success(()))
                case .failed(let error): starter.resolve(.failure(error))
                case .cancelled: starter.resolve(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { starter.resolve(.failure(URLError(.timedOut))) }
        }
    }

    private func startKeepAlive(host: String) async throws {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        let udp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 32003)!, using: parameters)
        self.udp = udp
        try await Self.start(udp, on: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak udp] in
            udp?.send(content: Data("soundcore-keep-alive-unicast".utf8), completion: .contentProcessed { _ in })
        }
        keepAlive = timer
        timer.resume()
    }

    private func sendRaw(_ data: Data) async throws {
        guard let connection else { throw URLError(.notConnectedToInternet) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receiveRaw() async throws -> Data {
        guard let connection else { throw URLError(.notConnectedToInternet) }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if done { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                else { continuation.resume(throwing: URLError(.cannotParseResponse)) }
            }
        }
    }

    public func request(fileId: UInt32) async throws {
        var bytes = Data([8,238,0,0,0,26,7,18,0])
        bytes.append(D3200Protocol.littleEndian(0))
        bytes.append(D3200Protocol.littleEndian(fileId))
        bytes.append(27)
        try await sendText(bytes.map { String(format: "%02x", $0) }.joined())
    }

    public func nextPayload() async throws -> Data {
        while true {
            if !messages.isEmpty {
                let message = messages.removeFirst()
                if message.opcode == 8 { throw URLError(.networkConnectionLost) }
                if message.opcode == 9 { try await sendFrame(opcode: 10, data: message.data); continue }
                if message.opcode == 10 { continue }
                if message.opcode == 2 { return message.data }
                if message.opcode == 1 {
                    guard let text = String(data: message.data, encoding: .ascii) else { throw RecorderSocketError.invalidFrame }
                    if text == "OK" || text == "ACK" { continue }
                    guard text.count.isMultiple(of: 2), text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else {
                        throw RecorderSocketError.invalidFrame
                    }
                    var bytes = Data(capacity: text.count / 2)
                    let chars = Array(text.utf8)
                    for i in stride(from: 0, to: chars.count, by: 2) {
                        let pair = String(decoding: chars[i..<i+2], as: UTF8.self)
                        guard let value = UInt8(pair, radix: 16) else { throw RecorderSocketError.invalidFrame }
                        bytes.append(value)
                    }
                    return bytes
                }
            }
            messages.append(contentsOf: try decoder.push(try await receiveRaw()))
        }
    }

    private func sendText(_ text: String) async throws { try await sendFrame(opcode: 1, data: Data(text.utf8)) }
    private func sendFrame(opcode: UInt8, data: Data) async throws {
        let mask = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        try await sendRaw(RecorderWebSocketFrames.masked(opcode: opcode, data: data, mask: mask))
    }

    public func close() async {
        try? await sendText("FINISH")
        teardown()
    }

    private func teardown() {
        keepAlive?.cancel(); keepAlive = nil
        udp?.cancel(); udp = nil
        connection?.cancel(); connection = nil
        messages.removeAll()
        received.removeAll()
        decoder = RecorderWebSocketFrames()
    }
}
