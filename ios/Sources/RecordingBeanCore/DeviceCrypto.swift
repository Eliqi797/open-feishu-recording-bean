import CommonCrypto
import CryptoKit
import Foundation

public enum DeviceCryptoError: Error, Equatable {
    case missingHandshake, invalidHandshake, sharedSecretMismatch
    case invalidFileHeader, fileUnavailable, missingFileKey, invalidAudioSlice
    case encryptionFailure
}

/// D3200 crypto state is per BLE connection. Never persist session or file keys.
public final class DeviceCrypto {
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var session = Data()
    private var fileKey = Data()
    private var nonce = Data()

    public init() {}

    public func publicKey() -> Data {
        clear()
        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key
        return key.publicKey.x963Representation
    }

    public func handshake(_ payload: Data) throws {
        guard let privateKey, payload.count >= 97, payload[0] == 4 else { throw DeviceCryptoError.invalidHandshake }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: payload.prefix(65))
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        guard secret.count == 32, Self.constantTimeEqual(secret, payload.subdata(in: 65..<97)) else {
            throw DeviceCryptoError.sharedSecretMismatch
        }
        let first = Self.hmac(key: Data([1,2,3]), value: secret)
        session = Self.hmac(key: first, value: Data([1,2,3,1]))
        self.privateKey = nil
    }

    public func openFile(_ header: Data) throws {
        guard session.count == 32, header.count >= 87 else { throw DeviceCryptoError.missingHandshake }
        guard header[86] == 0 || header[86] == 255 else { throw DeviceCryptoError.fileUnavailable }
        let plain = try Self.aesCTR(key: session, iv: header.subdata(in: 70..<86), input: header.subdata(in: 24..<70))
        let magic = Data("soundcored3200".utf8)
        guard plain.count == magic.count + 32, plain.prefix(magic.count) == magic else { throw DeviceCryptoError.invalidFileHeader }
        fileKey = Data(plain.dropFirst(magic.count))
        nonce = header.subdata(in: 8..<24)
    }

    public func decrypt(sequence: UInt32, packet: Data) throws -> Data {
        guard fileKey.count == 32, nonce.count == 16 else { throw DeviceCryptoError.missingFileKey }
        guard packet.count == 160 else { throw DeviceCryptoError.invalidAudioSlice }
        return try Self.aesCTR(key: fileKey, iv: D3200Protocol.counter(nonce: nonce, sequence: sequence), input: packet)
    }

    public func decryptBatch(_ packets: [AudioSlice]) throws -> Data {
        guard fileKey.count == 32, nonce.count == 16 else { throw DeviceCryptoError.missingFileKey }
        guard (1...400).contains(packets.count) else { throw DeviceCryptoError.invalidAudioSlice }
        let first = packets[0].sequence
        guard UInt64(first) + UInt64(packets.count) - 1 <= 429_496_729 else { throw BeanError.invalidCounter }
        var encrypted = Data(capacity: packets.count * 160)
        for (index, packet) in packets.enumerated() {
            guard UInt64(packet.sequence) == UInt64(first) + UInt64(index), packet.encrypted.count == 160 else {
                throw DeviceCryptoError.invalidAudioSlice
            }
            encrypted.append(packet.encrypted)
        }
        return try Self.aesCTR(key: fileKey, iv: D3200Protocol.counter(nonce: nonce, sequence: first), input: encrypted)
    }

    public func clear() {
        privateKey = nil
        session.resetBytes(in: 0..<session.count)
        fileKey.resetBytes(in: 0..<fileKey.count)
        nonce.resetBytes(in: 0..<nonce.count)
        session.removeAll()
        fileKey.removeAll()
        nonce.removeAll()
    }

    private static func hmac(key: Data, value: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: value, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        var different = a.count ^ b.count
        for i in 0..<min(a.count, b.count) { different |= Int(a[i] ^ b[i]) }
        return different == 0
    }

    private static func aesCTR(key: Data, iv: Data, input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw DeviceCryptoError.encryptionFailure }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var used = 0
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress,
                                        key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw DeviceCryptoError.encryptionFailure }
        defer { CCCryptorRelease(cryptor) }
        let capacity = output.count
        let updateStatus = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                CCCryptorUpdate(cryptor, source.baseAddress, input.count, destination.baseAddress, capacity, &used)
            }
        }
        guard updateStatus == kCCSuccess, used == input.count else { throw DeviceCryptoError.encryptionFailure }
        output.count = used
        return output
    }
}
