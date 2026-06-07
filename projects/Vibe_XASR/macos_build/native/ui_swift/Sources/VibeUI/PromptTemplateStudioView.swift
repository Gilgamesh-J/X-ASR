import SwiftUI
import AppKit

// 提示词模板工作室 —— 从 LLMTab 抽出的可复用视图:模板 chips + 占位符工具条 + 编辑器。
// 设置页内嵌(embedded=true)与独立窗口(PromptStudioWindowView)共用同一份,
// 都读写 s.cloud → SettingsStore(单一真值来源)。

extension Notification.Name {
    /// 内嵌工作室请求在独立窗口打开(VibeUI 不能依赖 app 目标,用通知解耦,AppDelegate 监听)。
    public static let vibeOpenPromptStudio = Notification.Name("vibeOpenPromptStudio")
}

/// 稳定持有 NSTextView 协调器:用 @StateObject 保证每个窗口一个实例、re-render 不重建。
final class PromptCoordinatorHolder: ObservableObject { let co = CloudPromptCoordinator() }

struct PromptTemplateStudioView: View {
    @ObservedObject var s: SettingsState
    @ObservedObject var l10n: L10n
    /// 内嵌于设置页 = true(显示「在新窗口打开」);独立窗口 = false。
    var embedded: Bool = false
    @Environment(\.colorScheme) private var scheme

    @State private var cfg: CloudConfigDTO
    @State private var templates: [CloudTemplate]
    @State private var editingId: String?
    @State private var copiedTplId: String?   // 刚一键复制的模板(短暂高亮)
    @State private var hotkeys: [String: TemplateHotkey]   // 每模板绑定的快捷键
    @State private var hotkeyConflict = false              // 上次绑定撞键
    @StateObject private var coordHolder = PromptCoordinatorHolder()

    init(s: SettingsState, l10n: L10n, embedded: Bool = false) {
        self.s = s; self.l10n = l10n; self.embedded = embedded
        let tpls = CloudSeeds.decode(s.cloud.templatesJSON)
        var c0 = s.cloud
        // 归正:activeTemplate 指向已删模板 → 回「自动」。
        if c0.activeTemplate != "auto", !tpls.contains(where: { $0.id == c0.activeTemplate }) { c0.activeTemplate = "auto" }
        _cfg = State(initialValue: c0)
        _templates = State(initialValue: tpls)
        _hotkeys = State(initialValue: CloudTemplateHotkeys.decode(s.cloud.templateHotkeysJSON))
    }

    private var promptCo: CloudPromptCoordinator { coordHolder.co }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 模板 chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipT(l10n.t("llm.tpl.auto"), active: cfg.activeTemplate == "auto") { cfg.activeTemplate = "auto"; hotkeyConflict = false; commit() }
                    ForEach(templates) { t in
                        templateChip(t)
                    }
                    Button { addTemplate() } label: { Text(l10n.t("llm.tpl.new")) }
                        .buttonStyle(.plain).font(Vibe.Fonts.ui(13))
                        .foregroundStyle(Vibe.Palette.textMuted(scheme))
                        .padding(.horizontal, 13).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Vibe.Palette.hairline(scheme), style: StrokeStyle(lineWidth: 1, dash: [4])))
                    if embedded {
                        Button { NotificationCenter.default.post(name: .vibeOpenPromptStudio, object: nil) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "macwindow").font(.system(size: 11))
                                Text(l10n.t("llm.tpl.openWindow")).font(Vibe.Fonts.ui(13))
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1))
                        .padding(.horizontal, 13).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Vibe.Palette.hairline(scheme), style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                }
            }
            // 占位符工具条(锁定模板「自动 / 口语转书面」只读 → 隐藏插入,改显锁定提示)
            if isLockedTemplate(cfg.activeTemplate) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(l10n.t("llm.tpl.locked"))
                    Spacer()
                    // 「自动」无 chip,在此提供一键复制(复制实时拼成的提示词)。
                    if cfg.activeTemplate == "auto" {
                        Button { copyPrompt(id: "auto", content: buildAutoPromptUI(cfg.modsTuple)) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedTplId == "auto" ? "checkmark" : "doc.on.doc")
                                Text(l10n.t(copiedTplId == "auto" ? "llm.tpl.copied" : "llm.tpl.copy"))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(copiedTplId == "auto" ? Color(red: 0.20, green: 0.83, blue: 0.6) : Color(red: 0.62, green: 0.58, blue: 1))
                    }
                }.font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
            } else {
                HStack(spacing: 8) {
                    Text(l10n.t("llm.tpl.insertToken")).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    ForEach(CloudSeeds.tokens, id: \.token) { tk in
                        Button { promptCo.insert(tk.token) } label: { Text(tk.token) }
                            .buttonStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 1))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.55, green: 0.48, blue: 0.94).opacity(0.12)))
                    }
                    Spacer()
                    Text(l10n.t("llm.tpl.autoReplace")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.7))
                }
            }
            // 编辑器(锁定模板只读)
            CloudPromptEditor(text: promptBinding, coordinator: promptCo, editable: !isLockedTemplate(cfg.activeTemplate))
                .frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Vibe.Palette.hairline(scheme))))
            // 模板快捷键(按住说话触发该模板);「自动」不可绑定。
            if cfg.activeTemplate != "auto" {
                HStack(spacing: 8) {
                    Text(l10n.t("llm.tpl.hotkey")).font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    ComboRecorder(display: hotkeyDisplay(cfg.activeTemplate),
                                  placeholder: l10n.t("llm.tpl.hotkeyUnset")) { code, mods in
                        setHotkey(cfg.activeTemplate, code: code, mods: mods)
                    }
                    if hotkeys[cfg.activeTemplate] != nil {
                        Button(l10n.t("llm.tpl.hotkeyClear")) { clearHotkey(cfg.activeTemplate) }
                            .buttonStyle(.plain).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.textMuted(scheme))
                    }
                    if hotkeyConflict {
                        Text(l10n.t("llm.tpl.hotkeyConflict")).font(Vibe.Fonts.ui(11)).foregroundStyle(Vibe.Palette.error)
                    }
                    Spacer()
                    Text(l10n.t("llm.tpl.hotkeyCloudHint")).font(Vibe.Fonts.ui(10.5)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.7))
                }
            }
            Text(l10n.t("llm.tpl.hint"))
                .font(Vibe.Fonts.ui(12)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.8))
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Vibe.Palette.surface2(scheme))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Vibe.Palette.hairline(scheme))))
        .onChange(of: s.cloud) { _, newVal in   // 外部(另一窗口/重置)改了 → 同步进来
            if newVal != cfg {
                cfg = newVal
                templates = CloudSeeds.decode(newVal.templatesJSON)
                hotkeys = CloudTemplateHotkeys.decode(newVal.templateHotkeysJSON)
            }
        }
    }

    // ===== 绑定 & 动作(从 LLMTab 迁入)=====
    /// 以最新 store 为基准,只覆盖模板相关字段(provider/profile 等取 live,避免覆盖另一窗口的改动)。
    private func commit() {
        var c = s.liveCloud ?? s.cloud
        c.templatesJSON = CloudSeeds.encode(templates)
        c.activeTemplate = cfg.activeTemplate
        c.templateHotkeysJSON = CloudTemplateHotkeys.encode(hotkeys)
        s.applyCloud(c)
        cfg = c   // 与 s.cloud 对齐,避免 onChange 误判再次同步
    }

    // ===== 模板快捷键 =====
    private func hotkeyDisplay(_ id: String) -> String {
        guard let h = hotkeys[id] else { return "" }
        return VibeKeycodes.comboName(keyCode: h.keyCode, mods: HotkeyMods(rawValue: h.mods))
    }
    private func setHotkey(_ id: String, code: Int, mods: HotkeyMods) {
        if conflicts(id: id, code: code, mods: mods) { hotkeyConflict = true; return }
        hotkeyConflict = false
        hotkeys[id] = TemplateHotkey(keyCode: code, mods: mods.rawValue, modifierOnly: false)
        commit()
    }
    private func clearHotkey(_ id: String) { hotkeys[id] = nil; hotkeyConflict = false; commit() }
    /// 与主听写键或其它模板撞键。模板键恒为「普通键(+可选修饰)」,主键若是纯修饰键
    /// (modifierOnly)则不可能与模板键精确相同 → 不算冲突;否则按 keyCode + 修饰位完全比对。
    private func conflicts(id: String, code: Int, mods: HotkeyMods) -> Bool {
        if !s.hotkeyModifierOnly, s.hotkeyKeyCode == code, HotkeyMods(rawValue: s.hotkeyMods) == mods { return true }
        for (tid, h) in hotkeys where tid != id {
            if h.keyCode == code && h.mods == mods.rawValue { return true }
        }
        return false
    }
    /// 锁定(不可编辑/改名/删除)的内置模板:「自动」+「口语转书面」(t1)。
    private func isLockedTemplate(_ id: String) -> Bool { id == "auto" || id == "t1" }

    /// 内置锁定模板「口语转书面」(t1)随 UI 语言走;自定义模板保持用户原文。
    /// 因此 t1 的「显示名 / 内容 / 复制」都用当前语言实时生成,不读存储里的旧文案。
    private func displayName(_ t: CloudTemplate) -> String {
        t.id == LocalizedPrompts.seedTemplateId ? LocalizedPrompts.seedUI().name : t.name
    }
    private func displayContent(_ t: CloudTemplate) -> String {
        t.id == LocalizedPrompts.seedTemplateId ? LocalizedPrompts.seedUI().content : t.content
    }

    /// 一键复制提示词内容到剪贴板(用于分享),短暂高亮反馈。
    private func copyPrompt(id: String, content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copiedTplId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copiedTplId == id { copiedTplId = nil } }
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: {
                if cfg.activeTemplate == "auto" {
                    return buildAutoPromptUI(cfg.modsTuple)   // 自动:始终由开关实时拼成(只读)
                }
                if cfg.activeTemplate == LocalizedPrompts.seedTemplateId {
                    return LocalizedPrompts.seedUI().content   // 内置「口语转书面」:随 UI 语言(只读)
                }
                return templates.first { $0.id == cfg.activeTemplate }?.content ?? ""
            },
            set: { v in
                if isLockedTemplate(cfg.activeTemplate) { return }   // 锁定模板只读
                if let i = templates.firstIndex(where: { $0.id == cfg.activeTemplate }) { templates[i].content = v; commit() }
            })
    }

    private func chipT(_ title: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) { Text(title) }
            .buttonStyle(.plain).font(Vibe.Fonts.ui(13, weight: active ? .medium : .regular))
            .foregroundStyle(active ? .white : Vibe.Palette.text(scheme))
            .padding(.horizontal, 13).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? Color(red: 0.45, green: 0.42, blue: 0.85).opacity(0.28) : Color.black.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color(red: 0.55, green: 0.48, blue: 0.94).opacity(0.55) : Vibe.Palette.hairline(scheme))))
    }

    private func templateChip(_ t: CloudTemplate) -> some View {
        let active = cfg.activeTemplate == t.id
        let locked = isLockedTemplate(t.id)
        return HStack(spacing: 6) {
            if editingId == t.id && !locked {
                TextField("", text: Binding(
                    get: { t.name },
                    set: { nv in if let i = templates.firstIndex(where: { $0.id == t.id }) { templates[i].name = nv } }))
                    .textFieldStyle(.plain).frame(width: 80)
                    .onSubmit { editingId = nil; commit() }
            } else {
                Text(displayName(t)).font(Vibe.Fonts.ui(13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? .white : Vibe.Palette.text(scheme))
            }
            // 一键复制(分享)—— 所有模板(含锁定)都可复制。
            Button { copyPrompt(id: t.id, content: displayContent(t)) } label: {
                Image(systemName: copiedTplId == t.id ? "checkmark" : "doc.on.doc").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copiedTplId == t.id ? Color(red: 0.20, green: 0.83, blue: 0.6)
                                                 : (active ? .white.opacity(0.85) : Vibe.Palette.textMuted(scheme)))
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Vibe.Palette.textMuted(scheme).opacity(0.7))
            } else {
                Button { delTemplate(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(Vibe.Palette.textMuted(scheme))
            }
        }
        .padding(.horizontal, 13).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(active ? Color(red: 0.45, green: 0.42, blue: 0.85).opacity(0.28) : Color.black.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color(red: 0.55, green: 0.48, blue: 0.94).opacity(0.55) : Vibe.Palette.hairline(scheme))))
        .onTapGesture { cfg.activeTemplate = t.id; hotkeyConflict = false; commit() }
        .onTapGesture(count: 2) { if !locked { editingId = t.id } }
    }

    private func addTemplate() {
        let id = "t\(templates.count + 1)-\(templates.count)"
        let base = l10n.t("llm.tpl.default")
        var n = templates.count + 1, name = "\(base)\(n)"
        while templates.contains(where: { $0.name == name }) { n += 1; name = "\(base)\(n)" }
        templates.append(CloudTemplate(id: id, name: name, content: LocalizedPrompts.newStarterUI()))
        cfg.activeTemplate = id; editingId = id; hotkeyConflict = false; commit()
    }
    private func delTemplate(_ id: String) {
        guard !isLockedTemplate(id) else { return }
        templates.removeAll { $0.id == id }
        if cfg.activeTemplate == id { cfg.activeTemplate = "auto" }
        commit()
    }
}

/// 独立窗口宿主:自己持有一个绑定到同一 bridge 的 SettingsState(与设置页那个是两个实例,
/// 但都指向同一个 SettingsStore,故数据一致;跨窗口实时同步靠 vibeSettingsExternallyChanged 重绑)。
public struct PromptStudioWindowView: View {
    @StateObject private var s = SettingsState()
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var scheme
    private let bridge: SettingsBridge
    public init(bridge: SettingsBridge) { self.bridge = bridge }
    public var body: some View {
        ScrollView {
            PromptTemplateStudioView(s: s, l10n: l10n, embedded: false)
                .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Vibe.Palette.surface(scheme))
        .onAppear { s.bind(to: bridge) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("vibeSettingsExternallyChanged"))) { _ in s.bind(to: bridge) }
    }
}
