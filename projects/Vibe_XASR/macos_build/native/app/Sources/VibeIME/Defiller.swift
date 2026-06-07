import Foundation

/// Remove Chinese filler words from FINAL dictation — the touch that makes speech
/// read like writing. Conservative:
/// deletes pure interjections (嗯/呃/唉…) and collapses ≥4× repeats, so genuine
/// reduplications (看看 / 想想 / 好好) and short counting (三三三) stay, and a single
/// meaningful 那个 / 就是 is left intact — only stutter-style repeats are folded.
/// NOTE: 額/额/诶 are deliberately NOT interjections — they occur in real words
/// (金额 / 额外 / 余额), so stripping them mangled those.
enum Defiller {
    private static let interjections = "嗯呃唉欸喔噢"
    private static let repeatWords = ["那个", "这个", "就是", "然后"]

    static func clean(_ text: String) -> String {
        var s = text
        // 1) pure interjections (and any run of them)
        s = s.replacingOccurrences(of: "[\(interjections)]+", with: "", options: .regularExpression)
        // 2) collapse a character repeated ≥4× → once (≤3× e.g. 看看/三三三 untouched;
        //    only true stutters like 这这这这 fold)
        s = s.replacingOccurrences(of: "(.)\\1{3,}", with: "$1", options: .regularExpression)
        // 3) collapse stutter repeats of common fillers (≥2×) → once
        for w in repeatWords {
            s = s.replacingOccurrences(of: "(?:\(w)){2,}", with: w, options: .regularExpression)
        }
        // 4) tidy punctuation left behind by removed interjections
        s = s.replacingOccurrences(of: "^[，,、。!?！？\\s]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "([，,])[，,]+", with: "$1", options: .regularExpression)
        return s
    }
}
