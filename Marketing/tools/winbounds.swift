import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "YapToText",
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let wd = b["Width"] as? Double, let ht = b["Height"] as? Double,
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
}
