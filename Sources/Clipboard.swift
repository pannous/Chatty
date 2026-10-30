import Foundation

/// UIPasteboard is marked unavailable in the watchOS SDK but exists in the runtime (UIKitCore), so it is reached
/// by name. Whether Universal Clipboard then carries the text on to the Mac is untested.
enum Clipboard {
    /// Returns whether the pasteboard now holds `text`.
    static func copy(_ text: String) -> Bool {
        guard let pasteboardClass: AnyObject = NSClassFromString("UIPasteboard"),
              let general = pasteboardClass.perform(NSSelectorFromString("generalPasteboard"))?.takeUnretainedValue() as? NSObject
        else { return false }
        general.setValue(text, forKey: "string")
        return general.value(forKey: "string") as? String == text
    }
}
