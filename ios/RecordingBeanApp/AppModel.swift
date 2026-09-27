#if os(iOS)
import AVFoundation
import CoreBluetooth
import Combine
import CryptoKit
import Foundation
import RecordingBeanCore
import Security

private enum AccessStore {
    static let service = "xyz.recordingbean.ios.cloud"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        let attributes: [String: Any] = query.merging([
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
    }
}

private enum PersonalDefaults {
    static func decoded(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
    static let origin = decoded("RBPersonalOriginBase64")
    static let token = decoded("RBPersonalTokenBase64")
    static func initialToken() -> String {
        let secured = AccessStore.read()
        if !secured.isEmpty { return secured }
        let savedOrigin = UserDefaults.standard.string(forKey: "cloudOrigin")
        return savedOrigin == nil || savedOrigin == origin ? token : ""
    }
}

private struct SavedLiveSegment: Codable {
    let index: Int
    let frames: Int
    let path: String
}

private struct LiveJournal: Codable {
    let version: Int
    let endpoint: String
    let deviceId: String
    let originalId: String
    let captureId: String
    let title: String
    let windowSeconds: Int
    var fromSequence: UInt32?
    var sessionId: String?
    var pending: [SavedLiveSegment]
    var uploaded: Int
    var deviceEnded: Bool
    var completed: Bool
}

struct ManualHotspotRequest: Identifiable {
    let id = UUID()
    let ssid: String
    let password: String
}

@MainActor
final class AppModel: ObservableObject {
    private static let desiredPeripheralKey = "desiredRecorderPeripheralId"
    @Published var origin = UserDefaults.standard.string(forKey: "cloudOrigin") ?? PersonalDefaults.origin
    @Published var token = PersonalDefaults.initialToken()
    @Published var message = ""
    @Published var busy = false
    @Published var discovered: [CBPeripheral] = []
    @Published var status: DeviceStatus?
    @Published var reconnecting = false
    @Published var deviceFiles: [D3200File] = []
    @Published var currentRecordingId: UInt32?
    @Published var cloudRecordings: [CloudRecording] = []
    @Published var selectedRecording: CloudRecording?
    @Published var transcriptText = ""
    @Published var summaryText = ""
    @Published var detailBusy = false
    @Published var playingRecordingId: String?
    @Published var playbackPosition: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var playbackPaused = false
    @Published var progress: Double = 0
    @Published var speed = ""
    @Published var manualHotspotRequest: ManualHotspotRequest?
    @Published var autoUpload = UserDefaults.standard.object(forKey: "autoUpload") as? Bool ?? true
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake")
    @Published var themeMode = UserDefaults.standard.string(forKey: "themeMode") ?? "system"
    @Published var asrProvider = "nvidia_parakeet"
    @Published var asrBaseURL = ""
    @Published var asrModel = ""
    @Published var asrLanguage = "zh-CN"
    @Published var asrHotwords = ""
    @Published var asrResponseFormat = "verbose_json"
    @Published var asrChunkSeconds = "120"
    @Published var nvidiaMaxSpeakers = "8"
    @Published var nvidiaTimeoutSeconds = "1800"
    @Published var nvidiaSpeakerZeroPolicy = "unknown"
    @Published var asrKey = ""
    @Published var llmBaseURL = ""
    @Published var llmModel = ""
    @Published var llmKey = ""
    @Published var feishuAuthMode = "lark_cli"
    @Published var feishuAppId = ""
    @Published var feishuAppSecret = ""
    @Published var feishuUserToken = ""
    @Published var feishuExpectedOpenId = ""
    @Published var feishuPersonalConfirmed = false
    @Published var feishuCliProfile = ""
    @Published var feishuFolderToken = ""
    @Published var feishuDocsOrigin = "https://www.feishu.cn"
    @Published var autoPipeline = false
    @Published var documentTimezone = "Asia/Shanghai"
    @Published var settingsRevision = 0
    @Published var settingsLoaded = false
    @Published var configuredSecrets: [String: Bool] = [:]
    @Published var clearSecrets: Set<String> = []
    @Published var liveText = ""
    @Published var liveStatus = "尚未开始实时记录"
    @Published var liveRunning = false
    @Published var liveWindowSeconds = UserDefaults.standard.integer(forKey: "liveWindowSeconds") == 0 ? 5 : UserDefaults.standard.integer(forKey: "liveWindowSeconds")
    private let device = D3200Device()
    private var desiredPeripheral: CBPeripheral?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptId: UUID?
    private var cloud: CloudClient?
    private var lastProgress: (bytes: Int64, time: Date)?
    private var syncRunning = false
    private var manualHotspotWaiter: CheckedContinuation<Void, Error>?
    private var liveJournal: LiveJournal?
    private var liveJournalURL: URL?
    private var liveFlushTask: Task<Void, Never>?
    private var liveCaptureTask: Task<Void, Never>?
    private var devicePollTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var playbackRequest: UUID?
    private var playbackObservers: [NSObjectProtocol] = []
    private var playbackTimeObserver: Any?

    init() {
        if !origin.isEmpty, !token.isEmpty { cloud = try? CloudClient(origin: origin, token: token) }
        device.onDisconnect = { [weak self] in
            guard let self else { return }
            self.status = nil
            self.currentRecordingId = nil
            if self.desiredPeripheral != nil {
                self.message = "蓝牙暂时中断，正在自动重连；云端上传会继续"
                self.scheduleReconnect()
            }
        }
        device.onManualHotspotJoin = { [weak self] ssid, password in
            guard let self else { throw CancellationError() }
            try await self.waitForManualHotspot(ssid: ssid, password: password)
        }
    }

    private func waitForManualHotspot(ssid: String, password: String) async throws {
        try Task.checkCancellation()
        guard manualHotspotWaiter == nil else { throw BeanError.invalidFrame }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                manualHotspotWaiter = continuation
                manualHotspotRequest = ManualHotspotRequest(ssid: ssid, password: password)
                message = "请先在 iPhone 设置中加入录音豆热点，再返回这里继续"
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelManualHotspotJoin() }
        }
    }

    func confirmManualHotspotJoin() {
        guard let waiter = manualHotspotWaiter else { return }
        manualHotspotWaiter = nil
        manualHotspotRequest = nil
        waiter.resume()
    }

    func cancelManualHotspotJoin() {
        guard let waiter = manualHotspotWaiter else { return }
        manualHotspotWaiter = nil
        manualHotspotRequest = nil
        waiter.resume(throwing: CancellationError())
    }

    func saveConnection() async {
        do {
            let client = try CloudClient(origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
            try await client.check()
            try AccessStore.save(token)
            UserDefaults.standard.set(origin, forKey: "cloudOrigin")
            cloud = client
            settingsLoaded = false
            configuredSecrets = [:]
            clearSecrets = []
            message = "服务器已连接"
            await refreshCloud()
            await loadProviderSettings()
        } catch { message = "服务器连接失败：\(error.localizedDescription)" }
    }

    func refreshCloud() async {
        guard let cloud else { return }
        do {
            cloudRecordings = try await cloud.recordings()
            if AccessStore.read().isEmpty, origin == PersonalDefaults.origin,
               token == PersonalDefaults.token, !token.isEmpty {
                do { try AccessStore.save(token) }
                catch { message = "服务器已连接，但访问口令未能存入钥匙串" }
            }
        }
        catch { message = "云端读取失败：\(error.localizedDescription)" }
    }

    func selectRecording(_ recording: CloudRecording) async {
        selectedRecording = recording
        transcriptText = ""
        summaryText = ""
        await refreshDetails()
    }

    func closeDetails() {
        stopPlayback()
        selectedRecording = nil
        transcriptText = ""
        summaryText = ""
    }

    func refreshDetails() async {
        guard let id = selectedRecording?.id, let cloud, !detailBusy else { return }
        detailBusy = true
        defer { detailBusy = false }
        do {
            let detail = try await cloud.recording(id: id)
            guard selectedRecording?.id == id else { return }
            var transcript = ""
            var summary = ""
            if detail.jobs.contains(where: { $0.stage == "asr" && $0.status == "completed" }) {
                let result = try await cloud.transcript(recordingId: id)
                transcript = result.text
                if result.coverage?.status == "partial" {
                    summary = "转写不完整：部分时段没有识别文字，请结合原音核对。\n\n"
                }
            }
            if detail.jobs.contains(where: { $0.stage == "summary" && $0.status == "completed" }) {
                let result = try await cloud.summary(recordingId: id)
                let actions = result.actions.map {
                    "\($0.task) · 责任人：\($0.owner ?? "待确认") · 日期：\($0.due_date ?? "待确认")"
                }
                summary += result.summary + "\n\n结论\n" + result.decisions.joined(separator: "\n")
                    + "\n\n待办\n" + actions.joined(separator: "\n")
                    + "\n\n待确认\n" + result.uncertainties.joined(separator: "\n")
            }
            guard selectedRecording?.id == id else { return }
            selectedRecording = detail
            transcriptText = transcript
            summaryText = summary
            message = "处理结果已更新；说话人准确性仍需核验"
        } catch { message = "读取录音详情失败：\(error.localizedDescription)" }
    }

    func retrySelected() async {
        guard let id = selectedRecording?.id, let cloud, !detailBusy else { return }
        detailBusy = true
        do { try await cloud.startPipeline(recordingId: id) }
        catch { message = "继续处理失败：\(error.localizedDescription)" }
        detailBusy = false
        await refreshDetails()
    }

    func stopPlayback() {
        playbackRequest = nil
        playingRecordingId = nil
        playbackPosition = 0
        playbackDuration = 0
        playbackPaused = false
        if let playbackTimeObserver, let player {
            player.removeTimeObserver(playbackTimeObserver)
        }
        playbackTimeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playbackObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playbackObservers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlayback(_ recording: CloudRecording) async {
        if playingRecordingId == recording.id {
            guard let player, player.currentItem?.status == .readyToPlay else {
                stopPlayback()
                message = "回听已取消"
                return
            }
            if playbackPaused {
                player.play()
                playbackPaused = false
                message = "继续回听"
            } else {
                player.pause()
                playbackPaused = true
                message = "回听已暂停"
            }
            return
        }
        stopPlayback()
        guard recording.stored, let cloud else { message = "云端录音尚未保存"; return }
        let requestId = UUID()
        playbackRequest = requestId
        playingRecordingId = recording.id
        message = "正在准备回听"
        do {
            let grant = try await cloud.playbackGrant(recordingId: recording.id)
            guard playbackRequest == requestId else { return }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": grant.setCookie], for: grant.url)
            guard let host = grant.url.host, cookies.count == 1,
                  cookies[0].name == "bean_session", cookies[0].isSecure,
                  cookies[0].domain == host else { throw CloudError.invalidResponse }
            let asset = AVURLAsset(url: grant.url, options: [AVURLAssetHTTPCookiesKey: cookies])
            guard try await asset.load(.isPlayable), playbackRequest == requestId else {
                throw CloudError.invalidResponse
            }
            let item = AVPlayerItem(asset: asset)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            guard playbackRequest == requestId else { return }
            player = AVPlayer(playerItem: item)
            playbackTimeObserver = player?.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackRequest == requestId else { return }
                        if time.seconds.isFinite { self.playbackPosition = max(0, time.seconds) }
                        let duration = self.player?.currentItem?.duration.seconds ?? 0
                        if duration.isFinite && duration > 0 { self.playbackDuration = duration }
                    }
                }
            playbackObservers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.playbackRequest == requestId else { return }
                        self?.stopPlayback()
                        self?.message = "回听结束"
                    }
                })
            playbackObservers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.playbackRequest == requestId else { return }
                        self?.stopPlayback()
                        self?.message = "回听中断，请检查服务器和网络"
                    }
                })
            player?.play()
            message = "正在回听云端录音"
        } catch {
            guard playbackRequest == requestId else { return }
            stopPlayback()
            message = "回听未启动：\(error.localizedDescription)"
        }
    }

    func seekPlayback(to seconds: Double) {
        guard let player, playbackDuration > 0, seconds.isFinite else { return }
        let target = min(max(0, seconds), playbackDuration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        playbackPosition = target
    }

    func loadProviderSettings() async {
        guard let cloud else { return }
        do {
            let settings = try await cloud.settings()
            settingsRevision = settings.revision
            settingsLoaded = true
            configuredSecrets = settings.secrets_configured
            clearSecrets = []
            asrProvider = settings.values["ASR_PROVIDER"] ?? "nvidia_parakeet"
            asrBaseURL = settings.values["ASR_BASE_URL"] ?? ""
            asrModel = settings.values["ASR_MODEL"] ?? ""
            asrLanguage = settings.values["ASR_LANGUAGE"] ?? "zh-CN"
            asrHotwords = settings.values["ASR_HOTWORDS"] ?? ""
            asrResponseFormat = settings.values["ASR_RESPONSE_FORMAT"] ?? "verbose_json"
            asrChunkSeconds = settings.values["ASR_CHUNK_SECONDS"] ?? "120"
            nvidiaMaxSpeakers = settings.values["NVIDIA_MAX_SPEAKERS"] ?? "8"
            nvidiaTimeoutSeconds = settings.values["NVIDIA_TIMEOUT_SECONDS"] ?? "1800"
            nvidiaSpeakerZeroPolicy = settings.values["NVIDIA_SPEAKER_ZERO_POLICY"] ?? "unknown"
            llmBaseURL = settings.values["LLM_BASE_URL"] ?? ""
            llmModel = settings.values["LLM_MODEL"] ?? ""
            feishuAuthMode = settings.values["FEISHU_AUTH_MODE"] ?? "lark_cli"
            feishuAppId = settings.values["FEISHU_APP_ID"] ?? ""
            feishuExpectedOpenId = settings.values["FEISHU_EXPECTED_OPEN_ID"] ?? ""
            feishuPersonalConfirmed = settings.values["FEISHU_PERSONAL_CONFIRMED"] == "1"
            feishuCliProfile = settings.values["FEISHU_CLI_PROFILE"] ?? ""
            feishuFolderToken = settings.values["FEISHU_FOLDER_TOKEN"] ?? ""
            feishuDocsOrigin = settings.values["FEISHU_DOCS_ORIGIN"] ?? "https://www.feishu.cn"
            autoPipeline = settings.values["AUTO_PIPELINE"] == "1"
            documentTimezone = settings.values["DOCUMENT_TIMEZONE"] ?? "Asia/Shanghai"
            asrKey = ""; llmKey = ""; feishuAppSecret = ""; feishuUserToken = ""
        } catch { message = "设置读取失败：\(error.localizedDescription)" }
    }

    func saveProviderSettings() async {
        guard let cloud, settingsLoaded else { message = "请先读取服务器设置"; return }
        let asrSecret = asrProvider == "openai_compatible" ? "ASR_API_KEY" : "NVIDIA_API_KEY"
        var values = ["ASR_PROVIDER": asrProvider, "ASR_BASE_URL": asrBaseURL,
                      "ASR_MODEL": asrModel, "ASR_LANGUAGE": asrLanguage,
                      "ASR_HOTWORDS": asrHotwords, "ASR_RESPONSE_FORMAT": asrResponseFormat,
                      "ASR_CHUNK_SECONDS": asrChunkSeconds,
                      "NVIDIA_MAX_SPEAKERS": nvidiaMaxSpeakers,
                      "NVIDIA_TIMEOUT_SECONDS": nvidiaTimeoutSeconds,
                      "NVIDIA_SPEAKER_ZERO_POLICY": nvidiaSpeakerZeroPolicy,
                      "LLM_BASE_URL": llmBaseURL, "LLM_MODEL": llmModel,
                      "FEISHU_AUTH_MODE": feishuAuthMode, "FEISHU_APP_ID": feishuAppId,
                      "FEISHU_EXPECTED_OPEN_ID": feishuExpectedOpenId,
                      "FEISHU_PERSONAL_CONFIRMED": feishuPersonalConfirmed ? "1" : "0",
                      "FEISHU_CLI_PROFILE": feishuCliProfile, "FEISHU_FOLDER_TOKEN": feishuFolderToken,
                      "FEISHU_DOCS_ORIGIN": feishuDocsOrigin,
                      "AUTO_PIPELINE": autoPipeline ? "1" : "0",
                      "DOCUMENT_TIMEZONE": documentTimezone]
        if !asrKey.isEmpty { values[asrSecret] = asrKey }
        if !llmKey.isEmpty { values["LLM_API_KEY"] = llmKey }
        if !feishuAppSecret.isEmpty { values["FEISHU_APP_SECRET"] = feishuAppSecret }
        if !feishuUserToken.isEmpty { values["FEISHU_USER_ACCESS_TOKEN"] = feishuUserToken }
        var clearing = clearSecrets
        if !asrKey.isEmpty { clearing.remove(asrSecret) }
        if !llmKey.isEmpty { clearing.remove("LLM_API_KEY") }
        if !feishuAppSecret.isEmpty { clearing.remove("FEISHU_APP_SECRET") }
        if !feishuUserToken.isEmpty { clearing.remove("FEISHU_USER_ACCESS_TOKEN") }
        do {
            let result = try await cloud.saveSettings(revision: settingsRevision, values: values,
                                                     clearSecrets: clearing.sorted())
            settingsRevision = result.revision
            configuredSecrets = result.secrets_configured
            clearSecrets = []
            asrKey = ""; llmKey = ""; feishuAppSecret = ""; feishuUserToken = ""
            message = "模型设置已保存；下一条任务生效"
        } catch { message = "模型设置未保存：\(error.localizedDescription)" }
    }

    func toggleSecretClear(_ key: String) {
        guard configuredSecrets[key] == true else { return }
        if clearSecrets.contains(key) { clearSecrets.remove(key) }
        else {
            clearSecrets.insert(key)
            switch key {
            case "NVIDIA_API_KEY", "ASR_API_KEY": asrKey = ""
            case "LLM_API_KEY": llmKey = ""
            case "FEISHU_APP_SECRET": feishuAppSecret = ""
            case "FEISHU_USER_ACCESS_TOKEN": feishuUserToken = ""
            default: break
            }
        }
    }

    func scan() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { discovered = try await device.scan(); message = discovered.isEmpty ? "未发现录音豆，请唤醒设备" : "选择你的录音豆连接" }
        catch { message = "扫描失败：\(error.localizedDescription)" }
    }

    func connect(_ target: CBPeripheral) async {
        guard !busy else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptId = nil
        desiredPeripheral = target
        reconnecting = false
        busy = true; defer { busy = false }
        var stage = "蓝牙握手"
        do {
            status = try await device.connect(target)
            stage = "读取录音列表"
            deviceFiles = try await device.list()
            UserDefaults.standard.set(target.identifier.uuidString, forKey: Self.desiredPeripheralKey)
            currentRecordingId = device.currentRecordingId
            message = "已连接，读取到 \(deviceFiles.count) 条录音"
            if autoUpload, cloud != nil { await syncAll() }
            if status != nil { startDevicePolling() }
        } catch {
            await device.close()
            status = nil
            currentRecordingId = nil
            deviceFiles = []
            message = "\(stage)失败：\(error.localizedDescription)"
            scheduleReconnect()
        }
    }

    func disconnect() async {
        guard !busy else { return }
        desiredPeripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.desiredPeripheralKey)
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptId = nil
        devicePollTask?.cancel()
        devicePollTask = nil
        reconnecting = false
        await device.close()
        status = nil
        currentRecordingId = nil
        deviceFiles = []
        discovered = []
        message = "已断开录音豆"
    }

    func restoreConnection() async {
        guard desiredPeripheral == nil,
              let saved = UserDefaults.standard.string(forKey: Self.desiredPeripheralKey),
              let identifier = UUID(uuidString: saved),
              let target = await device.knownPeripheral(identifier) else { return }
        desiredPeripheral = target
        message = "正在恢复录音豆连接"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard desiredPeripheral != nil, reconnectTask == nil else { return }
        reconnecting = true
        let attemptId = UUID()
        reconnectAttemptId = attemptId
        reconnectTask = Task { [weak self] in
            defer {
                if self?.reconnectAttemptId == attemptId {
                    self?.reconnectAttemptId = nil
                    self?.reconnectTask = nil
                }
            }
            var delay = 2.0
            while let self, !Task.isCancelled, let target = self.desiredPeripheral {
                if self.busy || self.syncRunning || self.liveRunning {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                self.busy = true
                do {
                    let fresh = try await self.device.connect(target)
                    let files = try await self.device.list()
                    guard self.desiredPeripheral?.identifier == target.identifier, !Task.isCancelled else {
                        await self.device.close()
                        self.busy = false
                        return
                    }
                    self.status = fresh
                    self.deviceFiles = files
                    self.currentRecordingId = self.device.currentRecordingId
                    self.reconnecting = false
                    self.busy = false
                    self.message = "录音豆已自动重连，读取到 \(files.count) 条录音"
                    self.startDevicePolling()
                    return
                } catch {
                    await self.device.close()
                    self.busy = false
                    if Task.isCancelled { return }
                    self.message = "录音豆暂不可达，正在重连：\(error.localizedDescription)"
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    delay = min(delay * 1.6, 15)
                }
            }
        }
    }

    private func startDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard let self else { return }
                if self.busy || self.syncRunning || self.liveRunning { continue }
                guard self.status != nil else { return }
                do {
                    let wasRecording = self.status?.recording == 1
                    let previous = Set(self.deviceFiles.map(\.id))
                    self.status = try await self.device.refreshStatus()
                    self.deviceFiles = try await self.device.list()
                    self.currentRecordingId = self.device.currentRecordingId
                    let foundNew = self.deviceFiles.contains { !previous.contains($0.id) }
                    if self.autoUpload, self.cloud != nil, self.status?.recording != 1,
                       (wasRecording || foundNew) { await self.syncAll() }
                } catch {
                    self.status = nil
                    self.message = "设备连接已中断：\(error.localizedDescription)；正在自动重连"
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    func setAutoUpload(_ value: Bool) {
        autoUpload = value
        UserDefaults.standard.set(value, forKey: "autoUpload")
    }

    func setKeepAwake(_ value: Bool) {
        keepAwake = value
        UserDefaults.standard.set(value, forKey: "keepAwake")
    }

    func setThemeMode(_ value: String) {
        guard ["system", "light", "dark"].contains(value) else { return }
        themeMode = value
        UserDefaults.standard.set(value, forKey: "themeMode")
    }

    private func cacheDirectory(for deviceId: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appending(path: "Recordings/\(deviceId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func existingCache(_ id: UInt32, in root: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("\(id)-") && $0.pathExtension == "ogg" })
    }

    private func updateProgress(_ bytes: Int64, _ total: Int64) {
        progress = total > 0 ? min(1, Double(bytes) / Double(total)) : 0
        let now = Date()
        if let previous = lastProgress, now.timeIntervalSince(previous.time) > 0.5 {
            let rate = Double(bytes - previous.bytes) / now.timeIntervalSince(previous.time)
            speed = rate >= 1_048_576 ? String(format: "%.1f MB/s", rate / 1_048_576) : String(format: "%.0f KB/s", max(0, rate) / 1024)
            lastProgress = (bytes, now)
        } else if lastProgress == nil { lastProgress = (bytes, now) }
    }

    var pendingDeviceFiles: [D3200File] {
        guard let deviceId = status?.deviceId else { return deviceFiles }
        return deviceFiles.filter { file in
            !cloudRecordings.contains(where: { $0.stored && $0.source_id == String(file.id) &&
                ($0.device_id == deviceId || $0.source_devices.contains(deviceId)) })
        }
    }

    func downloadOnly(_ file: D3200File) async {
        guard !syncRunning, let status else { message = "请先连接录音豆"; return }
        syncRunning = true
        let wasBusy = busy
        busy = true
        defer { syncRunning = false; busy = wasBusy }
        do {
            let fresh = try await device.refreshStatus()
            guard fresh.recording != 1 else { throw BeanError.recordingNotFinalized }
            guard fresh.deviceId == status.deviceId else { throw BeanError.invalidIdentity }
            let root = try cacheDirectory(for: status.deviceId)
            if existingCache(file.id, in: root) != nil { message = "手机已有完整录音缓存，可继续上传"; return }
            try await device.beginBatch()
            do {
                lastProgress = nil
                _ = try await device.download(file, into: root) { [weak self] bytes, total in
                    Task { @MainActor in self?.updateProgress(bytes, total) }
                }
                await device.endBatch()
            } catch { await device.endBatch(); throw error }
            message = "已下载并校验到手机，设备原件保留；可继续上传"
            progress = 1; speed = ""
        } catch { message = "下载未完成：\(error.localizedDescription)；设备原件保留" }
    }

    func syncAll(only sourceId: UInt32? = nil) async {
        guard !syncRunning else { return }
        syncRunning = true
        let wasBusy = busy
        busy = true
        defer { syncRunning = false; busy = wasBusy }
        guard let cloud, status != nil else { message = "请先连接录音豆并设置服务器"; return }
        do {
            let status = try await device.refreshStatus()
            self.status = status
            if status.recording == 1 { message = "设备仍在录音，结束并保留文件后再同步"; return }
            let root = try cacheDirectory(for: status.deviceId)
            let current = try await cloud.recordings()
            let pending = deviceFiles.filter { source in
                (sourceId == nil || source.id == sourceId) &&
                !current.contains(where: { $0.stored && $0.source_id == String(source.id) &&
                    ($0.device_id == status.deviceId || $0.source_devices.contains(status.deviceId)) })
            }
            if pending.isEmpty { message = "录音已全部归档"; return }
            let uncached = pending.filter { existingCache($0.id, in: root) == nil }
            if !uncached.isEmpty {
                try await device.beginBatch()
                do {
                    for (index, file) in uncached.enumerated() {
                        message = "高速下载 \(index + 1)/\(uncached.count)"
                        lastProgress = nil
                        _ = try await device.download(file, into: root) { [weak self] bytes, total in
                            Task { @MainActor in self?.updateProgress(bytes, total) }
                        }
                    }
                    await device.endBatch()
                } catch { await device.endBatch(); throw error }
            }
            let until = Date().addingTimeInterval(45)
            while true {
                do { try await cloud.check(); break }
                catch CloudError.unauthorized { throw CloudError.unauthorized }
                catch {
                    if Date() >= until { throw error }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            var processingFailures = 0
            for (index, file) in pending.enumerated() {
                guard let audio = existingCache(file.id, in: root) else { throw BeanError.invalidSize }
                message = "云端上传 \(index + 1)/\(pending.count)"
                lastProgress = nil
                let title = "录音 \(Date(timeIntervalSince1970: Double(file.id)).formatted(date: .abbreviated, time: .shortened))"
                let ref = RecordingReference(deviceId: status.deviceId, sourceId: String(file.id), title: title)
                let receipt = try await cloud.upload(file: audio, source: ref) { [weak self] bytes, total in
                    Task { @MainActor in self?.updateProgress(bytes, total) }
                }
                guard receipt.stored, receipt.verified else { throw BeanError.invalidSize }
                try FileManager.default.removeItem(at: audio)
                do { try await cloud.startPipeline(recordingId: receipt.recording_id) }
                catch { processingFailures += 1 }
            }
            cloudRecordings = try await cloud.recordings()
            message = processingFailures == 0 ? "\(pending.count) 条录音已保存并开始处理" :
                "\(pending.count) 条录音已保存，\(processingFailures) 条待重试处理"
            progress = 1; speed = ""
        } catch { message = "同步中断，本地缓存保留：\(error.localizedDescription)" }
    }

    func resumeCachedUploads() async {
        guard !syncRunning, !busy else { return }
        guard let cloud else { message = "请先设置服务器"; return }
        syncRunning = true; busy = true
        defer { syncRunning = false; busy = false }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appending(path: "Recordings", directoryHint: .isDirectory)
            let directories = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var uploaded = 0
            for directory in directories where directory.lastPathComponent.hasPrefix("d3200-sn-") {
                let deviceId = directory.lastPathComponent
                guard deviceId.count == 73,
                      deviceId.dropFirst(9).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.pathExtension == "ogg" {
                    let id = file.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
                    guard let epoch = Int(id), (946_684_800...4_102_444_800).contains(epoch),
                          file.lastPathComponent.hasPrefix("\(id)-") else { continue }
                    let title = "录音 \(Date(timeIntervalSince1970: Double(epoch)).formatted(date: .abbreviated, time: .shortened))"
                    message = "正在恢复缓存上传 \(id)"
                    let receipt = try await cloud.upload(file: file,
                        source: RecordingReference(deviceId: deviceId, sourceId: id, title: title)) { [weak self] bytes, total in
                        Task { @MainActor in self?.updateProgress(bytes, total) }
                    }
                    guard receipt.verified, receipt.stored else { throw CloudError.receiptMismatch }
                    try FileManager.default.removeItem(at: file)
                    uploaded += 1
                    do { try await cloud.startPipeline(recordingId: receipt.recording_id) }
                    catch { message = "音频已保存；处理任务可在录音页重试" }
                }
            }
            cloudRecordings = try await cloud.recordings()
            message = uploaded == 0 ? "没有待上传的完整缓存" : "已恢复上传 \(uploaded) 条完整录音"
        } catch { message = "缓存上传未完成，本地音频保留：\(error.localizedDescription)" }
    }

    func startPipeline(_ recording: CloudRecording) async {
        guard let cloud else { return }
        do { try await cloud.startPipeline(recordingId: recording.id); await refreshCloud() }
        catch { message = "处理失败：\(error.localizedDescription)" }
    }

    private func liveDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let path = base.appending(path: "Live", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func persistLive() throws {
        guard let liveJournal, let liveJournalURL else { return }
        try JSONEncoder().encode(liveJournal).write(to: liveJournalURL, options: .atomic)
    }

    func setLiveWindow(_ seconds: Int) {
        guard [2, 5, 10, 20].contains(seconds) else { return }
        liveWindowSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "liveWindowSeconds")
    }

    func startLive() {
        guard !busy, !liveRunning, cloud != nil, status?.recording == 1,
              device.currentRecordingId != nil else {
            liveStatus = "请先连接正在录音的录音豆，并设置服务器"
            return
        }
        liveCaptureTask = Task { await captureLive() }
    }

    func stopLive() { liveCaptureTask?.cancel(); liveStatus = "正在停止；已收到的草稿片段会保留" }

    private func captureLive() async {
        guard let cloud, let status, let fileId = device.currentRecordingId else { return }
        busy = true; liveRunning = true
        defer { busy = false; liveRunning = false; liveCaptureTask = nil }
        do {
            let directory = try liveDirectory()
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            liveJournalURL = directory.appending(path: "live-journal-\(stamp).json")
            liveJournal = LiveJournal(version: 1, endpoint: cloud.origin.absoluteString,
                deviceId: status.deviceId, originalId: String(fileId),
                captureId: "\(fileId):capture:\(stamp)", title: "实时录音 \(fileId)",
                windowSeconds: liveWindowSeconds, fromSequence: nil, sessionId: nil,
                pending: [], uploaded: 0, deviceEnded: false, completed: false)
            try persistLive()
            liveStatus = "正在接收实时音频"
            let captured = try await device.captureRealtime(fileId: fileId, into: directory,
                windowSeconds: liveWindowSeconds) { [weak self] segment in
                    guard let self, var journal = self.liveJournal else { throw BeanError.invalidFrame }
                    if journal.fromSequence == nil { journal.fromSequence = segment.fromSequence }
                    journal.pending.append(SavedLiveSegment(index: segment.index, frames: segment.frames,
                                                             path: segment.audio.path))
                    self.liveJournal = journal
                    try self.persistLive()
                    self.scheduleLiveFlush()
                }
            guard captured.segmentCount > 0 else { throw BeanError.invalidSize }
            liveJournal?.deviceEnded = true
            try persistLive()
            await liveFlushTask?.value
            guard liveJournal?.pending.isEmpty == true else { throw CloudError.invalidResponse }
            liveStatus = "设备录音已结束，正在归档完整音频"
            self.status = try await device.refreshStatus()
            deviceFiles = try await device.list()
            currentRecordingId = device.currentRecordingId
            await syncAll()
            let archived = try await cloud.recordings().first(where: { $0.stored && $0.source_id == String(fileId) &&
                ($0.device_id == status.deviceId || $0.source_devices.contains(status.deviceId)) })
            guard let archived, let journal = liveJournal, let sessionId = journal.sessionId else {
                throw CloudError.invalidResponse
            }
            _ = try await cloud.liveFinish(sessionId: sessionId, recordingId: archived.id, count: journal.uploaded)
            liveJournal?.completed = true
            try persistLive()
            liveStatus = "实时草稿完成；完整录音已归档并开始生成纪要"
            try? FileManager.default.removeItem(at: captured.audio)
        } catch is CancellationError {
            liveStatus = "实时接收已停止；设备原件和手机草稿片段保留"
        } catch {
            liveStatus = "实时接收中断：\(error.localizedDescription)。草稿保留，可恢复上传"
        }
    }

    private func scheduleLiveFlush() {
        if liveFlushTask != nil { return }
        liveFlushTask = Task {
            await flushLive()
            liveFlushTask = nil
        }
    }

    private func flushLive() async {
        guard let cloud else { return }
        do {
            while var journal = liveJournal, let segment = journal.pending.first {
                let directory = try liveDirectory()
                let file = URL(fileURLWithPath: segment.path)
                guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                      [2, 5, 10, 20].contains(journal.windowSeconds),
                      segment.index == journal.uploaded, segment.frames > 0,
                      segment.frames <= journal.windowSeconds * 50,
                      journal.endpoint == cloud.origin.absoluteString,
                      let fromSequence = journal.fromSequence else { throw CloudError.invalidResponse }
                let bytes = try Data(contentsOf: file)
                if journal.sessionId == nil {
                    let source = RecordingReference(deviceId: journal.deviceId, sourceId: journal.captureId, title: journal.title)
                    let session = try await cloud.liveBegin(source: source, originalSourceId: journal.originalId,
                        startMs: Int(fromSequence) * 20, windowMs: journal.windowSeconds * 1000)
                    journal.sessionId = session.session_id
                    liveJournal = journal
                    try persistLive()
                }
                try await cloud.livePut(sessionId: journal.sessionId!, index: segment.index,
                                        audio: bytes, durationMs: segment.frames * 20)
                journal.pending.removeFirst()
                journal.uploaded += 1
                liveJournal = journal
                try persistLive()
                try FileManager.default.removeItem(at: file)
                liveStatus = "实时音频已上传 \(journal.uploaded) 段；转写在后台继续"
            }
        } catch {
            liveStatus = "实时上传暂时中断：\(error.localizedDescription)；片段已保留"
        }
    }

    func refreshLive() async {
        guard let cloud, let session = liveJournal?.sessionId else { return }
        do {
            let state = try await cloud.liveStatus(sessionId: session)
            liveText = state.text
            let pending = state.segments.filter { $0.status == "queued" || $0.status == "running" }.count
            liveStatus = "已上传 \(Double(state.received_ms) / 1000) 秒 · 待转写 \(pending) 段"
        } catch { liveStatus = "实时草稿状态暂时不可用，音频片段保留" }
    }

    func recoverLive() async {
        guard let cloud else { liveStatus = "请先连接服务器"; return }
        do {
            let directory = try liveDirectory()
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("live-journal-") && $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            for file in files {
                let journal = try JSONDecoder().decode(LiveJournal.self, from: Data(contentsOf: file))
                guard journal.version == 1, journal.endpoint == cloud.origin.absoluteString else { continue }
                if journal.completed { continue }
                liveJournal = journal; liveJournalURL = file
                await flushLive()
                if liveJournal?.deviceEnded == true, liveJournal?.pending.isEmpty == true,
                   let sessionId = liveJournal?.sessionId {
                    let matches = try await cloud.recordings()
                    if let archived = matches.first(where: { $0.stored && $0.source_id == journal.originalId &&
                        ($0.device_id == journal.deviceId || $0.source_devices.contains(journal.deviceId)) }) {
                        _ = try await cloud.liveFinish(sessionId: sessionId, recordingId: archived.id,
                            count: liveJournal?.uploaded ?? 0)
                        liveJournal?.completed = true
                        try persistLive()
                    }
                }
            }
            liveStatus = "待上传草稿已检查；完整归档仍以设备原件校验为准"
        } catch { liveStatus = "恢复草稿失败：\(error.localizedDescription)；手机数据保留" }
    }
}
#endif
