// ============================================================
//  Vibe XASR — 词库导入/导出(词典 / 替换 / 口令)
//
//  纯文件 I/O 小工具:把当前编辑区的文本/JSON 存成文件,或从文件读回。
//  换机、备份、分享词库用。解析/序列化仍由各 Tab 自己负责,这里只管落盘/读盘。
// ============================================================

import AppKit
import UniformTypeIdentifiers

@MainActor
enum LexiconIO {
    /// 弹保存面板,把 `content` 写入用户选择的文件。
    static func export(_ content: String, suggestedName: String, json: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = json ? [.json, .plainText] : [.plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    /// 弹打开面板,读回所选文件的文本内容(失败 / 取消 → nil)。
    static func importText(json: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = json ? [.json, .plainText] : [.plainText, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
