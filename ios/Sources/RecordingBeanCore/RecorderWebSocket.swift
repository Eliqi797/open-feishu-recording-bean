import CryptoKit
import Foundation

public enum RecorderSocketError: Error, Equatable {
    case invalidFrame, oversizedFrame, invalidFragment, invalidUpgrade, wrongCertificate, invalidEndpoint
}

extension RecorderSocketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFrame, .oversizedFrame, .invalidFragment: "录音豆高速通道数据无效 (D3200_WIFI_FRAME)"
        case .invalidUpgrade: "录音豆高速通道握手失败 (D3200_WIFI_UPGRADE)"
        case .wrongCertificate: "录音豆设备证书指纹不匹配 (D3200_CERT_PIN_MISMATCH)"
        case .invalidEndpoint: "录音豆热点地址不符合预期 (D3200_WIFI_ENDPOINT)"
        }
    }
}

public struct RecorderMessage: Equatable, Sendable {
    public let opcode: UInt8
    public let data: Data
}

public struct RecorderWebSocketFrames {
    private var pending = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private let limit = 4 * 1024 * 1024
    public init() {}

    public mutating func push(_ bytes: Data) throws -> [RecorderMessage] {
        guard pending.count + bytes.count <= limit + 10 else { throw RecorderSocketError.oversizedFrame }
        pending.append(bytes)
        var result: [RecorderMessage] = []
        while pending.count >= 2 {
            let first = pending[0], second = pending[1]
            let finished = first & 128 != 0, opcode = first & 15
            guard first & 112 == 0, second & 128 == 0, [0,1,2,8,9,10].contains(opcode) else {
                throw RecorderSocketError.invalidFrame
            }
            var length = Int(second & 127), offset = 2
            if length == 126 {
                guard pending.count >= 4 else { break }
                length = Int(pending[2]) * 256 + Int(pending[3])
                offset = 4
                guard length >= 126 else { throw RecorderSocketError.invalidFrame }
            } else if length == 127 {
                guard pending.count >= 10 else { break }
                guard pending[2..<6].allSatisfy({ $0 == 0 }) else { throw RecorderSocketError.oversizedFrame }
                length = (6..<10).reduce(0) { $0 * 256 + Int(pending[$1]) }
                offset = 10
                guard length >= 65_536 else { throw RecorderSocketError.invalidFrame }
            }
            guard length <= limit, opcode < 8 || (finished && length <= 125) else { throw RecorderSocketError.oversizedFrame }
            guard pending.count >= offset + length else { break }
            let body = pending.subdata(in: offset..<offset + length)
            pending = Data(pending.dropFirst(offset + length))
            if opcode >= 8 {
                guard opcode != 8 || length != 1 else { throw RecorderSocketError.invalidFrame }
                result.append(RecorderMessage(opcode: opcode, data: body))
                continue
            }
            if opcode == 0 {
                guard fragmentOpcode != 0 else { throw RecorderSocketError.invalidFragment }
            } else {
                guard fragmentOpcode == 0 else { throw RecorderSocketError.invalidFragment }
                fragmentOpcode = opcode
            }
            guard fragments.count + body.count <= limit else { throw RecorderSocketError.oversizedFrame }
            fragments.append(body)
            if finished {
                result.append(RecorderMessage(opcode: fragmentOpcode, data: fragments))
                fragments.removeAll()
                fragmentOpcode = 0
            }
        }
        return result
    }

    public static func masked(opcode: UInt8, data: Data, mask: Data) throws -> Data {
        guard mask.count == 4, data.count <= 65_535, opcode < 8 || data.count <= 125 else {
            throw RecorderSocketError.oversizedFrame
        }
        var result = Data([128 | opcode])
        if data.count < 126 { result.append(UInt8(128 | data.count)) }
        else { result.append(254); result.append(UInt8(data.count >> 8)); result.append(UInt8(data.count & 255)) }
        result.append(mask)
        for (index, byte) in data.enumerated() { result.append(byte ^ mask[index % 4]) }
        return result
    }

    public static func accept(for key: String) -> String {
        let input = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
    }

    public static func verifyUpgrade(_ response: String, accept: String) throws {
        let lines = response.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else { throw RecorderSocketError.invalidUpgrade }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw RecorderSocketError.invalidUpgrade }
            let name = String(line[..<colon]).lowercased()
            guard headers[name] == nil else { throw RecorderSocketError.invalidUpgrade }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["sec-websocket-accept"] == accept,
              headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil else {
            throw RecorderSocketError.invalidUpgrade
        }
    }
}
