import CoreGraphics
import Foundation
// Every YapToText window, on screen or not: id, name, bounds, layer, alpha, onscreen.
let opts: CGWindowListOption = [.optionAll]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "YapToText",
          let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("\(num) \"\(name)\" \(Int(b["X"] as? Double ?? 0)),\(Int(b["Y"] as? Double ?? 0)) \(Int(b["Width"] as? Double ?? 0))x\(Int(b["Height"] as? Double ?? 0)) layer=\(layer) alpha=\(alpha) onscreen=\(on)")
}
