import CryptoKit
import Foundation

func expect(_ ok: Bool, _ message: String) {
    precondition(ok, message)
}

let body = D3200Protocol.littleEndian(1, count: 2)
    + D3200Protocol.littleEndian(123) + D3200Protocol.littleEndian(166)
var frame = Data([9,255,0,0,1,26,14])
frame.append(D3200Protocol.littleEndian(UInt32(body.count + 10), count: 2))
frame.append(body)
frame.append(UInt8(truncatingIfNeeded: frame.reduce(0) { $0 + Int($1) }))
var decoder = D3200FrameDecoder()
expect(try decoder.push(Data(frame.prefix(8))).isEmpty, "fragment")
let parsed = try decoder.push(Data(frame.dropFirst(8)) + frame)
expect(parsed.count == 2, "coalesced")
expect(try D3200Protocol.files(parsed[0].payload).first?.id == 123, "list")
expect(try D3200Protocol.counter(nonce: Data(repeating: 0, count: 16), sequence: 7).suffix(4) == Data([0,0,0,70]), "counter")
expect(try D3200Protocol.oggPage(packet: Data(repeating: 0, count: 160), sequence: 2, granule: 960, flags: 4).count == 188, "ogg")
let live = try D3200Protocol.liveWindow([Data(repeating: 1, count: 160), Data(repeating: 2, count: 160)])
expect(live.starts(with: Data("OggS".utf8)) && live.suffix(188).dropFirst(5).first == 4, "live window")

let app = DeviceCrypto()
let appPoint = app.publicKey()
let peer = P256.KeyAgreement.PrivateKey()
let secret = try peer.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: appPoint))
    .withUnsafeBytes { Data($0) }
try app.handshake(peer.publicKey.x963Representation + secret)
let ws = try RecorderWebSocketFrames.masked(opcode: 1, data: Data("OK".utf8), mask: Data([1,2,3,4]))
expect(ws[0] == 129 && ws[1] == 130 && ws.count == 8, "websocket mask")
var parser = RecorderWebSocketFrames()
expect(try parser.push(Data([129,2,79,75])).first?.data == Data("OK".utf8), "websocket parser")
print("D3200 Swift protocol + P-256 handshake smoke passed")
