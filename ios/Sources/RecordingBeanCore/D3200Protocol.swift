import Foundation

public enum BeanError: Error, Equatable {
    case invalidFrame, invalidChecksum, receiveOverflow, truncatedField
    case commandNotAllowed, invalidList, incompleteList, invalidSlices
    case invalidCounter, recordingNotFinalized, invalidSize, invalidIdentity
    case invalidPacket
}

extension BeanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "录音豆数据帧无效 (D3200_INVALID_FRAME)"
        case .invalidChecksum: "录音豆数据校验失败 (D3200_CHECKSUM_MISMATCH)"
        case .receiveOverflow: "录音豆接收队列已满 (D3200_RECEIVER_OVERFLOW)"
        case .truncatedField: "录音豆数据字段不完整 (D3200_TRUNCATED_FIELD)"
        case .commandNotAllowed: "录音豆指令未允许 (D3200_COMMAND_NOT_ALLOWED)"
        case .invalidList, .incompleteList: "录音列表不完整 (D3200_INVALID_LIST)"
        case .invalidSlices: "录音数据序号不连续 (D3200_SEQUENCE_GAP)"
        case .invalidCounter: "录音解密计数器无效 (D3200_COUNTER_INVALID)"
        case .recordingNotFinalized: "录音仍在进行，请结束后重试 (D3200_RECORDING_NOT_FINALIZED)"
        case .invalidSize: "录音长度校验未通过 (D3200_INVALID_SIZE)"
        case .invalidIdentity: "录音豆或录音编号不一致 (D3200_IDENTITY_MISMATCH)"
        case .invalidPacket: "录音音频包无效 (D3200_INVALID_PACKET)"
        }
    }
}

public struct D3200Frame: Equatable, Sendable {
    public let type: UInt8
    public let command: UInt8
    public let status: UInt8
    public let payload: Data
    public var accepted: Bool { status & 0x0f == 1 }
}

public struct D3200File: Equatable, Sendable {
    public let id: UInt32
    public let durationMs: UInt32
}

public struct AudioSlice: Equatable, Sendable {
    public let sequence: UInt32
    public let encrypted: Data
}

public enum D3200Protocol {
    public static let service = UUID(uuidString: "020cf5da-0000-1000-8000-00805f9b34fb")!
    public static let write = UUID(uuidString: "00007777-0000-1000-8000-00805f9b34fb")!
    public static let notify = UUID(uuidString: "00008888-0000-1000-8000-00805f9b34fb")!
    private static let permitted: Set<String> = ["1:1", "46:1", "26:14", "26:7", "26:5", "26:2", "26:15", "26:17"]

    public static func littleEndian(_ value: UInt32, count: Int = 4) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    public static func uint32(_ bytes: Data, at: Int) throws -> UInt32 {
        guard at >= 0, bytes.count - at >= 4 else { throw BeanError.truncatedField }
        return (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << ($1 * 8) }
    }

    public static func command(type: UInt8, id: UInt8, payload: Data = Data()) throws -> Data {
        guard permitted.contains("\(type):\(id)"), payload.count <= 1024 else { throw BeanError.commandNotAllowed }
        var data = Data([8, 238, 0, 0, 0, type, id])
        data.append(littleEndian(UInt32(payload.count + 10), count: 2))
        data.append(payload)
        data.append(UInt8(truncatingIfNeeded: data.reduce(0) { $0 + Int($1) }))
        return data
    }

    public static func files(_ payload: Data) throws -> [D3200File] {
        guard payload.count >= 2 else { throw BeanError.invalidList }
        let count = Int(payload[0]) + Int(payload[1]) * 256
        guard count <= 4096, payload.count >= 2 + count * 8 else { throw BeanError.incompleteList }
        return try (0..<count).map { i in
            D3200File(id: try uint32(payload, at: 2 + i * 8), durationMs: try uint32(payload, at: 6 + i * 8))
        }
    }

    public static func slices(_ payload: Data) throws -> [AudioSlice] {
        guard !payload.isEmpty, payload.count % 166 == 0 else { throw BeanError.invalidSlices }
        return try stride(from: 0, to: payload.count, by: 166).map { i in
            AudioSlice(sequence: try uint32(payload, at: i), encrypted: payload.subdata(in: i + 5..<i + 165))
        }
    }

    public static func counter(nonce: Data, sequence: UInt32) throws -> Data {
        guard nonce.count == 16, sequence <= 429_496_729 else { throw BeanError.invalidCounter }
        var iv = nonce
        let block = sequence * 10
        for i in 0..<4 { iv[12 + i] = UInt8(truncatingIfNeeded: block >> (24 - i * 8)) }
        return iv
    }

    public static func offlineSize(_ bytes: UInt32) throws -> Int {
        if bytes == .max { throw BeanError.recordingNotFinalized }
        guard bytes > 0 else { throw BeanError.invalidSize }
        return Int(bytes)
    }

    public static func serial(_ payload: Data) throws -> String {
        guard payload.count >= 24 else { throw BeanError.invalidIdentity }
        let value = String(decoding: payload[8..<24], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).lowercased()
        let allowed = value.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
        let repeated = value.utf8.first.map { first in value.utf8.allSatisfy { $0 == first } } ?? true
        guard (8...16).contains(value.count), allowed, !repeated,
              !["unknown", "undefined", "default", "12345678", "1234567890123456"].contains(value) else {
            throw BeanError.invalidIdentity
        }
        return value
    }

    public static func battery(_ raw: UInt8?) -> Int? {
        guard let raw, raw <= 100 else { return nil }
        return raw <= 9 ? (Int(raw) + 1) * 10 : Int(raw)
    }

    public static func recordingState(_ payload: Data) -> Int {
        guard payload.count >= 51, payload[50] <= 1 else { return -1 }
        return Int(payload[50])
    }

    public static func oggPage(packet: Data, sequence: UInt32, granule: UInt64, flags: UInt8) throws -> Data {
        let segmentCount = packet.count / 255 + 1
        guard segmentCount <= 255 else { throw BeanError.invalidPacket }
        var page = Data([79, 103, 103, 83, 0, flags])
        for i in 0..<8 { page.append(UInt8(truncatingIfNeeded: granule >> (i * 8))) }
        page.append(littleEndian(0x4245414e))
        page.append(littleEndian(sequence))
        page.append(contentsOf: [0, 0, 0, 0, UInt8(segmentCount)])
        for i in 0..<segmentCount { page.append(UInt8(min(255, packet.count - i * 255))) }
        page.append(packet)
        var crc: UInt32 = 0
        for byte in page {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
        }
        page.replaceSubrange(22..<26, with: littleEndian(crc))
        return page
    }

    public static func opusHeaders(preSkip: UInt16 = 312) throws -> Data {
        var head = Data([79,112,117,115,72,101,97,100,1,2,56,1,128,62,0,0,0,0,0])
        head[10] = UInt8(truncatingIfNeeded: preSkip)
        head[11] = UInt8(truncatingIfNeeded: preSkip >> 8)
        let tags = Data([79,112,117,115,84,97,103,115,4,0,0,0,66,101,97,110,0,0,0,0])
        return try oggPage(packet: head, sequence: 0, granule: 0, flags: 2)
            + oggPage(packet: tags, sequence: 1, granule: 0, flags: 0)
    }

    /// Independently playable draft window; never treated as the complete source.
    public static func liveWindow(_ packets: [Data]) throws -> Data {
        guard (1...1000).contains(packets.count), packets.allSatisfy({ $0.count == 160 }) else {
            throw BeanError.invalidPacket
        }
        var audio = try opusHeaders(preSkip: 0)
        for (index, packet) in packets.enumerated() {
            audio.append(try oggPage(packet: packet, sequence: UInt32(index + 2),
                                     granule: UInt64(index + 1) * 960,
                                     flags: index == packets.count - 1 ? 4 : 0))
        }
        return audio
    }
}

public struct D3200FrameDecoder {
    private var pending = Data()
    public init() {}

    public mutating func push(_ input: Data) throws -> [D3200Frame] {
        guard pending.count + input.count <= 131_072 else { throw BeanError.receiveOverflow }
        pending.append(input)
        var frames: [D3200Frame] = []
        while pending.count >= 10 {
            if pending[0] != 9 || pending[1] != 255 || pending[2] != 0 || pending[3] != 0 {
                pending = Data(pending.dropFirst())
                continue
            }
            let length = Int(pending[7]) + Int(pending[8]) * 256
            guard (10...65_535).contains(length) else { throw BeanError.invalidFrame }
            if pending.count < length { break }
            let frame = pending.prefix(length)
            let checksum = UInt8(truncatingIfNeeded: frame.dropLast().reduce(0) { $0 + Int($1) })
            guard checksum == frame.last else { throw BeanError.invalidChecksum }
            frames.append(D3200Frame(type: frame[5], command: frame[6], status: frame[4], payload: Data(frame.dropFirst(9).dropLast())))
            pending = Data(pending.dropFirst(length))
        }
        return frames
    }
}
