import CoreGraphics
import Foundation
let want = Int(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    guard let num = w[kCGWindowNumber as String] as? Int, num == want,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
    print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
}
