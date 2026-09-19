import AppKit
import Foundation

/// How an application is presented: what to call it, what to show for it, and
/// what to key it by.
struct ApplicationIdentity {
    let bundleID: String
    let name: String
    let icon: NSImage
    let bundleURL: URL?
}
