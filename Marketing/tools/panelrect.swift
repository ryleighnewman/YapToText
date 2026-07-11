import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "YapToText",
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let wd = b["Width"] as? Double, let ht = b["Height"] as? Double,
          wd >= 280, wd <= 620, ht <= 420, ht >= 40 else { continue }
    print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
}
