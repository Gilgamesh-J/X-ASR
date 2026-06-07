import AppKit
import CoreGraphics
import VibeUI

/// 全局快捷键监听(CGEventTap)。一个共享的 tap 同时服务多个绑定:
///   * 主听写键(默认 Right ⌘,modifierOnly)—— 走 flagsChanged;
///   * 每个模板绑定的「单键或修饰+键」组合 —— 走 keyDown/keyUp(精确匹配修饰位)。
/// 全部为「按住说话」(hold)语义:按下 onFire(id,true),松开 onFire(id,false)。
/// 改动绑定时:stop() 后重建 + start()。需 Accessibility / Input-Monitoring 权限(无则 start() 返回 false)。
final class Hotkey {
    /// 一个绑定。id==nil 为主听写键;非 nil 为 templateId。
    struct Binding {
        let id: String?
        let keycode: CGKeyCode
        let mods: HotkeyMods       // 组合键修饰位;主键/单键为空
        let modifierOnly: Bool     // 纯修饰键(R/L ⌘⌥⌃⇧)→ flagsChanged
    }

    /// 触发回调:(binding.id, isDown)。
    var onFire: ((String?, Bool) -> Void)?

    private let bindings: [Binding]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var downKeys: Set<String> = []   // 已按下的绑定(去重)
    private var pressedModCodes: Set<CGKeyCode> = []   // 当前按下的修饰键 keycode(区分左右)

    init(bindings: [Binding]) { self.bindings = bindings }

    private func key(_ b: Binding) -> String { "\(b.keycode)|\(b.mods.rawValue)|\(b.modifierOnly)" }

    @discardableResult
    func start() -> Bool {
        guard !bindings.isEmpty else { return false }
        var raw: UInt64 = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        if bindings.contains(where: { $0.modifierOnly }) { raw |= (1 << CGEventType.flagsChanged.rawValue) }
        let mask = CGEventMask(raw)

        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        self.runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 拆 tap。若有按住中的绑定,补发 up,避免「卡住按下」。
    func stop() {
        for b in bindings where downKeys.contains(key(b)) { onFire?(b.id, false) }
        downKeys.removeAll()
        pressedModCodes.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            // 维护当前按下的修饰键集合(按 keycode,区分左右)。
            if VibeKeycodes.isModifier(Int(code)) {
                if event.flags.contains(Hotkey.flagMask(for: code)) { pressedModCodes.insert(code) }
                else { pressedModCodes.remove(code) }
            }
            let curFlags = HotkeyMods(cg: event.flags)
            // 纯修饰键 / 修饰键组合绑定(主听写键)。
            for b in bindings where b.modifierOnly {
                let down = Hotkey.modBindingSatisfied(b, pressed: pressedModCodes, flags: curFlags)
                let k = key(b)
                if down && !downKeys.contains(k) { downKeys.insert(k); onFire?(b.id, true) }
                else if !down && downKeys.contains(k) { downKeys.remove(k); onFire?(b.id, false) }
            }
            return
        }

        let evMods = HotkeyMods(cg: event.flags)
        if type == .keyDown {
            // 精确匹配 keycode + 修饰位(⌥1 ≠ 裸 1)。autorepeat 由 downKeys 去重。
            if let b = bindings.first(where: { !$0.modifierOnly && $0.keycode == code && $0.mods == evMods }) {
                let k = key(b)
                if !downKeys.contains(k) { downKeys.insert(k); onFire?(b.id, true) }
            }
        } else if type == .keyUp {
            // 结束该 keycode 的在按绑定(松开时修饰位可能已变,故只按 keycode 收尾)。
            for b in bindings where !b.modifierOnly && b.keycode == code && downKeys.contains(key(b)) {
                downKeys.remove(key(b)); onFire?(b.id, false)
            }
        }
    }

    /// 判断一个 modifierOnly 绑定当前是否「按下」。
    ///   * 单修饰键(mods 空):主修饰 keycode 在按即可(允许同时按住别的修饰键,保持旧的宽松行为)。
    ///   * 修饰键组合(mods 非空,如 Right ⌘ + ⌥):主修饰(区分左右)必须在按,
    ///     且当前修饰位恰好等于「主修饰 ∪ mods」——不多不少,避免误触。
    private static func modBindingSatisfied(_ b: Binding, pressed: Set<CGKeyCode>, flags: HotkeyMods) -> Bool {
        guard pressed.contains(b.keycode) else { return false }
        if b.mods.isEmpty { return true }
        return flags == b.mods.union(VibeKeycodes.flagFor(Int(b.keycode)))
    }

    /// 修饰键 keycode → CGEventFlags 位(左右不分,已先按精确 keycode 过滤)。
    private static func flagMask(for keycode: CGKeyCode) -> CGEventFlags {
        switch Int(keycode) {
        case 54, 55: return .maskCommand
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 56, 60: return .maskShift
        default:     return .maskCommand
        }
    }

    /// Friendly display name for a keycode (delegates to the shared table).
    static func keycodeName(_ code: Int) -> String { VibeKeycodes.name(code) }
}

extension HotkeyMods {
    /// 从 CGEventFlags 取四个修饰位。
    init(cg f: CGEventFlags) {
        var m = HotkeyMods()
        if f.contains(.maskCommand)   { m.insert(.command) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl)   { m.insert(.control) }
        if f.contains(.maskShift)     { m.insert(.shift) }
        self = m
    }
}
