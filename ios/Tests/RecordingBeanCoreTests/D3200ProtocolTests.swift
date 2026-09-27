import Foundation
import XCTest
@testable import RecordingBeanCore

final class D3200ProtocolTests: XCTestCase {
func testCommandAllowlistAndFrameDecoding() throws {
    XCTAssertThrowsError(try D3200Protocol.command(type: 26, id: 16))
    let payload = D3200Protocol.littleEndian(1, count: 2)
        + D3200Protocol.littleEndian(123) + D3200Protocol.littleEndian(7200)
    var frame = Data([9,255,0,0,1,26,14])
    frame.append(D3200Protocol.littleEndian(UInt32(payload.count + 10), count: 2))
    frame.append(payload)
    frame.append(UInt8(truncatingIfNeeded: frame.reduce(0) { $0 + Int($1) }))
    var decoder = D3200FrameDecoder()
    XCTAssertTrue(try decoder.push(Data(frame.prefix(8))).isEmpty)
    let parsed = try decoder.push(Data(frame.dropFirst(8)) + frame)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(try D3200Protocol.files(parsed[0].payload), [D3200File(id: 123, durationMs: 7200)])
    frame[10] ^= 1
    XCTAssertThrowsError(try decoder.push(frame))
}

func testPacketLayoutAndCounter() throws {
    XCTAssertThrowsError(try D3200Protocol.slices(Data(repeating: 0, count: 165)))
    XCTAssertEqual(try D3200Protocol.counter(nonce: Data(repeating: 0, count: 16), sequence: 7).suffix(4), Data([0,0,0,70]))
    XCTAssertThrowsError(try D3200Protocol.counter(nonce: Data(repeating: 0, count: 16), sequence: 429_496_730))
    XCTAssertThrowsError(try D3200Protocol.offlineSize(.max))
    let page = try D3200Protocol.oggPage(packet: Data(repeating: 0, count: 160), sequence: 2, granule: 960, flags: 4)
    XCTAssertEqual(page.count, 188)
    XCTAssertEqual(page[5], 4)
    XCTAssertEqual(page[27], 160)
    XCTAssertEqual(try D3200Protocol.opusHeaders().prefix(4), Data("OggS".utf8))
}

func testSerialRequiresStableIdentity() throws {
    var payload = Data(repeating: 0, count: 56)
    payload.replaceSubrange(8..<24, with: Data("abcd123456789012".utf8))
    XCTAssertEqual(try D3200Protocol.serial(payload), "abcd123456789012")
    XCTAssertEqual(D3200Protocol.recordingState(payload), 0)
    XCTAssertEqual(D3200Protocol.battery(4), 50)
    payload[50] = 255
    XCTAssertEqual(D3200Protocol.recordingState(payload), -1)
}

func testLiveWindowIsIndependentlyDecodable() throws {
    let window = try D3200Protocol.liveWindow([Data(repeating: 1, count: 160), Data(repeating: 2, count: 160)])
    XCTAssertEqual(window.prefix(4), Data("OggS".utf8))
    XCTAssertEqual(window.count, try D3200Protocol.opusHeaders(preSkip: 0).count + 376)
    XCTAssertEqual(window.suffix(188).dropFirst(5).first, 4)
    XCTAssertThrowsError(try D3200Protocol.liveWindow([]))
}
}
