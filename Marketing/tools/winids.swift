import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "YapToText",
          let num = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          let layer = w[kCGWindowLayer as String] as? Int else { continue }
    print("\(num) \(Int(width))x\(Int(height)) layer=\(layer)")
}
