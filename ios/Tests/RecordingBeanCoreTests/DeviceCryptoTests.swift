import CryptoKit
import Foundation
import XCTest
@testable import RecordingBeanCore

final class DeviceCryptoTests: XCTestCase {
func testHandshakeRejectsWrongSecret() throws {
    let app = DeviceCrypto()
    let appPoint = app.publicKey()
    XCTAssertEqual(appPoint.count, 65)
    let peer = P256.KeyAgreement.PrivateKey()
    let shared = try peer.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: appPoint))
        .withUnsafeBytes { Data($0) }
    var reply = peer.publicKey.x963Representation + shared
    reply[65] ^= 1
    XCTAssertThrowsError(try app.handshake(reply))
}

func testDecryptRequiresVerifiedHandshakeAndFileHeader() throws {
    let app = DeviceCrypto()
    XCTAssertThrowsError(try app.openFile(Data(repeating: 0, count: 87)))
    XCTAssertThrowsError(try app.decrypt(sequence: 0, packet: Data(repeating: 0, count: 160)))
}
}
