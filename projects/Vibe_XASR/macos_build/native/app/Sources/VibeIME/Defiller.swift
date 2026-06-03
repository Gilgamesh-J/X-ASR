import Foundation

/// Remove Chinese filler words from FINAL dictation — the touch that makes speech
/// read like writing (Typeless / Willow / WisprFlow all do this). Conservative:
/// deletes pure interjections (嗯/呃/唉…) and collapses ≥3× repeats, so genuine
/// reduplications (看看 / 想想 / 好好) stay, and a single meaningful 那个 / 就是
/// is left intact — only stutter-style repeats are folded.
enum Defiller {
    private static let interjections = "嗯呃唉欸額额诶喔噢"
    private static let repeatWords = ["那个", "这个", "就是", "然后"]

    static func clean(_ text: String) -> String {
        var s = text
        // 1) pure interjections (and any run of them)
        s = s.replacingOccurrences(of: "[\(interjections)]+", with: "", options: .regularExpression)
        // 2) collapse a character repeated ≥3× → once (2× e.g. 看看/想想 untouched)
        s = s.replacingOccurrences(of: "(.)\\1{2,}", with: "$1", options: .regularExpression)
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
