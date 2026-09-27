#if os(iOS)
@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation
import RecordingBeanCore

struct DeviceStatus {
    let deviceId: String
    let battery: Int?
    let charging: Bool?
    let caseBattery: Int?
    let caseCharging: Bool?
    let recording: Int
}

struct LiveDraftSegment {
    let index: Int
    let frames: Int
    let fromSequence: UInt32
    let audio: URL
}

struct LiveCapture {
    let audio: URL
    let fromSequence: UInt32
    let segmentCount: Int
}

/// All CoreBluetooth work stays on the main actor; file and socket work is async.
@MainActor
final class D3200Device: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var connectionWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var connectionWaitId: UUID?
    private var writeWaitId: UUID?
    private var fault: Error?
    private var discovered: [CBPeripheral] = []
    private var queue: [D3200Frame] = []
    private var bleDecoder = D3200FrameDecoder()
    private var wifiDecoder = D3200FrameDecoder()
    private let crypto = DeviceCrypto()
    private var hotspot: D3200Hotspot?
    private var fastLink: PinnedRecorderLink?
    private(set) var status: DeviceStatus?
    private(set) var currentRecordingId: UInt32?
    private var batch = false
    var onDisconnect: (() -> Void)?
    var onManualHotspotJoin: ((String, String) async throws -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn, let waiter = connectionWaiter {
            connectionWaiter = nil
            waiter.resume(throwing: URLError(.notConnectedToInternet))
        }
    }

    func scan() async throws -> [CBPeripheral] {
        guard central.state == .poweredOn else { throw URLError(.notConnectedToInternet) }
        discovered.removeAll()
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: D3200Protocol.service)], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        defer { central.stopScan() }
        try await Task.sleep(for: .seconds(5))
        return discovered
    }

    func knownPeripheral(_ identifier: UUID) async -> CBPeripheral? {
        for _ in 0..<20 where central.state == .unknown || central.state == .resetting {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        guard central.state == .poweredOn else { return nil }
        return central.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discovered.contains(where: { $0.identifier == peripheral.identifier }) { discovered.append(peripheral) }
    }

    func connect(_ target: CBPeripheral) async throws -> DeviceStatus {
        await close()
        fault = nil
        guard central.state == .poweredOn else { throw URLError(.notConnectedToInternet) }
        peripheral = target
        target.delegate = self
        do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waitId = UUID()
            connectionWaitId = waitId
            connectionWaiter = continuation
            central.connect(target)
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if self.connectionWaitId == waitId, let waiter = self.connectionWaiter {
                    self.connectionWaitId = nil
                    self.connectionWaiter = nil
                    self.central.cancelPeripheralConnection(target)
                    waiter.resume(throwing: URLError(.timedOut))
                }
            }
        }
        guard let writer, target.maximumWriteValueLength(for: .withResponse) >= 75 else { throw BeanError.invalidFrame }
        _ = writer
        try await send(D3200Protocol.command(type: 46, id: 1, payload: crypto.publicKey()))
        try crypto.handshake((try await next(type: 46, id: 1)).payload)
        return try await refreshStatus()
        } catch {
            await close()
            throw error
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        peripheral.discoverServices([CBUUID(nsuuid: D3200Protocol.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        failConnection(error ?? URLError(.cannotConnectToHost))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if batch && hotspot != nil { return }
        let failure = error ?? URLError(.networkConnectionLost)
        fault = failure
        failConnection(failure)
        status = nil
        currentRecordingId = nil
        onDisconnect?()
    }

    private func failConnection(_ error: Error) {
        if let waiter = connectionWaiter { connectionWaiter = nil; connectionWaitId = nil; waiter.resume(throwing: error) }
        if let waiter = writeWaiter { writeWaiter = nil; writeWaitId = nil; waiter.resume(throwing: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { failConnection(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(nsuuid: D3200Protocol.service) }) else {
            failConnection(BeanError.invalidFrame); return
        }
        peripheral.discoverCharacteristics([CBUUID(nsuuid: D3200Protocol.write), CBUUID(nsuuid: D3200Protocol.notify)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { failConnection(error); return }
        writer = service.characteristics?.first(where: { $0.uuid == CBUUID(nsuuid: D3200Protocol.write) })
        guard writer != nil, let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(nsuuid: D3200Protocol.notify) }) else {
            failConnection(BeanError.invalidFrame); return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { failConnection(error); return }
        guard characteristic.isNotifying else { failConnection(BeanError.invalidFrame); return }
        if let waiter = connectionWaiter { connectionWaiter = nil; connectionWaitId = nil; waiter.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let waiter = writeWaiter {
            writeWaiter = nil
            writeWaitId = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { fault = error; failConnection(error); return }
        guard characteristic.uuid == CBUUID(nsuuid: D3200Protocol.notify), let value = characteristic.value else { return }
        do {
            let found = try bleDecoder.push(value)
            guard queue.count + found.count <= 1024 else { throw BeanError.receiveOverflow }
            queue.append(contentsOf: found)
        } catch { fault = error; failConnection(error) }
    }

    private func send(_ data: Data) async throws {
        guard let peripheral, let writer, peripheral.state == .connected,
              data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { throw BeanError.invalidFrame }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waitId = UUID()
            writeWaitId = waitId
            writeWaiter = continuation
            peripheral.writeValue(data, for: writer, type: .withResponse)
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if self.writeWaitId == waitId, let waiter = self.writeWaiter {
                    self.writeWaitId = nil
                    self.writeWaiter = nil
                    waiter.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    private func next(type: UInt8, id: UInt8? = nil) async throws -> D3200Frame {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            if let fault { throw fault }
            if !queue.isEmpty {
                let frame = queue.removeFirst()
                if frame.type == type && (id == nil || frame.command == id) {
                    guard frame.accepted else { throw BeanError.invalidFrame }
                    return frame
                }
                continue
            }
            if let fastLink {
                let payload = try await fastLink.nextPayload()
                for chunk in stride(from: 0, to: payload.count, by: 16_384) {
                    let frames = try wifiDecoder.push(payload.subdata(in: chunk..<min(payload.count, chunk + 16_384)))
                    guard queue.count + frames.count <= 1024 else { throw BeanError.receiveOverflow }
                    queue.append(contentsOf: frames)
                }
            } else { try await Task.sleep(for: .milliseconds(10)) }
        }
        throw URLError(.timedOut)
    }

    func refreshStatus() async throws -> DeviceStatus {
        try await send(D3200Protocol.command(type: 1, id: 1))
        let payload = try await next(type: 1, id: 1).payload
        let serial = try D3200Protocol.serial(payload)
        let id = "d3200-sn-" + SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
        guard status == nil || status?.deviceId == id else { throw BeanError.invalidIdentity }
        func flag(_ index: Int) -> Bool? {
            guard payload.count > index, payload[index] <= 1 else { return nil }
            return payload[index] == 1
        }
        let result = DeviceStatus(deviceId: id, battery: D3200Protocol.battery(payload.count > 1 ? payload[1] : nil),
                                  charging: flag(2), caseBattery: D3200Protocol.battery(payload.count > 38 ? payload[38] : nil),
                                  caseCharging: flag(32), recording: D3200Protocol.recordingState(payload))
        status = result
        return result
    }

    func list() async throws -> [D3200File] {
        var all: [D3200File] = []
        currentRecordingId = nil
        for page in 0..<4096 {
            try await send(D3200Protocol.command(type: 26, id: 14, payload: D3200Protocol.littleEndian(UInt32(page), count: 2)))
            let payload = try await next(type: 26, id: 14).payload
            let found = try D3200Protocol.files(payload)
            if page == 0, payload.count >= 2 + found.count * 8 + 8 {
                let candidate = try D3200Protocol.uint32(payload, at: 2 + found.count * 8)
                if candidate != 0 { currentRecordingId = candidate }
            }
            if found.isEmpty { return all }
            guard !found.contains(where: { new in all.contains(where: { $0.id == new.id }) }) else { throw BeanError.invalidList }
            all.append(contentsOf: found)
        }
        throw BeanError.invalidList
    }

    func beginBatch() async throws {
        guard !batch, try await refreshStatus().recording != 1 else { throw BeanError.recordingNotFinalized }
        batch = true
    }

    func download(_ source: D3200File, into directory: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        guard batch else { throw BeanError.invalidFrame }
        if fastLink == nil, try await refreshStatus().recording == 1 { throw BeanError.recordingNotFinalized }
        if fastLink == nil {
            let hotspot = try D3200Hotspot()
            self.hotspot = hotspot
            try await send(D3200Protocol.command(type: 26, id: 5, payload: hotspot.credentials))
            let endpoint = try await next(type: 26, id: 5).payload
            guard let onManualHotspotJoin else { throw BeanError.invalidFrame }
            try await hotspot.join(manually: onManualHotspotJoin)
            let link = PinnedRecorderLink()
            let deadline = Date().addingTimeInterval(45)
            while true {
                do { try await link.connect(endpoint: endpoint); break }
                catch RecorderSocketError.wrongCertificate { throw RecorderSocketError.wrongCertificate }
                catch {
                    if Date() >= deadline { throw error }
                    try await Task.sleep(for: .milliseconds(700))
                }
            }
            fastLink = link
        }
        let partial = directory.appending(path: "\(source.id)-\(Int(Date().timeIntervalSince1970)).ogg.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let writer = try FileHandle(forWritingTo: partial)
        var received: Int64 = 0
        var pending: Data?
        do {
            try await fastLink!.request(fileId: source.id)
            let header = try await next(type: 26, id: 7)
            let headerId = try D3200Protocol.uint32(header.payload, at: 0)
            guard headerId == source.id else { throw BeanError.invalidIdentity }
            // List metadata is duration in milliseconds. The header declares wire bytes.
            let total = try D3200Protocol.offlineSize(D3200Protocol.uint32(header.payload, at: 4))
            let space = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
            guard space?.int64Value ?? 0 > Int64(total) * 3 + 64 * 1024 * 1024 else { throw BeanError.invalidSize }
            try crypto.openFile(header.payload)
            try writer.write(contentsOf: D3200Protocol.opusHeaders())
            while true {
                let frame = try await next(type: 26)
                if frame.command == 10 { break }
                if frame.command != 8 && frame.command != 18 { continue }
                let slices = try D3200Protocol.slices(frame.payload)
                guard slices.first.map({ Int64($0.sequence) }) == received else { throw BeanError.invalidSlices }
                for start in stride(from: 0, to: slices.count, by: 400) {
                    let group = Array(slices[start..<min(start + 400, slices.count)])
                    let clear = try crypto.decryptBatch(group)
                    for index in group.indices {
                        if let pending {
                            try writer.write(contentsOf: D3200Protocol.oggPage(packet: pending, sequence: UInt32(received + 1), granule: UInt64(received * 960), flags: 0))
                        }
                        pending = clear.subdata(in: index * 160..<index * 160 + 160)
                        received += 1
                        progress(received * 166, Int64(total))
                        guard received * 166 <= Int64(total) else { throw BeanError.invalidSize }
                    }
                }
            }
            guard let pending, received * 166 == Int64(total) else { throw BeanError.invalidSize }
            try writer.write(contentsOf: D3200Protocol.oggPage(packet: pending, sequence: UInt32(received + 1), granule: UInt64(received * 960), flags: 4))
            try writer.synchronize()
            try writer.close()
            let complete = URL(fileURLWithPath: partial.path.replacingOccurrences(of: ".partial", with: ""))
            try FileManager.default.moveItem(at: partial, to: complete)
            return complete
        } catch {
            try? writer.close()
            throw error
        }
    }

    func captureRealtime(fileId: UInt32, into directory: URL, windowSeconds: Int,
                         onSegment: @escaping (LiveDraftSegment) async throws -> Void) async throws -> LiveCapture {
        guard [2, 5, 10, 20].contains(windowSeconds), currentRecordingId == fileId,
              try await refreshStatus().recording == 1 else { throw BeanError.recordingNotFinalized }
        guard fastLink == nil else { throw BeanError.invalidFrame }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: "\(fileId)-live-\(Int(Date().timeIntervalSince1970)).ogg.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let writer = try FileHandle(forWritingTo: partial)
        var count: UInt32 = 0
        var index = 0
        var fromSequence: UInt32?
        var pending: Data?
        var window: [Data] = []
        func saveWindow() async throws {
            guard !window.isEmpty, let fromSequence else { return }
            try writer.synchronize()
            let bytes = try D3200Protocol.liveWindow(window)
            guard bytes.count <= 1_048_576 else { throw BeanError.invalidSize }
            let file = directory.appending(path: "\(fileId)-live-\(partial.lastPathComponent)-window-\(index).ogg")
            try bytes.write(to: file, options: .atomic)
            try await onSegment(LiveDraftSegment(index: index, frames: window.count,
                                                 fromSequence: fromSequence, audio: file))
            window.removeAll(keepingCapacity: true)
            index += 1
        }
        do {
            let request = D3200Protocol.littleEndian(0) + D3200Protocol.littleEndian(fileId) + Data([1])
            try await send(D3200Protocol.command(type: 26, id: 7, payload: request))
            let header = try await next(type: 26, id: 7)
            guard try D3200Protocol.uint32(header.payload, at: 0) == fileId else { throw BeanError.invalidIdentity }
            try crypto.openFile(header.payload)
            try writer.write(contentsOf: D3200Protocol.opusHeaders())
            while true {
                try Task.checkCancellation()
                let frame = try await next(type: 26)
                if frame.command == 10 { break }
                if frame.command == 6 || frame.command == 7 { throw BeanError.invalidIdentity }
                if frame.command != 8 && frame.command != 18 { continue }
                for slice in try D3200Protocol.slices(frame.payload) {
                    if fromSequence == nil { fromSequence = slice.sequence }
                    guard UInt64(slice.sequence) == UInt64(fromSequence!) + UInt64(count) else { throw BeanError.invalidSlices }
                    let clear = try crypto.decrypt(sequence: slice.sequence, packet: slice.encrypted)
                    if let pending {
                        try writer.write(contentsOf: D3200Protocol.oggPage(packet: pending,
                            sequence: count + 1, granule: UInt64(count) * 960, flags: 0))
                    }
                    pending = clear
                    count += 1
                    window.append(clear)
                    if window.count == windowSeconds * 50 { try await saveWindow() }
                }
            }
            guard let pending, let fromSequence else { throw BeanError.invalidSize }
            try writer.write(contentsOf: D3200Protocol.oggPage(packet: pending,
                sequence: count + 1, granule: UInt64(count) * 960, flags: 4))
            try writer.synchronize()
            if !window.isEmpty { try await saveWindow() }
            try writer.close()
            let ready = URL(fileURLWithPath: partial.path.replacingOccurrences(of: ".partial", with: ""))
            try FileManager.default.moveItem(at: partial, to: ready)
            return LiveCapture(audio: ready, fromSequence: fromSequence, segmentCount: index)
        } catch {
            try? writer.close()
            throw error
        }
    }

    func endBatch() async {
        let hadHotspot = hotspot != nil || fastLink != nil
        await fastLink?.close(); fastLink = nil
        hotspot?.leave(); hotspot = nil
        wifiDecoder = D3200FrameDecoder()
        batch = false
        if hadHotspot { try? await send(D3200Protocol.command(type: 26, id: 2)) }
        if hadHotspot, peripheral?.state != .connected {
            status = nil
            currentRecordingId = nil
            onDisconnect?()
        }
    }

    func close() async {
        failConnection(CancellationError())
        await endBatch()
        crypto.clear()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writer = nil
        status = nil
        currentRecordingId = nil
        queue.removeAll()
        bleDecoder = D3200FrameDecoder()
        wifiDecoder = D3200FrameDecoder()
        fault = nil
    }
}
#endif
