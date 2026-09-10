// Post a DEBUG hook notification to the running YapToText.
// Usage: swift postnote.swift <name> [object]
// Lived in /tmp for the 1.4 rounds and kept getting cleaned up mid-shoot; it belongs here.
import Foundation
let a = CommandLine.arguments
guard a.count >= 2 else { FileHandle.standardError.write("usage: postnote.swift <name> [object]\n".data(using: .utf8)!); exit(2) }
DistributedNotificationCenter.default().postNotificationName(
    .init(a[1]), object: a.count > 2 ? a[2] : nil, userInfo: nil, deliverImmediately: true)
