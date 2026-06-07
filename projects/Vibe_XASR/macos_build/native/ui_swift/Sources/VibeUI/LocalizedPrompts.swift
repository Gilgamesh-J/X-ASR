// ============================================================
//  Vibe XASR — 默认提示词的多语言文案
//
//  仅针对「不可修改的内置默认提示词」:
//    * 「自动」prompt(由 4 个处理项开关实时拼成)
//    * 锁定内置模板「口语转书面」(id=t1)
//    * 新建模板的起始内容(占位预填)
//  这些随 UI 语言走;用户自建/已改的模板内容一律不动,保持用户原文。
//
//  纯 Foundation、nonisolated,App(VibeIME)与 VibeUI 两个 target 共用,
//  保证两边(预览 / 实际发给模型)文案完全一致。占位符 {{transcript}} /
//  {{hotwords}} / {{changes}} / {{date}} 保留,由各自调用方在使用时替换。
// ============================================================

import Foundation

/// 一种语言下的「默认提示词」全部文案片段。
public struct PromptL10n: Sendable {
    public let autoIntro: String
    public let bulletNumbers: String
    public let bulletFillers: String
    public let bulletRestate: String
    public let bulletHotwords: String
    public let bulletNone: String
    public let autoTail: String
    public let seedName: String
    public let seedContent: String
    public let newStarter: String
}

public enum LocalizedPrompts {

    /// 锁定内置模板「口语转书面」的固定 id。
    public static let seedTemplateId = "t1"

    public static func strings(for lang: Lang) -> PromptL10n {
        let l = (lang == .auto) ? L10n.systemPreferred() : lang
        switch l {
        case .zhHant: return zhHant
        case .en:     return en
        case .ja:     return ja
        case .ko:     return ko
        default:      return zh
        }
    }

    /// 「自动」prompt:按 4 个处理项开关(数字 / 去口水 / 改口 / 热词)拼装。
    public static func auto(_ m: (Bool, Bool, Bool, Bool), lang: Lang) -> String {
        let s = strings(for: lang)
        var r: [String] = []
        if m.0 { r.append(s.bulletNumbers) }
        if m.1 { r.append(s.bulletFillers) }
        if m.2 { r.append(s.bulletRestate) }
        if m.3 { r.append(s.bulletHotwords) }
        let body = r.isEmpty ? s.bulletNone : r.joined(separator: "\n")
        return s.autoIntro + "\n\n" + body + "\n\n" + s.autoTail
    }

    /// 锁定内置模板「口语转书面」的(名称, 内容)。
    public static func seed(lang: Lang) -> (name: String, content: String) {
        let s = strings(for: lang); return (s.seedName, s.seedContent)
    }

    /// 新建模板起始内容。
    public static func newStarter(lang: Lang) -> String { strings(for: lang).newStarter }

    // 便捷:按当前 UI 语言(VibeUI 主线程上下文)。
    @MainActor public static func autoUI(_ m: (Bool, Bool, Bool, Bool)) -> String { auto(m, lang: L10n.shared.resolved) }
    @MainActor public static func seedUI() -> (name: String, content: String) { seed(lang: L10n.shared.resolved) }
    @MainActor public static func newStarterUI() -> String { newStarter(lang: L10n.shared.resolved) }

    // MARK: - 简体中文(基准)
    static let zh = PromptL10n(
        autoIntro: "你是语音转写(ASR)的后处理助手。任务：把这段口述整理成说话人最终想表达的样子。只做下面已开启规则要求的增删，其余内容保持原样——不要改写用词、不要臆造或补充信息、不要总结、不要翻译。",
        bulletNumbers: "• 数字规整：把口语数字转成阿拉伯数字（一百二十三 → 123、三点半 → 3:30、百分之二十 → 20%）；成语、计数词保持不变。",
        bulletFillers: "• 去口水词：删掉「嗯 / 呃 / 唉」等语气词和口吃式重复（那个那个 → 那个、我我我 → 我）；正常叠词（看看 / 想想）保留。",
        bulletRestate: "• 改口纠正：说话人中途自我更正（常见「不对 / 不是 / 应该是 / 我还是…吧」等）时，必须删掉被否定、被替换掉的前半句，只保留最终说法；必要时把最终说法补成通顺完整的句子。例：「我想开发现代风格的客户端，不对，还是古早风格的吧」→「我想开发古早风格的客户端」。",
        bulletHotwords: "• 热词修正：优先按热词表修正同音 / 近音误写，正确写法以热词表为准。\n  热词表：{{hotwords}}",
        bulletNone: "•（暂未选择任何处理项，将原样返回文本）",
        autoTail: "【本地规则已做的改动 · 可能有误，请核对】\n下面是本机规则(同音字纠正 / 替换规则)对原始识别文本所做的修改；本地规则可能弄错，若发现改错了请改回正确写法，没问题则保持：\n{{changes}}\n\n只输出整理后的纯文本，不要解释、不要加引号。\n\n原文：{{transcript}}",
        seedName: "口语转书面",
        seedContent: "把下面这段口述整理成通顺的书面表达，保留全部信息和原意，不要总结、不要遗漏。\n• 去掉口水词与重复，规整数字写法。\n• 专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的文本。\n\n原文：{{transcript}}",
        newStarter: "在此编写你的润色指令(例:把口述整理成简洁书面表达)。\n专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的文本。\n\n原文：{{transcript}}"
    )

    // MARK: - 繁體中文(台灣正體)
    static let zhHant = PromptL10n(
        autoIntro: "你是語音轉寫(ASR)的後處理助手。任務:把這段口述整理成說話人最終想表達的樣子。只做下面已開啟規則要求的增刪,其餘內容保持原樣——不要改寫用詞、不要臆造或補充資訊、不要總結、不要翻譯。",
        bulletNumbers: "• 數字規整:把口語數字轉成阿拉伯數字(一百二十三 → 123、三點半 → 3:30、百分之二十 → 20%);成語、計數詞保持不變。",
        bulletFillers: "• 去口水詞:刪掉「嗯 / 呃 / 唉」等語氣詞和口吃式重複(那個那個 → 那個、我我我 → 我);正常疊詞(看看 / 想想)保留。",
        bulletRestate: "• 改口糾正:說話人中途自我更正(常見「不對 / 不是 / 應該是 / 我還是…吧」等)時,必須刪掉被否定、被替換掉的前半句,只保留最終說法;必要時把最終說法補成通順完整的句子。例:「我想開發現代風格的客戶端,不對,還是古早風格的吧」→「我想開發古早風格的客戶端」。",
        bulletHotwords: "• 熱詞修正:優先按熱詞表修正同音 / 近音誤寫,正確寫法以熱詞表為準。\n  熱詞表:{{hotwords}}",
        bulletNone: "•(暫未選擇任何處理項,將原樣返回文字)",
        autoTail: "【本機規則已做的改動 · 可能有誤,請核對】\n下面是本機規則(同音字糾正 / 替換規則)對原始辨識文字所做的修改;本機規則可能弄錯,若發現改錯了請改回正確寫法,沒問題則保持:\n{{changes}}\n\n只輸出整理後的純文字,不要解釋、不要加引號。\n\n原文:{{transcript}}",
        seedName: "口語轉書面",
        seedContent: "把下面這段口述整理成通順的書面表達,保留全部資訊和原意,不要總結、不要遺漏。\n• 去掉口水詞與重複,規整數字寫法。\n• 專有名詞以熱詞表為準:{{hotwords}}\n\n只輸出整理後的文字。\n\n原文:{{transcript}}",
        newStarter: "在此編寫你的潤色指令(例:把口述整理成簡潔書面表達)。\n專有名詞以熱詞表為準:{{hotwords}}\n\n只輸出整理後的文字。\n\n原文:{{transcript}}"
    )

    // MARK: - English
    static let en = PromptL10n(
        autoIntro: "You are a post-processing assistant for ASR transcripts. Tidy the dictation into what the speaker ultimately meant. Make only the additions and deletions required by the enabled rules below; keep everything else as is — do not rephrase, do not invent or add information, do not summarize, do not translate.",
        bulletNumbers: "• Number normalization: convert spoken numbers into Arabic numerals (e.g. one hundred twenty-three → 123, half past three → 3:30, twenty percent → 20%); leave idioms and set phrases unchanged.",
        bulletFillers: "• Remove filler words: delete fillers (um / uh / er) and stutter-style repetitions (e.g. I-I-I want → I want).",
        bulletRestate: "• Self-correction: when the speaker corrects themselves midway, delete the negated or replaced first half and keep only the final version; complete it into a smooth full sentence if needed. Example: I want to build a modern-style client — no, actually a retro-style one → I want to build a retro-style client.",
        bulletHotwords: "• Hotword correction: prioritize the hotword list to fix homophone and near-homophone mis-transcriptions; the correct spelling is determined by the hotword list.\n  Hotword list: {{hotwords}}",
        bulletNone: "• (No processing option selected yet; text returned unchanged)",
        autoTail: "[Changes already made by local rules · may contain errors, please verify]\nBelow are modifications the on-device rules (homophone correction / replacement rules) made to the original recognized text; they may be wrong — if you find a mistaken change, revert it to the correct spelling, otherwise keep it:\n{{changes}}\n\nOutput only the tidied plain text, no explanation, no quotation marks.\n\nOriginal: {{transcript}}",
        seedName: "Speech to Written Form",
        seedContent: "Tidy the dictation below into smooth written expression, preserving all information and the original meaning; do not summarize, do not omit.\n• Remove fillers and repetitions, and normalize number formatting.\n• Proper nouns follow the hotword list: {{hotwords}}\n\nOutput only the tidied text.\n\nOriginal: {{transcript}}",
        newStarter: "Write your refinement instructions here (e.g., tidy the dictation into concise written expression).\nProper nouns follow the hotword list: {{hotwords}}\n\nOutput only the tidied text.\n\nOriginal: {{transcript}}"
    )

    // MARK: - 日本語
    static let ja = PromptL10n(
        autoIntro: "あなたは音声認識テキストの後処理アシスタントです。口述された内容を、話し手が最終的に伝えたかった形に整えてください。以下で有効になっているルールに必要な追加・削除のみを行い、それ以外はそのまま保持してください。言い換えない、情報を創作・追加しない、要約しない、翻訳しないでください。",
        bulletNumbers: "• 数字の正規化:話し言葉の数を算用数字に変換してください(例:百二十三 → 123、三時半 → 3:30、二十パーセント → 20%)。慣用句や決まり文句はそのままにしてください。",
        bulletFillers: "• フィラーの除去:つなぎ言葉(えーと / あのー / うーん)や、どもりのような繰り返しを削除してください(例:わ、わ、わたしは → わたしは)。",
        bulletRestate: "• 言い直し:話し手が途中で自分の発言を訂正した場合、否定・置き換えられた前半を削除し、最終版だけを残してください。必要なら自然な一文に整えてください。例:モダン風のクライアントを作りたい、いや、やっぱりレトロ風のものを → レトロ風のクライアントを作りたい。",
        bulletHotwords: "• ホットワード修正:ホットワードリストを優先して、同音・類音による誤認識を修正してください。正しい表記はホットワードリストによって決まります。\n  ホットワードリスト: {{hotwords}}",
        bulletNone: "•(処理オプションがまだ選択されていません。テキストはそのまま返されます)",
        autoTail: "【ローカルルールがすでに行った変更 · 誤りを含む可能性があるため確認してください】\n以下は、端末上のルール(同音語修正 / 置換ルール)が元の認識テキストに加えた変更です。誤っている可能性があります。誤った変更を見つけた場合は正しい表記に戻し、そうでなければ保持してください:\n{{changes}}\n\n整えたプレーンテキストのみを出力してください。説明も引用符も付けないでください。\n\n原文: {{transcript}}",
        seedName: "話し言葉を書き言葉へ",
        seedContent: "以下の口述を、すべての情報と元の意味を保ったまま、滑らかな書き言葉に整えてください。要約せず、省略しないでください。\n• フィラーや繰り返しを除去し、数字の表記を正規化してください。\n• 固有名詞はホットワードリストに従ってください: {{hotwords}}\n\n整えたテキストのみを出力してください。\n\n原文: {{transcript}}",
        newStarter: "ここに整形の指示を書いてください(例:口述を簡潔な書き言葉に整える)。\n固有名詞はホットワードリストに従ってください: {{hotwords}}\n\n整えたテキストのみを出力してください。\n\n原文: {{transcript}}"
    )

    // MARK: - 한국어
    static let ko = PromptL10n(
        autoIntro: "당신은 음성 인식 텍스트의 후처리 도우미입니다. 받아쓴 내용을 화자가 최종적으로 전하려던 의미대로 다듬어 주세요. 아래에서 활성화된 규칙에 필요한 추가와 삭제만 수행하고, 나머지는 그대로 유지하세요. 바꿔 말하지 말고, 정보를 지어내거나 추가하지 말고, 요약하지 말고, 번역하지 마세요.",
        bulletNumbers: "• 숫자 정규화: 말로 표현된 수를 아라비아 숫자로 변환하세요(예: 백이십삼 → 123, 세 시 반 → 3:30, 이십 퍼센트 → 20%). 관용구나 굳어진 표현은 그대로 두세요.",
        bulletFillers: "• 군말 제거: 군말(음 / 어 / 그—)과 말 더듬기식 반복을 삭제하세요(예: 저-저-저는 → 저는).",
        bulletRestate: "• 말 고치기: 화자가 도중에 스스로 정정한 경우, 부정되거나 교체된 앞부분을 삭제하고 최종 버전만 남기세요. 필요하면 자연스러운 한 문장으로 완성하세요. 예: 모던 스타일 클라이언트를 만들고 싶어요, 아니 사실은 레트로 스타일로 → 레트로 스타일 클라이언트를 만들고 싶어요.",
        bulletHotwords: "• 핫워드 교정: 핫워드 목록을 우선하여 동음어와 유사 발음으로 인한 오인식을 바로잡으세요. 올바른 표기는 핫워드 목록으로 결정됩니다.\n  핫워드 목록: {{hotwords}}",
        bulletNone: "• (아직 처리 옵션이 선택되지 않았습니다. 텍스트가 변경 없이 반환됩니다)",
        autoTail: "【로컬 규칙이 이미 적용한 변경 · 오류가 있을 수 있으니 확인하세요】\n아래는 기기 내 규칙(동음어 교정 / 치환 규칙)이 원본 인식 텍스트에 가한 변경입니다. 잘못되었을 수 있으니, 잘못된 변경을 발견하면 올바른 표기로 되돌리고 그렇지 않으면 유지하세요:\n{{changes}}\n\n다듬은 일반 텍스트만 출력하세요. 설명도 따옴표도 붙이지 마세요.\n\n원문: {{transcript}}",
        seedName: "말한 것을 글말로",
        seedContent: "아래 받아쓴 내용을 모든 정보와 원래 의미를 유지하면서 매끄러운 글말 표현으로 다듬어 주세요. 요약하지 말고 생략하지 마세요.\n• 군말과 반복을 제거하고 숫자 표기를 정규화하세요.\n• 고유명사는 핫워드 목록을 따르세요: {{hotwords}}\n\n다듬은 텍스트만 출력하세요.\n\n원문: {{transcript}}",
        newStarter: "여기에 다듬기 지침을 작성하세요(예: 받아쓴 내용을 간결한 글말 표현으로 다듬기).\n고유명사는 핫워드 목록을 따르세요: {{hotwords}}\n\n다듬은 텍스트만 출력하세요.\n\n원문: {{transcript}}"
    )
}
