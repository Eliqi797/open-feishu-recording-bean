#if os(iOS)
import SwiftUI
import UIKit
import RecordingBeanCore

@main
struct RecordingBeanApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showDeviceControls = false
    private var shouldKeepAwake: Bool {
        model.keepAwake
    }
    private var displayMessage: String {
        if model.reconnecting && model.message.contains("NSURLErrorDomain error -1001") {
            return "设备暂时未响应，正在重连"
        }
        return model.message
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                DeviceStatusBar(model: model) {
                    selectedTab = 0
                    showDeviceControls = true
                }
                if !displayMessage.isEmpty {
                    Text(displayMessage)
                        .font(.caption)
                        .foregroundStyle(BeanPalette.muted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 7)
                        .background(BeanPalette.inset)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                TabView(selection: $selectedTab) {
                    RecordingsView(model: model, showDeviceControls: $showDeviceControls)
                    .tabItem { Label("录音", systemImage: "waveform") }.tag(0)
                LiveView(model: model)
                    .tabItem { Label("实时", systemImage: "dot.radiowaves.left.and.right") }.tag(1)
                SettingsView(model: model)
                    .tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
                }
                .tint(BeanPalette.accent)
                .toolbarBackground(BeanPalette.surface, for: .tabBar)
            }
            .background(BeanPalette.background)
            .tint(BeanPalette.accent)
            .preferredColorScheme(model.themeMode == "light" ? .light : model.themeMode == "dark" ? .dark : nil)
            .onChange(of: scenePhase) { _, phase in
                UIApplication.shared.isIdleTimerDisabled = phase == .active && shouldKeepAwake
            }
            .onChange(of: model.keepAwake) { _, _ in
                UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && shouldKeepAwake
            }
            .sheet(item: $model.manualHotspotRequest, onDismiss: model.cancelManualHotspotJoin) { request in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("录音豆已开启临时 Wi-Fi。请打开 iPhone「设置 → 无线局域网」，加入下面的网络，随后回到这里继续传输。")
                        LabeledContent("网络名称", value: request.ssid)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("密码").foregroundStyle(.secondary)
                            Text(request.password).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("复制密码", systemImage: "doc.on.doc") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": request.password]], options: [
                                .localOnly: true, .expirationDate: Date().addingTimeInterval(300)
                            ])
                        }
                        .buttonStyle(.bordered)
                        Text("每批录音只需加入一次；传完后录音豆会关闭这个热点。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("我已加入热点，继续") { model.confirmManualHotspotJoin() }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(20)
                    .navigationTitle("连接录音豆热点")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消传输") { model.cancelManualHotspotJoin() }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
            .task {
                UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && shouldKeepAwake
                await model.restoreConnection()
                await model.refreshCloud()
                await model.loadProviderSettings()
                if model.autoUpload {
                    await model.resumeCachedUploads()
                    await model.recoverLive()
                }
            }
        }
    }
}

private enum BeanPalette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let background = dynamic(0xF4F7F7, 0x101719)
    static let surface = dynamic(0xFFFFFF, 0x1B272A)
    static let ink = dynamic(0x162C30, 0xEDF5F4)
    static let muted = dynamic(0x536C70, 0xAABDBF)
    static let accent = dynamic(0x077568, 0x65DBC9)
    static let line = dynamic(0xDFE8E8, 0x304246)
    static let inset = dynamic(0xEAF2F1, 0x243639)
    static let attention = dynamic(0x9B430D, 0xFFBC89)
}

private struct BeanCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(BeanPalette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DeviceStatusBar: View {
    @ObservedObject var model: AppModel
    let onManage: () -> Void
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3).foregroundStyle(BeanPalette.accent)
                    .accessibilityHidden(true)
                Text("录音豆").font(.subheadline.weight(.semibold)).foregroundStyle(BeanPalette.ink)
                Spacer()
                Text(model.status == nil ? (model.reconnecting ? "正在重连" : "未连接") :
                     (model.liveRunning ? "实时记录" : model.status?.recording == 1 ? "正在录音" : "已连接"))
                    .font(.caption).foregroundStyle(model.status == nil ? BeanPalette.muted : BeanPalette.accent)
                Button(model.status == nil ? "连接" : "管理", action: onManage)
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: 48, minHeight: 44)
            }
            HStack {
                Text("设备 \(model.status?.battery.map { "\($0)%" } ?? "--")\(model.status?.charging == true ? " · 充电中" : "")")
                Spacer()
                Text("充电盒 \(model.status?.caseBattery.map { "\($0)%" } ?? "--")\(model.status?.caseCharging == true ? " · 充电中" : "")")
            }
            .font(.caption).foregroundStyle(BeanPalette.muted)
        }
        .padding(.horizontal, 20).padding(.bottom, 9).padding(.top, 2)
        .background(BeanPalette.surface)
        .overlay(alignment: .bottom) { BeanPalette.line.frame(height: 1) }
    }
}

private struct PlaybackControls: View {
    @ObservedObject var model: AppModel
    let recording: CloudRecording
    @State private var seeking = false
    @State private var seekPosition = 0.0

    private func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0))
        if whole >= 3600 {
            return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Button(model.playingRecordingId == recording.id && !model.playbackPaused ? "暂停" : "播放",
                       systemImage: model.playingRecordingId == recording.id && !model.playbackPaused ? "pause.fill" : "play.fill") {
                    Task { await model.togglePlayback(recording) }
                }
                if model.playingRecordingId == recording.id {
                    Button("停止", systemImage: "stop.fill") { model.stopPlayback() }
                    Button("后退 15 秒", systemImage: "gobackward.15") {
                        model.seekPlayback(to: model.playbackPosition - 15)
                    }.labelStyle(.iconOnly)
                    Button("前进 30 秒", systemImage: "goforward.30") {
                        model.seekPlayback(to: model.playbackPosition + 30)
                    }.labelStyle(.iconOnly)
                }
            }
            if model.playingRecordingId == recording.id {
                Slider(value: Binding(
                    get: { seeking ? seekPosition : min(model.playbackPosition, max(model.playbackDuration, 1)) },
                    set: { seekPosition = $0 }),
                    in: 0...max(model.playbackDuration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            seekPosition = model.playbackPosition
                        } else {
                            model.seekPlayback(to: seekPosition)
                        }
                        seeking = editing
                    })
                    .disabled(model.playbackDuration <= 0)
                    .accessibilityLabel("播放位置")
                HStack {
                    Text(clock(seeking ? seekPosition : model.playbackPosition))
                    Spacer()
                    Text(clock(model.playbackDuration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecordingsView: View {
    @ObservedObject var model: AppModel
    @Binding var showDeviceControls: Bool
    @Environment(\.openURL) private var openURL
    @State private var transcriptPage = 0
    @State private var detailTab = 0

    private func duration(_ milliseconds: UInt32) -> String {
        let seconds = Int(milliseconds) / 1000
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func date(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(.dateTime.year().month().day().hour().minute())
    }
    private func documentLink(_ id: String) -> URL? {
        guard id.range(of: "^[A-Za-z0-9_-]{8,100}$", options: .regularExpression) != nil,
              let base = URLComponents(string: model.feishuDocsOrigin), base.scheme == "https",
              let host = base.host, base.port == nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/",
              host == "feishu.cn" || host.hasSuffix(".feishu.cn") || host == "larksuite.com" || host.hasSuffix(".larksuite.com"),
              let document = URL(string: model.feishuDocsOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/docx/\(id)") else { return nil }
        var link = URLComponents(string: "https://applink.feishu.cn/client/docs/open")
        link?.queryItems = [URLQueryItem(name: "url", value: document.absoluteString)]
        return link?.url
    }
    private func verifiedDocument(_ recording: CloudRecording) -> URL? {
        guard let id = recording.publications.first(where: { $0.part == 0 && $0.status == "verified" })?.document_id else { return nil }
        return documentLink(id)
    }
    private func showDetails(_ recording: CloudRecording) {
        transcriptPage = 0
        detailTab = 0
        Task { await model.selectRecording(recording) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let selected = model.selectedRecording { detail(selected) }
                else { library }
            }
            .padding(20)
        }
        .background(BeanPalette.background)
    }
    private var library: some View {
        Group {
            HStack(alignment: .firstTextBaseline) {
                Text("录音").font(.largeTitle.bold()).foregroundStyle(BeanPalette.ink)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refreshCloud() } }
                    .font(.subheadline)
            }
            if showDeviceControls { deviceControls }
            transferCard
            if !model.pendingDeviceFiles.isEmpty { pendingFiles }
            HStack {
                Text("云端录音").font(.headline).foregroundStyle(BeanPalette.ink)
                Spacer()
                Text("\(model.cloudRecordings.count) 条").font(.subheadline).foregroundStyle(BeanPalette.muted)
            }
            if model.cloudRecordings.isEmpty {
                BeanCard { ContentUnavailableView("暂无录音", systemImage: "waveform", description: Text("连接录音豆后同步录音")) }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.cloudRecordings) { recording in
                        cloudRow(recording)
                        if recording.id != model.cloudRecordings.last?.id {
                            BeanPalette.line.frame(height: 1).padding(.leading, 18)
                        }
                    }
                }
                .background(BeanPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var deviceControls: some View {
        BeanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("设备连接").font(.headline).foregroundStyle(BeanPalette.ink)
                    Spacer()
                    Button("收起", systemImage: "chevron.up") { showDeviceControls = false }.font(.subheadline)
                }
                Button("扫描录音豆", systemImage: "antenna.radiowaves.left.and.right") { Task { await model.scan() } }
                    .buttonStyle(.bordered).disabled(model.busy)
                ForEach(model.discovered, id: \.identifier) { device in
                    Button(device.name?.isEmpty == false ? device.name! : "录音豆") {
                        Task { await model.connect(device) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .disabled(model.busy)
                }
                if model.status != nil || model.reconnecting {
                    Button("断开录音豆", systemImage: "power") { Task { await model.disconnect() } }
                        .font(.subheadline).disabled(model.busy)
                }
            }
        }
    }
    private var transferCard: some View {
        BeanCard {
            VStack(alignment: .leading, spacing: 13) {
                if model.progress > 0 && model.progress < 1 {
                    HStack {
                        Text("正在传输").font(.headline).foregroundStyle(BeanPalette.ink)
                        Spacer()
                        Text(model.speed).font(.subheadline.monospacedDigit()).foregroundStyle(BeanPalette.accent)
                    }
                    ProgressView(value: model.progress).tint(BeanPalette.accent)
                    Text("\(Int(model.progress * 100))% · 完成云端校验后清理手机缓存")
                        .font(.caption).foregroundStyle(BeanPalette.muted)
                } else {
                    Toggle(isOn: Binding(get: { model.autoUpload }, set: model.setAutoUpload)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动上传").font(.headline).foregroundStyle(BeanPalette.ink)
                            Text("连接设备后同步新录音").font(.caption).foregroundStyle(BeanPalette.muted)
                        }
                    }
                    .tint(BeanPalette.accent)
                    BeanPalette.line.frame(height: 1)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("同步设备录音").font(.subheadline.weight(.medium)).foregroundStyle(BeanPalette.ink)
                            Text("一次连接，批量同步").font(.caption).foregroundStyle(BeanPalette.muted)
                        }
                        Spacer(minLength: 0)
                        Button("高速传输", systemImage: "bolt.fill") { Task { await model.syncAll() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.status == nil || model.busy)
                    }
                }
                Button("恢复本机缓存上传", systemImage: "arrow.up.doc") { Task { await model.resumeCachedUploads() } }
                    .font(.caption).disabled(model.busy)
            }
        }
    }
    private var pendingFiles: some View {
        Group {
            Text("待同步录音 · \(model.pendingDeviceFiles.count)")
                .font(.headline).foregroundStyle(BeanPalette.ink)
            BeanCard {
                VStack(spacing: 14) {
                    ForEach(model.pendingDeviceFiles, id: \.id) { file in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(date(Double(file.id))).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(duration(file.durationMs)).font(.caption).foregroundStyle(BeanPalette.muted)
                            }
                            HStack {
                                Button("下载到手机") { Task { await model.downloadOnly(file) } }
                                Button("上传云端") { Task { await model.syncAll(only: file.id) } }
                                    .disabled(model.origin.isEmpty || model.token.isEmpty)
                            }
                            .font(.caption).disabled(model.status == nil || model.busy)
                        }
                        if file.id != model.pendingDeviceFiles.last?.id { BeanPalette.line.frame(height: 1) }
                    }
                }
            }
        }
    }
    private func cloudRow(_ recording: CloudRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(date(recording.recorded_at ?? recording.created))
                .font(.caption).foregroundStyle(BeanPalette.muted)
            Button {
                if let url = verifiedDocument(recording) { openURL(url) }
                else { showDetails(recording) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(recording.title).font(.headline).foregroundStyle(BeanPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: verifiedDocument(recording) == nil ? "chevron.right" : "arrow.up.right")
                        .font(.caption).foregroundStyle(BeanPalette.muted)
                }
            }
            Text(recording.stored ? "云端已保存" : "上传未完成")
                .font(.caption).foregroundStyle(BeanPalette.muted)
            HStack(spacing: 16) {
                if recording.stored {
                    Button("回听与详情", systemImage: "play.circle") { showDetails(recording) }
                }
                if let url = verifiedDocument(recording) {
                    Button("飞书文档", systemImage: "arrow.up.right.square") { openURL(url) }
                } else if recording.stored {
                    Button("继续处理") { Task { await model.startPipeline(recording) } }
                }
            }
            .font(.subheadline)
            if let failed = recording.jobs.first(where: { $0.status == "failed" || $0.status == "blocked" }) {
                Text("\(failed.stage)：\(failed.status)").font(.caption).foregroundStyle(BeanPalette.attention)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detail(_ selected: CloudRecording) -> some View {
        Group {
            Button("返回录音列表", systemImage: "chevron.left") { model.closeDetails() }
                .frame(minHeight: 44)
            Text(date(selected.recorded_at ?? selected.created))
                .font(.subheadline).foregroundStyle(BeanPalette.muted)
            Text(selected.title).font(.title2.bold()).foregroundStyle(BeanPalette.ink)
            BeanCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("录音回听").font(.headline).foregroundStyle(BeanPalette.ink)
                    if selected.stored { PlaybackControls(model: model, recording: selected) }
                    else { Text("上传尚未完成").foregroundStyle(BeanPalette.muted) }
                    if let url = verifiedDocument(selected) {
                        Button("打开飞书文档", systemImage: "arrow.up.right.square") { openURL(url) }
                    }
                }
            }
            Picker("查看内容", selection: $detailTab) {
                Text("总结").tag(0); Text("转写").tag(1); Text("处理状态").tag(2)
            }
            .pickerStyle(.segmented)
            BeanCard {
                VStack(alignment: .leading, spacing: 12) {
                    if detailTab == 0 {
                        Text(model.summaryText.isEmpty ? "总结尚未生成，可在处理状态中继续任务。" : model.summaryText)
                            .textSelection(.enabled)
                    } else if detailTab == 1 {
                        let transcript = model.transcriptText
                        Text(transcript.isEmpty ? "转写尚未生成。" : String(transcript.dropFirst(transcriptPage * 4000).prefix(4000)))
                            .textSelection(.enabled)
                        if transcript.count > 4000 {
                            HStack {
                                Button("上一页") { transcriptPage = max(0, transcriptPage - 1) }
                                    .disabled(transcriptPage == 0)
                                Spacer()
                                Text("第 \(transcriptPage + 1) 页").foregroundStyle(BeanPalette.muted)
                                Spacer()
                                Button("下一页") { transcriptPage += 1 }
                                    .disabled((transcriptPage + 1) * 4000 >= transcript.count)
                            }
                        }
                    } else {
                        ForEach(selected.jobs, id: \.stage) { job in
                            Text("\(job.stage)：\(job.status)\(job.error.map { " · \($0)" } ?? "")")
                        }
                        Button("继续处理 / 重试") { Task { await model.retrySelected() } }
                            .disabled(model.detailBusy || !selected.stored)
                    }
                }
                .foregroundStyle(BeanPalette.ink)
            }
            Button("刷新处理结果", systemImage: "arrow.clockwise") { Task { await model.refreshDetails() } }
                .disabled(model.detailBusy)
        }
    }
}

private struct LiveView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("实时").font(.largeTitle.bold()).foregroundStyle(BeanPalette.ink)
                BeanCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.largeTitle).foregroundStyle(BeanPalette.accent)
                        Text("边录边看文字").font(.title3.bold()).foregroundStyle(BeanPalette.ink)
                        Text("录音豆正在录音时，可以接收实时片段。结束后草稿会继续上传处理。")
                            .font(.subheadline).foregroundStyle(BeanPalette.muted)
                        Text(model.liveStatus).font(.subheadline).foregroundStyle(BeanPalette.ink)
                        Picker("转写窗口", selection: Binding(get: { model.liveWindowSeconds }, set: model.setLiveWindow)) {
                            ForEach([2, 5, 10, 20], id: \.self) { Text("\($0) 秒").tag($0) }
                        }
                        .disabled(model.liveRunning)
                        if model.liveRunning {
                            Button("停止接收并保留草稿", role: .destructive) { model.stopLive() }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        } else {
                            Button("开始实时记录", systemImage: "record.circle") { model.startLive() }
                                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                                .disabled(model.status?.recording != 1 || model.currentRecordingId == nil || model.busy)
                        }
                        Button("恢复草稿上传") { Task { await model.recoverLive() } }
                            .font(.subheadline).disabled(model.liveRunning)
                    }
                }
                if !model.liveText.isEmpty {
                    Text("实时转写草稿").font(.headline).foregroundStyle(BeanPalette.ink)
                    BeanCard { Text(model.liveText).foregroundStyle(BeanPalette.ink).textSelection(.enabled) }
                }
            }
            .padding(20)
        }
        .background(BeanPalette.background)
        .task {
            while !Task.isCancelled {
                await model.refreshLive()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section = ""
    @State private var iconChoice = "white"
    @State private var iconError: String?

    private var sectionTitle: String {
        switch section {
        case "server": "服务连接"
        case "appearance": "外观与图标"
        case "asr": "语音转写"
        case "llm": "智能总结"
        case "feishu": "飞书文档"
        case "advanced": "处理与传输"
        default: "设置"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(BeanPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func settingField(
        _ title: String,
        value: Binding<String>,
        placeholder: String,
        help: String? = nil,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(BeanPalette.ink)
            if secure {
                SecureField(placeholder, text: value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: value)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let help { note(help) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func clearSecret(_ key: String) -> some View {
        if model.configuredSecrets[key] == true {
            Button(model.clearSecrets.contains(key) ? "撤销清除密钥" : "保存时清除已存密钥") {
                model.toggleSecretClear(key)
            }
            .font(.subheadline)
            if model.clearSecrets.contains(key) {
                note("尚未清除；点下方“保存服务设置”后才会生效。")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !section.isEmpty {
                    Button("返回设置", systemImage: "chevron.left") { section = "" }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("返回设置")
                }
                Text(sectionTitle).font(.largeTitle.bold()).foregroundStyle(BeanPalette.ink)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            Form {
                if section.isEmpty { overview }
                if section == "server" { serverSettings }
                if section == "appearance" { appearanceSettings }
                if section == "asr" { asrSettings }
                if section == "llm" { llmSettings }
                if section == "feishu" { feishuSettings }
                if section == "advanced" { advancedSettings }
                if !section.isEmpty && section != "server" && section != "appearance" { saveActions }
            }
            .id(section)
            .scrollContentBackground(.hidden)
            .background(BeanPalette.background)
            .tint(BeanPalette.accent)
        }
        .background(BeanPalette.background)
        .onAppear {
            iconChoice = UIApplication.shared.alternateIconName == "AppIconBlack" ? "black" : "white"
        }
    }

    private func changeIcon(to choice: String) {
        guard UIApplication.shared.supportsAlternateIcons else {
            iconError = "当前系统不支持切换 App 图标。"
            return
        }
        UIApplication.shared.setAlternateIconName(choice == "black" ? "AppIconBlack" : nil) { error in
            Task { @MainActor in
                iconChoice = UIApplication.shared.alternateIconName == "AppIconBlack" ? "black" : "white"
                iconError = error?.localizedDescription
            }
        }
    }

    @ViewBuilder private var overview: some View {
        Section("常用") {
            settingsRow("服务连接", model.origin.isEmpty ? "填写录音保存与处理服务器" : "已填写服务器地址", "server", icon: "server.rack")
            settingsRow("外观与图标", "深浅色及黑白录音豆图标", "appearance", icon: "paintbrush")
        }
        Section("服务与处理") {
            settingsRow("语音转写", "将录音变成文字", "asr", icon: "waveform")
            settingsRow("智能总结", "生成标题、摘要和待办", "llm", icon: "text.alignleft")
            settingsRow("飞书文档", "选择写入账号与文件夹", "feishu", icon: "doc.text")
            settingsRow("处理与传输", "自动上传及高级参数", "advanced", icon: "slider.horizontal.3")
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        Section("显示模式 · 保存在本机") {
            Picker("界面颜色", selection: Binding(get: { model.themeMode }, set: model.setThemeMode)) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
        }
        Section("App 图标") {
            Picker("设备颜色", selection: Binding(get: { iconChoice }, set: changeIcon)) {
                Text("白色").tag("white")
                Text("黑色").tag("black")
            }
            .pickerStyle(.segmented)
            note("使用录音豆原有的透明底图标；切换时 iOS 会弹出确认提示。")
            if let iconError { note(iconError) }
        }
    }

    @ViewBuilder private var serverSettings: some View {
        Section { note("音频先上传到这台服务器，再由它转写、总结并写入飞书。地址必须使用 HTTPS。") }
        Section("连接信息") {
            settingField("服务器地址", value: $model.origin, placeholder: "https://recorder.example.com", keyboard: .URL)
            settingField("访问口令", value: $model.token, placeholder: "服务器设置的访问口令", help: "只用于访问你的录音服务，验证成功后保存在 iPhone 钥匙串。", secure: true)
            Button("验证并保存连接") { Task { await model.saveConnection() } }
        }
    }

    @ViewBuilder private var asrSettings: some View {
        Section { note("语音转写把音频变成文字。选择服务后，只影响新开始的处理任务；已完成录音不会自动重新转写。") }
        Section("转写服务 · 保存在服务器") {
            Picker("使用哪个转写服务", selection: Binding(get: { model.asrProvider }, set: { value in
                if value != model.asrProvider { model.asrKey = "" }
                model.asrProvider = value
            })) {
                Text("NVIDIA Parakeet 中文").tag("nvidia_parakeet")
                Text("NVIDIA Whisper").tag("nvidia_whisper")
                Text("OpenAI 兼容接口").tag("openai_compatible")
            }
            note("Parakeet 用于中文；Whisper 可作对照。两种 NVIDIA 方案调用云端 API，手机无需安装模型。")
            if model.asrProvider == "openai_compatible" {
                settingField("兼容接口地址", value: $model.asrBaseURL, placeholder: "https://api.example.com/v1", help: "填写 API 基础地址；服务器会请求其 /audio/transcriptions 接口。", keyboard: .URL)
                settingField("模型名称", value: $model.asrModel, placeholder: "例如 whisper-1")
                Picker("返回结果格式", selection: $model.asrResponseFormat) {
                    Text("详细 JSON（请求时间戳）").tag("verbose_json")
                    Text("基础 JSON").tag("json")
                }
                note("详细格式会请求时间戳；是否返回以及精度取决于所选接口。")
            }
            settingField("识别语言", value: $model.asrLanguage, placeholder: "zh-CN", help: "例如 zh-CN；选 NVIDIA Whisper 或兼容接口时，服务端会使用 zh。")
            if model.asrProvider != "openai_compatible" {
                settingField("专业词汇", value: $model.asrHotwords, placeholder: "多个词用英文逗号分开", help: "作为识别提示发送给 NVIDIA；接口可能忽略，不保证每个词都识别正确。")
            }
            settingField("转写服务密钥", value: $model.asrKey, placeholder: "留空则保留服务器已保存的密钥", help: "只保存到你的服务器，App 不回显现有密钥。", secure: true)
            clearSecret(model.asrProvider == "openai_compatible" ? "ASR_API_KEY" : "NVIDIA_API_KEY")
        }
        Section("实时转写 · 保存在本机") {
            Picker("每段音频时长", selection: Binding(get: { model.liveWindowSeconds }, set: model.setLiveWindow)) {
                ForEach([2, 5, 10, 20], id: \.self) { Text("\($0) 秒").tag($0) }
            }
            .disabled(model.liveRunning)
            note("越短通常越早开始识别，但句子更容易被拆开；下次开始实时记录时生效。")
        }
    }

    @ViewBuilder private var llmSettings: some View {
        Section { note("总结服务根据转写生成一句话标题、摘要、结论和待办。需要兼容 OpenAI Chat Completions 的 HTTPS 接口。") }
        Section("总结模型 · 保存在服务器") {
            settingField("接口地址", value: $model.llmBaseURL, placeholder: "https://api.example.com/v1", help: "填写 API 基础地址；换服务时也要填写新服务的密钥。", keyboard: .URL)
            settingField("模型名称", value: $model.llmModel, placeholder: "填写服务商提供的模型 ID")
            settingField("总结服务密钥", value: $model.llmKey, placeholder: "留空则保留服务器已保存的密钥", help: "只保存到你的服务器，App 不回显现有密钥。", secure: true)
            clearSecret("LLM_API_KEY")
        }
    }

    @ViewBuilder private var feishuSettings: some View {
        Section { note("处理完成后由服务器创建飞书文档。服务器会验证所选凭据；使用个人身份时还会核对 Open ID，避免误写到其他账号。") }
        Section("写入身份 · 保存在服务器") {
            Picker("用谁的身份写文档", selection: Binding(get: { model.feishuAuthMode }, set: { value in
                if value != model.feishuAuthMode { model.feishuPersonalConfirmed = false }
                model.feishuAuthMode = value
            })) {
                Text("服务器已登录的飞书账号").tag("lark_cli")
                Text("飞书自建应用").tag("app")
                Text("手动用户令牌").tag("user_token")
            }
            if model.feishuAuthMode == "lark_cli" {
                note("使用服务器上飞书 CLI 已登录的账号；手机不会切换飞书身份。")
                settingField("服务器飞书配置名", value: $model.feishuCliProfile, placeholder: "留空使用服务器默认配置", help: "仅当服务器上有多个飞书 CLI 配置时需要填写。")
            } else if model.feishuAuthMode == "app" {
                note("以飞书自建应用的身份创建文档；应用需要目标文件夹权限。")
                settingField("应用 App ID", value: $model.feishuAppId, placeholder: "cli_…")
                settingField("应用 App Secret", value: $model.feishuAppSecret, placeholder: "留空保留已存密钥", secure: true)
                clearSecret("FEISHU_APP_SECRET")
            } else {
                note("使用手动提供的用户令牌；令牌过期后需更新。")
                settingField("用户访问令牌", value: $model.feishuUserToken, placeholder: "留空保留已存令牌", secure: true)
                clearSecret("FEISHU_USER_ACCESS_TOKEN")
            }
            if model.feishuAuthMode != "app" {
                settingField("目标用户 Open ID", value: $model.feishuExpectedOpenId, placeholder: "ou_…", help: "服务器会与实际登录用户比对；不一致时拒绝写入。")
            }
            Toggle("我已确认写入身份", isOn: $model.feishuPersonalConfirmed)
            note("更换写入方式后需重新确认；未确认时服务器不会发布文档。")
        }
        Section("文档位置与链接") {
            settingField("目标文件夹 Token（可选）", value: $model.feishuFolderToken, placeholder: "留空使用该身份默认位置", help: "来自飞书文件夹链接中的标识；所选身份必须有该文件夹的写入权限。")
            settingField("飞书文档域名", value: $model.feishuDocsOrigin, placeholder: "https://www.feishu.cn", help: "只用于生成打开文档的链接，不会更改写入账号。", keyboard: .URL)
        }
    }

    @ViewBuilder private var advancedSettings: some View {
        Section("自动化 · 本机与服务器") {
            Toggle("连接后自动上传新录音", isOn: Binding(get: { model.autoUpload }, set: model.setAutoUpload))
            note("保存在这台 iPhone；App 连接录音豆并发现已结束的新录音时自动同步。")
            Toggle("上传后自动转写、总结并写入飞书", isOn: $model.autoPipeline)
            note("保存在服务器；关闭后可在录音详情中手动继续处理。")
            Toggle("App 在前台时保持屏幕常亮", isOn: Binding(get: { model.keepAwake }, set: model.setKeepAwake))
            note("保存在这台 iPhone；只在 App 位于前台时生效。")
        }
        Section("长录音处理 · 高级") {
            settingField("每段转写长度（秒）", value: $model.asrChunkSeconds, placeholder: "120", help: "长录音按此长度分段，范围 10–300 秒；NVIDIA Whisper 最长按 60 秒处理。", keyboard: .numberPad)
            settingField("识别等待上限（秒）", value: $model.nvidiaTimeoutSeconds, placeholder: "1800", help: "单次 NVIDIA 请求最多等待多久，范围 10–3600 秒；不是整条录音的总时长。", keyboard: .numberPad)
        }
        Section("说话人区分 · 高级") {
            settingField("最多区分几位说话人", value: $model.nvidiaMaxSpeakers, placeholder: "8", help: "向 NVIDIA 请求的上限，范围 1–8；不保证实际能识别这么多人。", keyboard: .numberPad)
            Picker("编号 0 如何处理", selection: $model.nvidiaSpeakerZeroPolicy) {
                Text("当作未知说话人（推荐）").tag("unknown")
                Text("当作第 1 位说话人").tag("zero_based")
            }
            note("默认保守处理。只有实测确认模型用 0 表示第一位说话人时，才选择第二项；编号不代表真实身份。")
        }
        Section("飞书文档时间") {
            settingField("录制时间显示时区", value: $model.documentTimezone, placeholder: "Asia/Shanghai", help: "决定文档中录制日期和时间的显示方式，不改变音频内容。")
        }
        Section { note("上述服务器参数在新处理任务开始时生效；正在处理或已完成的录音不会自动重做。") }
    }

    @ViewBuilder private var saveActions: some View {
        Section {
            if !model.settingsLoaded {
                note("尚未读取服务器设置。请先连接服务器，再点下方重新读取。")
            }
            Button("保存服务器设置") { Task { await model.saveProviderSettings() } }
                .disabled(!model.settingsLoaded)
            Button("重新读取服务器设置") { Task { await model.loadProviderSettings() } }
        }
    }

    private func settingsRow(_ title: String, _ subtitle: String, _ key: String, icon: String) -> some View {
        Button { section = key } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(BeanPalette.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(BeanPalette.ink)
                    Text(subtitle).font(.caption).foregroundStyle(BeanPalette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(BeanPalette.muted)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
