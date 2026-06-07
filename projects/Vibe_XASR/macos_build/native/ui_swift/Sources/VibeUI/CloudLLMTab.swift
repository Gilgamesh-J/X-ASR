import SwiftUI
import AppKit

// 「AI 功能」标签完整视图:本地润色 + 云端大模型(服务商/Key/模型/测试连接)+ 处理项 + Prompt 模板工作室。
// 1:1 还原 云端llm「大模型设置」设计。

// MARK: - 小工具

private extension View {
    func sectionLabel(_ scheme: ColorScheme) -> some View {
        self.font(Vibe.Fonts.ui(12.5, weight: .medium))
            .foregroundStyle(Vibe.Palette.textMuted(scheme))
            .padding(.leading, 4).padding(.top, 22).padding(.bottom, 10)
    }
    func cloudFade(_ on: Bool) -> some View { self.opacity(on ? 1 : 0.4).allowsHitTesting(on) }
}

/// 光标处可插入占位符的多行编辑器(SwiftUI TextEditor 不支持插入到光标,用 NSTextView)。
final class CloudPromptCoordinator: NSObject, NSTextViewDelegate {
    var onChange: (String) -> Void = { _ in }
    weak var textView: NSTextView?
    func textDidChange(_ n: Notification) { if let tv = n.object as? NSTextView { onChange(tv.string) } }
    func insert(_ token: String) {
        guard let tv = textView else { return }
        tv.insertText(token, replacementRange: tv.selectedRange())
        onChange(tv.string)
    }
}
struct CloudPromptEditor: NSViewRepresentable {
    @Binding var text: String
    var coordinator: CloudPromptCoordinator
    var editable: Bool = true   // 锁定模板(自动 / 口语转书面)时只读
    func makeCoordinator() -> CloudPromptCoordinator { coordinator }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false; tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textColor = NSColor(white: 0.82, alpha: 1); tv.backgroundColor = .clear
        tv.drawsBackground = false; tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.string = text
        tv.isEditable = editable; tv.isSelectable = true   // 只读时仍可选中复制
        context.coordinator.textView = tv
        context.coordinator.onChange = { text = $0 }
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = editable
        tv.textColor = NSColor(white: editable ? 0.82 : 0.55, alpha: 1)   // 只读稍暗
    }
}

// MARK: - 主视图

struct LLMTab: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    /// 本地 refiner GGUF 的下载状态(进度 / 就绪 / 来源)经此 relay 实时刷新。
    @StateObject var relay: ModelManagerRelay
    @Environment(\.colorScheme) private var scheme

    @State private var cfg: CloudConfigDTO
    @State private var showKey = false
    @State private var testing = false
    @State private var test: CloudTestResult?
    // 自定义服务商态
    @State private var customProviders: [CloudCustomProvider]
    @State private var showProviderMenu = false
    @State private var providerEditor: CloudCustomProvider?   // 非 nil = 正在新增/编辑
    @State private var isNewProvider = false
    // 已保存配置(命名快照,一键切换)
    @State private var profiles: [CloudProfile]
    @State private var editingProfileId: String?
    // 最近请求(排查)
    @State private var reqLog: [CloudReqLogEntry] = []
    @State private var copiedId: UUID?   // 刚复制成 Issue 的那条(短暂高亮)
    // 非 nil = 用户想开启润色("cloud"/"local")但当前听写模式冲突,弹窗征询切换。
    @State private var pendingEnable: String?
    private let logTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(s: SettingsState, l10n: L10n, relay: ModelManagerRelay) {
        self.s = s; self.l10n = l10n
        _relay = StateObject(wrappedValue: relay)
        _cfg = State(initialValue: s.cloud)
        _customProviders = State(initialValue: CloudCustomProviders.decode(s.cloud.customProvidersJSON))
        _profiles = State(initialValue: CloudProfiles.decode(s.cloud.profilesJSON))
    }

    /// 当前服务商:内置 → 预设;自定义 → 由用户条目合成(模型预设留空,手填)。
    private var prov: CloudProviderUI {
        if !CloudProvidersUI.isBuiltin(cfg.provider),
           let c = customProviders.first(where: { $0.id == cfg.provider }) {
            return CloudProviderUI(key: c.id, label: c.label, mark: String(c.label.prefix(1)).uppercased(),
                                   cls: "custom", desc: l10n.t("llm.custom"), baseURL: c.baseURL,
                                   keyHint: "API Key", modelLabel: l10n.t("llm.field.modelOrEndpoint"), defaultModel: "",
                                   models: [], price: l10n.t("llm.price.perToken"))
        }
        return CloudProvidersUI.find(cfg.provider)
    }
    private func commit() {
        cfg.customProvidersJSON = CloudCustomProviders.encode(customProviders)
        cfg.profilesJSON = CloudProfiles.encode(profiles)
        // 模板由「提示词工作室」管理,提交时取最新 store 值(可能来自独立窗口),避免覆盖其编辑。
        let live = s.liveCloud ?? s.cloud
        cfg.templatesJSON = live.templatesJSON
        cfg.activeTemplate = live.activeTemplate
        s.applyCloud(cfg)
    }
    private func setEnabled(_ on: Bool) {
        cfg.enabled = on
        if on, s.refiner { s.applyRefiner(false) }   // 云端 ⟂ 本地:开云端 → 关本地
        commit()
    }
    /// 本地润色开启(含云端 ⟂ 本地互斥)。
    private func enableLocal() {
        if cfg.enabled { cfg.enabled = false; commit() }   // 开本地 → 关云端
        s.applyRefiner(true)
    }

    // ===== 开启润色:若当前听写模式与「说完插入」冲突,先弹窗征询切换 =====
    private func requestEnable(_ which: String) {
        if s.insert == "paste" { doEnable(which) }   // 不冲突,直接开
        else { pendingEnable = which }               // 冲突 → 弹窗
    }
    private func doEnable(_ which: String) {
        if which == "cloud" { setEnabled(true) } else { enableLocal() }
    }
    /// 弹窗点「切换并开启」:先切到说完插入,再开启对应润色。
    private func confirmPendingEnable() {
        guard let which = pendingEnable else { return }
        s.applyInsert("paste")
        doEnable(which)
        pendingEnable = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t("llm.sec.cloud")).sectionLabel(scheme)
            cloudCard

            if cfg.enabled {
                Text(l10n.t("llm.sec.requests")).sectionLabel(scheme)
                requestLogCard
                Text(l10n.t("llm.sec.mods")).sectionLabel(scheme)
                modsCard
                Text(l10n.t("llm.sec.templates")).sectionLabel(scheme)
                PromptTemplateStudioView(s: s, l10n: l10n, embedded: true)
            }

            Text(l10n.t("llm.sec.local")).sectionLabel(scheme)
            localCard
        }
        .onChange(of: s.cloud) { _, newVal in   // 外部(如重置)同步进来
            if newVal != cfg {
                cfg = newVal
                customProviders = CloudCustomProviders.decode(newVal.customProvidersJSON)
                profiles = CloudProfiles.decode(newVal.profilesJSON)
            }
        }
        .onAppear { reqLog = s.cloudRecentRequests() }
        .onReceive(logTimer) { _ in if cfg.enabled { reqLog = s.cloudRecentRequests() } }
        .alert(l10n.t("llm.enable.conflict.title"),
               isPresented: Binding(get: { pendingEnable != nil },
                                    set: { if !$0 { pendingEnable = nil } })) {
            Button(l10n.t("llm.enable.conflict.switch")) { confirmPendingEnable() }
            Button(l10n.t("llm.cancel"), role: .cancel) { pendingEnable = nil }
        } message: {
            Text(l10n.t("llm.enable.conflict.msg"))
        }
    }

    // ===== 本地大模型卡(Beta + 在线下载)=====
    private var localCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(l10n.t("llm.local.title")).font(Vibe.Fonts.ui(15.5, weight: .semibold))
                            .foregroundStyle(Vibe.Palette.text(scheme))
                        betaBadge
                    }
                    Text(l10n.t("llm.local.desc"))
                        .font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                #if arch(arm64)
                VibeToggle(on: Binding(get: { s.refiner }, set: { on in
                    if on { requestEnable("local") } else { s.applyRefiner(false) }
                }))
                #else
                // Intel 不支持本地润色 → 灰显不可开,引导用云端。
                Text(l10n.t("llm.local.aschip"))
                    .font(Vibe.Fonts.ui(11.5, weight: .medium)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                #endif
            }

            #if arch(arm64)
            if s.refiner {
                Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1).padding(.top, 14)
                localStatus.padding(.top, 14)
                refinerSourceLine.padding(.top, 12)
            }
            #endif
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Vibe.Palette.surface2(scheme))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Vibe.Palette.hairline(scheme))))
    }

    /// 下载/就绪/失败三态。
    @ViewBuilder private var localStatus: some View {
        let prog = relay.refinerDownloadProgress()
        let avail = relay.refinerAvailable()
        let failed = relay.refinerDownloadFailed()
        if let p = prog {
            HStack(spacing: 11) {
                ProgressBar(fraction: p).frame(maxWidth: 220)
                Text(p > 0 ? l10n.t("llm.local.downloading", Int(p * 100)) : l10n.t("llm.local.connecting"))
                    .font(Vibe.Fonts.mono(11.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer(minLength: 0)
            }
        } else if avail {
            HStack(spacing: 9) {
                Circle().fill(Color(red: 0.20, green: 0.83, blue: 0.6)).frame(width: 8, height: 8)
                Text(l10n.t("llm.local.ready"))
                    .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.20, green: 0.83, blue: 0.6))
                Spacer(minLength: 0)
                Button(l10n.t("llm.local.delete")) { _ = relay.deleteRefiner() }
                    .buttonStyle(.plain).font(Vibe.Fonts.ui(12))
                    .foregroundStyle(Vibe.Palette.error)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Vibe.Palette.hairline(scheme)))
            }
        } else if failed {
            HStack(spacing: 9) {
                Circle().fill(Color(red: 0.96, green: 0.38, blue: 0.48)).frame(width: 8, height: 8)
                Text(l10n.t("llm.local.failed"))
                    .font(Vibe.Fonts.ui(12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.38, blue: 0.48))
                Spacer(minLength: 0)
                downloadBtn(l10n.t("llm.local.retry"))
            }
        } else {
            HStack(spacing: 9) {
                Text(l10n.t("llm.local.firstdl"))
                    .font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer(minLength: 0)
                downloadBtn(l10n.t("llm.local.download"))
            }
        }
    }

    private func downloadBtn(_ title: String) -> some View {
        Button(title) { relay.startRefinerDownload() }
            .buttonStyle(.plain).font(Vibe.Fonts.ui(12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vibe.Palette.accentA))
    }

    /// 「模型来源」一行 —— 标注上游开源模型(MuyuanJ 的 Qwen3-refiner);实际 GGUF 由作者
    /// 镜像到自己的 HuggingFace 仓库后在线下载。
    private var refinerSourceLine: some View {
        HStack(spacing: 6) {
            Text(l10n.t("llm.local.source")).font(Vibe.Fonts.ui(11.5)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
            Link(destination: URL(string: "https://modelscope.cn/models/MuyuanJ/Qwen3-refiner-0.6B-MLX")!) {
                Text("Qwen3-refiner-0.6B · MuyuanJ").font(Vibe.Fonts.mono(11))
                    .foregroundStyle(Color(red: 0.49, green: 0.63, blue: 1)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(l10n.t("llm.local.quant")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.6))
        }
    }

    private var betaBadge: some View {
        Text("Beta").font(Vibe.Fonts.ui(10.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.98, green: 0.74, blue: 0.36))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color(red: 0.95, green: 0.66, blue: 0.24).opacity(0.16)))
    }

    // ===== 云端配置卡 =====
    private var cloudCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(l10n.t("llm.cloud.title")).font(Vibe.Fonts.ui(15.5, weight: .semibold))
                            .foregroundStyle(Vibe.Palette.text(scheme))
                        Text(l10n.t("badge.recommended")).font(Vibe.Fonts.ui(10.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 1))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color(red: 0.55, green: 0.48, blue: 0.94).opacity(0.16)))
                    }
                    Text(l10n.t("llm.cloud.desc"))
                        .font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
                Spacer()
                VibeToggle(on: Binding(get: { cfg.enabled }, set: { on in
                    if on { requestEnable("cloud") } else { setEnabled(false) }
                }))
            }
            .padding(.bottom, cfg.enabled ? 14 : 0)

            if cfg.enabled {
                profilesBar
                // 服务商 + 模型
                HStack(spacing: 16) {
                    fieldCol(l10n.t("llm.field.provider")) {
                        // 整行可点开下拉(Button + popover —— 避开 Menu(.borderlessButton) 在本
                        // macOS 会缩成最小、露系统箭头的问题);popover 内含内置 + 自定义 + 增删改。
                        Button { showProviderMenu.toggle() } label: {
                            HStack(spacing: 8) {
                                providerMark(prov)
                                Text(providerLabel(cfg.provider)).font(Vibe.Fonts.ui(13.5))
                                    .foregroundStyle(Vibe.Palette.text(scheme)).lineLimit(1)
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                            }
                            .padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: 42)
                            .background(fieldBG).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showProviderMenu, arrowEdge: .bottom) { providerPopover }
                    }
                    fieldCol(prov.modelLabel == "模型" ? l10n.t("llm.field.model") : prov.modelLabel) {
                        // 可输入(自定义模型名 / Ark 接入点 ID)+ 下拉选预设。
                        HStack(spacing: 6) {
                            TextField(l10n.t("llm.model.placeholder"), text: Binding(get: { cfg.model }, set: { cfg.model = $0; commit() }))
                                .textFieldStyle(.plain).font(Vibe.Fonts.ui(13.5))
                            if !prov.models.isEmpty {
                                Menu {
                                    ForEach(prov.models, id: \.id) { m in
                                        Button { cfg.model = m.id; commit() } label: {
                                            HStack { Text(m.label); Spacer(); Text(m.note).foregroundStyle(.secondary) }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                        }
                        .padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: 42).background(fieldBG)
                    }
                }
                fieldCol(l10n.t("llm.field.baseurl")) {
                    TextField(prov.baseURL, text: Binding(get: { cfg.baseURL }, set: { cfg.baseURL = $0; commit() }))
                        .textFieldStyle(.plain).font(Vibe.Fonts.ui(13.5))
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(fieldBG)
                }
                .padding(.top, 12)
                fieldCol("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if showKey { TextField(prov.keyHint, text: keyBinding) }
                            else { SecureField(prov.keyHint, text: keyBinding) }
                        }.textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        Button(showKey ? l10n.t("llm.hide") : l10n.t("llm.show")) { showKey.toggle() }
                            .buttonStyle(.plain).font(Vibe.Fonts.ui(11.5))
                            .foregroundStyle(Vibe.Palette.textMuted(scheme))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                    }
                    .padding(.horizontal, 13).frame(height: 42).background(fieldBG)
                }
                .padding(.top, 12)

                // 高级:Temperature + Max Tokens
                HStack(spacing: 16) {
                    fieldCol(l10n.t("llm.field.temperature")) {
                        TextField("0.3", value: Binding(get: { cfg.temperature },
                                                        set: { cfg.temperature = min(2, max(0, $0)); commit() }), format: .number)
                            .textFieldStyle(.plain).font(Vibe.Fonts.ui(13.5))
                            .padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: 42).background(fieldBG)
                    }
                    fieldCol(l10n.t("llm.field.maxtokens")) {
                        TextField("2048", value: Binding(get: { cfg.maxTokens },
                                                         set: { cfg.maxTokens = max(1, $0); commit() }), format: .number)
                            .textFieldStyle(.plain).font(Vibe.Fonts.ui(13.5))
                            .padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: 42).background(fieldBG)
                    }
                }
                .padding(.top, 12)

                // 测试连接
                HStack(spacing: 14) {
                    Button { runTest() } label: {
                        HStack(spacing: 8) {
                            if testing { ProgressView().controlSize(.small); Text(l10n.t("llm.testing")) }
                            else { Text(l10n.t("llm.test.btn")) }
                        }
                    }
                    .buttonStyle(.plain).disabled(testing)
                    .font(Vibe.Fonts.ui(13.5, weight: .semibold)).foregroundStyle(Vibe.Palette.text(scheme))
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.hairline(scheme))))

                    if let t = test {
                        if t.ok {
                            HStack(spacing: 9) {
                                Circle().fill(Color(red: 0.20, green: 0.83, blue: 0.6)).frame(width: 8, height: 8)
                                Text(l10n.t("llm.test.ok")).foregroundStyle(Color(red: 0.20, green: 0.83, blue: 0.6)).fontWeight(.semibold)
                                chip(l10n.t("llm.test.rtt", t.ping)); chip(l10n.t("llm.test.full", t.add))
                            }.font(Vibe.Fonts.ui(12.5))
                        } else {
                            HStack(spacing: 9) {
                                Circle().fill(Color(red: 0.96, green: 0.38, blue: 0.48)).frame(width: 8, height: 8)
                                Text(l10n.t("llm.test.fail", t.msg)).foregroundStyle(Color(red: 0.96, green: 0.38, blue: 0.48)).fontWeight(.semibold)
                            }.font(Vibe.Fonts.ui(12.5))
                        }
                    } else {
                        Text(l10n.t("llm.test.hint"))
                            .font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
                    }
                }
                .padding(.top, 18)

                HStack(spacing: 7) {
                    Text("💳 \(prov.price)")
                }.font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8)).padding(.top, 13)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Vibe.Palette.surface2(scheme))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Vibe.Palette.hairline(scheme))))
    }

    // ===== 我的配置栏(保存/一键切换)=====
    private var profilesBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(l10n.t("llm.profiles.hint"))
                .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(profiles) { p in profileChip(p) }
                    Button { saveCurrentAsProfile() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 11))
                            Text(l10n.t("llm.profiles.save")).font(Vibe.Fonts.ui(13))
                        }
                        .foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                        .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Vibe.Palette.hairline(scheme), style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 14)
    }
    private func profileChip(_ p: CloudProfile) -> some View {
        HStack(spacing: 7) {
            if editingProfileId == p.id {
                TextField("", text: Binding(
                    get: { p.name },
                    set: { nv in if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i].name = nv } }))
                    .textFieldStyle(.plain).font(Vibe.Fonts.ui(13)).frame(width: 92)
                    .onSubmit { editingProfileId = nil; commit() }
            } else {
                Text(p.name).font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme)).lineLimit(1)
                Text(providerLabel(p.provider)).font(Vibe.Fonts.ui(10.5))
                    .foregroundStyle(Vibe.Palette.textMuted(scheme)).lineLimit(1)
            }
            Button { deleteProfile(p.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Vibe.Palette.textMuted(scheme))
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Vibe.Palette.hairline(scheme))))
        .contentShape(Rectangle())
        .onTapGesture { loadProfile(p) }
        .onTapGesture(count: 2) { editingProfileId = p.id }
    }

    // ===== 最近请求卡(排查)=====
    private var requestLogCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(l10n.t("llm.log.hint"))
                    .font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if cfg.logEnabled {
                    Button(l10n.t("llm.refresh")) { reqLog = s.cloudRecentRequests() }
                        .buttonStyle(.plain).font(Vibe.Fonts.ui(12)).foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                    Button(l10n.t("llm.clear")) { s.cloudClearRequests(); reqLog = [] }
                        .buttonStyle(.plain).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                }
                Text(l10n.t("llm.log.label")).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                VibeToggle(on: Binding(get: { cfg.logEnabled }, set: { cfg.logEnabled = $0; commit() }))
            }
            if !cfg.logEnabled {
                Text(l10n.t("llm.log.off"))
                    .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            } else if reqLog.isEmpty {
                Text(l10n.t("llm.log.empty"))
                    .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            } else {
                let rows = Array(reqLog.prefix(8))
                ForEach(rows) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 9) {
                            Circle().fill(logColor(e.status)).frame(width: 7, height: 7)
                            Text(e.at.formatted(.dateTime.hour().minute().second()))
                                .font(Vibe.Fonts.mono(11)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                            Text("\(providerLabel(e.provider)) · \(e.model)")
                                .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.text(scheme)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(e.ms)ms").font(Vibe.Fonts.mono(11)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                            Text(logText(e.status)).font(Vibe.Fonts.ui(11.5, weight: .semibold)).foregroundStyle(logColor(e.status))
                            Button { copyIssue(e) } label: {
                                Text(copiedId == e.id ? l10n.t("llm.log.copied") : l10n.t("llm.log.copy"))
                                    .font(Vibe.Fonts.ui(11, weight: .medium))
                                    .foregroundStyle(copiedId == e.id ? Color(red: 0.20, green: 0.83, blue: 0.6) : Color(red: 0.62, green: 0.58, blue: 1))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Vibe.Palette.hairline(scheme)))
                            }.buttonStyle(.plain)
                        }
                        logChangeLine(e)
                    }
                    .padding(.vertical, 8)
                    if e.id != rows.last?.id {
                        Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Vibe.Palette.surface2(scheme))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Vibe.Palette.hairline(scheme))))
    }
    private func logColor(_ s: String) -> Color {
        switch s {
        case "ok":                return Color(red: 0.20, green: 0.83, blue: 0.6)
        case "timeout", "skipped": return Color(red: 0.98, green: 0.74, blue: 0.36)
        default:                  return Color(red: 0.96, green: 0.38, blue: 0.48)
        }
    }
    private func logText(_ s: String) -> String {
        switch s {
        case "ok": return l10n.t("llm.status.ok"); case "timeout": return l10n.t("llm.status.timeout")
        case "skipped": return l10n.t("llm.status.skipped"); default: return l10n.t("llm.status.failed")
        }
    }
    /// 变更行三态:失败 → 显示错误;原始==结果 → 「无修改」;否则 → 从「原始 ASR」改成「结果」。
    @ViewBuilder private func logChangeLine(_ e: CloudReqLogEntry) -> some View {
        let inp = e.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outp = e.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let faint = Vibe.Palette.textMuted(scheme).opacity(0.7)
        Group {
            if e.status != "ok" {
                Text("「\(inp)」").foregroundStyle(Vibe.Palette.textMuted(scheme))
                + Text("  ·  \(logText(e.status)):\(e.output)").foregroundStyle(logColor(e.status))
            } else if inp == outp {
                Text("「\(inp)」").foregroundStyle(Vibe.Palette.text(scheme))
                + Text("  ·  \(l10n.t("llm.log.nochange"))").foregroundStyle(faint)
            } else {
                Text(l10n.t("llm.log.from")).foregroundStyle(faint)
                + Text("「\(inp)」").foregroundStyle(Vibe.Palette.textMuted(scheme))
                + Text(l10n.t("llm.log.to")).foregroundStyle(faint)
                + Text("「\(outp)」").foregroundStyle(Vibe.Palette.text(scheme))
            }
        }
        .font(Vibe.Fonts.ui(11.5)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }
    /// 服务商 key → 显示名(内置查目录,自定义查列表)。
    private func providerLabel(_ key: String) -> String {
        if CloudProvidersUI.isBuiltin(key) { return CloudProvidersUI.localizedLabel(key) }
        return customProviders.first { $0.id == key }?.label ?? (key.isEmpty ? l10n.t("llm.custom") : key)
    }
    /// 把一条请求拼成可直接贴去 issue 的 Markdown(含服务商/模型/输入输出/提示词)。
    private func issueMarkdown(_ e: CloudReqLogEntry) -> String {
        """
        \(l10n.t("llm.issue.title"))

        - \(l10n.t("llm.issue.provider")): \(providerLabel(e.provider)) (`\(e.provider)`)
        - \(l10n.t("llm.issue.model")): `\(e.model)`
        - \(l10n.t("llm.issue.api")): \(e.baseURL)
        - \(l10n.t("llm.issue.result")): \(logText(e.status)) · \(e.ms)ms
        - \(l10n.t("llm.issue.time")): \(e.at.formatted(.dateTime.year().month().day().hour().minute().second()))

        ### \(l10n.t("llm.issue.input"))
        ```
        \(e.input)
        ```

        ### \(l10n.t("llm.issue.output"))
        ```
        \(e.output)
        ```

        ### \(l10n.t("llm.issue.prompt"))
        ```
        \(e.prompt)
        ```
        """
    }
    private func copyIssue(_ e: CloudReqLogEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issueMarkdown(e), forType: .string)
        copiedId = e.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copiedId == e.id { copiedId = nil } }
        // 弹出提示:可粘贴到 GitHub issue 反馈。
        let alert = NSAlert()
        alert.messageText = l10n.t("llm.copy.alert.title")
        alert.informativeText = l10n.t("llm.copy.alert.body")
        alert.addButton(withTitle: l10n.t("llm.ok"))
        alert.addButton(withTitle: l10n.t("llm.copy.alert.open"))
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/Gilgamesh-J/X-ASR/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    // ===== 处理项卡 =====
    private var modsCard: some View {
        SettingsGroup(label: "") {
            SettingsRow(title: l10n.t("llm.mod.numbers.title"), help: l10n.t("llm.mod.numbers.help")) {
                VibeToggle(on: Binding(get: { cfg.numbers }, set: { cfg.numbers = $0; commit() }))
            }
            SettingsRow(title: l10n.t("llm.mod.fillers.title"), help: l10n.t("llm.mod.fillers.help")) {
                VibeToggle(on: Binding(get: { cfg.fillers }, set: { cfg.fillers = $0; commit() }))
            }
            SettingsRow(title: l10n.t("llm.mod.restate.title"), help: l10n.t("llm.mod.restate.help")) {
                VibeToggle(on: Binding(get: { cfg.restate }, set: { cfg.restate = $0; commit() }))
            }
            SettingsRow(title: l10n.t("llm.mod.hotwords.title"), help: l10n.t("llm.mod.hotwords.help")) {
                VibeToggle(on: Binding(get: { cfg.hotwords }, set: { cfg.hotwords = $0; commit() }))
            }
        }
    }

    // ===== 绑定 & 动作 =====
    private var keyBinding: Binding<String> {
        Binding(get: { cfg.apiKey }, set: { cfg.apiKey = $0; test = nil; commit() })   // 即时写 Keychain
    }
    private func switchProvider(_ key: String) {
        cfg.provider = key
        let p = CloudProvidersUI.find(key)
        cfg.baseURL = p.baseURL
        cfg.model = p.defaultModel.isEmpty ? (p.models.first?.id ?? "") : p.defaultModel
        test = nil; commit()
    }
    /// 选择服务商:内置走预设填充;自定义则套用其 BaseURL(模型保留,手填)。
    private func selectProvider(_ id: String) {
        if CloudProvidersUI.isBuiltin(id) { switchProvider(id) }
        else if let c = customProviders.first(where: { $0.id == id }) {
            cfg.provider = id; cfg.baseURL = c.baseURL; test = nil; commit()
        }
        showProviderMenu = false
    }
    private func startAddProvider() {
        isNewProvider = true
        providerEditor = CloudCustomProvider(id: "", label: "", baseURL: "https://")
    }
    private func startEditProvider(_ id: String) {
        guard let c = customProviders.first(where: { $0.id == id }) else { return }
        isNewProvider = false; providerEditor = c
    }
    private func saveProvider() {
        guard var e = providerEditor else { return }
        e.label = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
        e.baseURL = e.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.label.isEmpty, !e.baseURL.isEmpty else { return }
        if e.id.isEmpty {                         // 新增:生成唯一 id
            var n = customProviders.count + 1, id = "cust\(n)"
            while customProviders.contains(where: { $0.id == id }) || CloudProvidersUI.isBuiltin(id) { n += 1; id = "cust\(n)" }
            e.id = id; customProviders.append(e)
        } else if let i = customProviders.firstIndex(where: { $0.id == e.id }) {
            customProviders[i] = e
        } else { customProviders.append(e) }
        cfg.provider = e.id; cfg.baseURL = e.baseURL; test = nil
        providerEditor = nil; commit()
    }
    private func deleteProvider(_ id: String) {
        customProviders.removeAll { $0.id == id }
        if cfg.provider == id { switchProvider("openai") } else { commit() }
        if providerEditor?.id == id { providerEditor = nil }
    }

    // ===== 我的配置(保存/切换/改名/删除)=====
    private func saveCurrentAsProfile() {
        var n = profiles.count + 1
        let base = l10n.t("llm.profile.default")
        var name = "\(base)\(n)", id = "prof\(n)"
        while profiles.contains(where: { $0.name == name }) { n += 1; name = "\(base)\(n)" }
        while profiles.contains(where: { $0.id == id }) { n += 1; id = "prof\(n)" }
        profiles.append(CloudProfiles.snapshot(cfg, id: id, name: name))
        editingProfileId = id     // 立刻进入改名
        commit()
    }
    private func loadProfile(_ p: CloudProfile) {
        guard editingProfileId == nil else { return }   // 改名时点击不触发加载
        CloudProfiles.apply(p, to: &cfg)
        test = nil
        commit()
    }
    private func deleteProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        if editingProfileId == id { editingProfileId = nil }
        commit()
    }
    private func runTest() {
        testing = true; test = nil
        let c = cfg
        Task {
            let r = await s.testCloud()
            await MainActor.run { test = r; testing = false }
            _ = c
        }
    }
    // ===== 复用小组件 =====
    private func fieldCol<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(Vibe.Fonts.ui(12.5, weight: .medium)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // 服务商/模型 两列等宽,避免被挤瘪
    }
    private var fieldBG: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Vibe.Palette.hairline(scheme)))
    }
    private func providerMark(_ p: CloudProviderUI) -> AnyView {
        let green = p.cls == "oa"
        let purple = p.cls == "custom"
        let fg = green ? Color(red: 0.12, green: 0.81, blue: 0.64)
               : purple ? Color(red: 0.70, green: 0.66, blue: 1) : Color(red: 0.49, green: 0.63, blue: 1)
        let bg = green ? Color(red: 0.06, green: 0.64, blue: 0.5)
               : purple ? Color(red: 0.55, green: 0.48, blue: 0.94) : Color(red: 0.23, green: 0.42, blue: 1)
        return AnyView(Text(p.mark).font(.system(size: 12, weight: .bold))
            .foregroundStyle(fg).frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg.opacity(0.13))))
    }

    // ===== 服务商下拉 popover(内置 + 自定义 + 增删改)=====
    @ViewBuilder private var providerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if providerEditor != nil { providerForm } else { providerList }
        }
        .frame(width: 340).padding(12).background(Vibe.Palette.surface2(scheme))
    }
    private var providerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l10n.t("llm.prov.select")).font(Vibe.Fonts.ui(11.5, weight: .medium))
                .foregroundStyle(Vibe.Palette.textMuted(scheme)).padding(.leading, 6).padding(.bottom, 4)
            ForEach(CloudProvidersUI.all, id: \.key) { p in
                providerPickRow(id: p.key, mark: p.mark, label: CloudProvidersUI.localizedLabel(p.key), custom: false)
            }
            if !customProviders.isEmpty {
                Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1).padding(.vertical, 5)
                ForEach(customProviders) { c in
                    providerPickRow(id: c.id, mark: String(c.label.prefix(1)).uppercased(), label: c.label, custom: true)
                }
            }
            Rectangle().fill(Vibe.Palette.hairline(scheme)).frame(height: 1).padding(.vertical, 5)
            Button { startAddProvider() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 13))
                    Text(l10n.t("llm.prov.add")).font(Vibe.Fonts.ui(13)); Spacer()
                }
                .foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                .padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
    private func providerPickRow(id: String, mark: String, label: String, custom: Bool) -> some View {
        HStack(spacing: 6) {
            Button { selectProvider(id) } label: {
                HStack(spacing: 9) {
                    Text(mark).font(.system(size: 11, weight: .bold)).foregroundStyle(Vibe.Palette.text(scheme))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                    Text(label).font(Vibe.Fonts.ui(13)).foregroundStyle(Vibe.Palette.text(scheme)).lineLimit(1)
                    Spacer(minLength: 4)
                    if cfg.provider == id {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                    }
                }
                .padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if custom {
                Button { startEditProvider(id) } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Button { deleteProvider(id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Vibe.Palette.error)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(cfg.provider == id ? Color.white.opacity(0.05) : .clear))
    }
    private var providerFormValid: Bool {
        !(providerEditor?.label.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        && !(providerEditor?.baseURL.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    private var providerForm: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(isNewProvider ? l10n.t("llm.prov.add") : l10n.t("llm.prov.edit")).font(Vibe.Fonts.ui(13.5, weight: .semibold))
                .foregroundStyle(Vibe.Palette.text(scheme))
            formField(l10n.t("llm.prov.name"), placeholder: l10n.t("llm.prov.name.ph"),
                      get: { providerEditor?.label ?? "" }, set: { providerEditor?.label = $0 })
            formField(l10n.t("llm.field.baseurl"), placeholder: "https://api.xxx.com/v1",
                      get: { providerEditor?.baseURL ?? "" }, set: { providerEditor?.baseURL = $0 })
            Text(l10n.t("llm.prov.form.hint"))
                .font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(l10n.t("llm.cancel")) { providerEditor = nil }
                    .buttonStyle(.plain).font(Vibe.Fonts.ui(12.5)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                Spacer()
                Button(l10n.t("llm.save")) { saveProvider() }
                    .buttonStyle(.plain).font(Vibe.Fonts.ui(12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(providerFormValid ? Vibe.Palette.accentA : Vibe.Palette.accentA.opacity(0.4)))
                    .disabled(!providerFormValid)
            }
        }
    }
    private func formField(_ label: String, placeholder: String,
                           get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Vibe.Fonts.ui(11.5, weight: .medium)).foregroundStyle(Vibe.Palette.textMuted(scheme))
            TextField(placeholder, text: Binding(get: get, set: set))
                .textFieldStyle(.plain).font(Vibe.Fonts.ui(13))
                .padding(.horizontal, 11).frame(height: 36).background(fieldBG)
        }
    }
    private func chip(_ t: String) -> some View {
        Text(t).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.text(scheme))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Vibe.Palette.hairline(scheme))))
    }
}
