import Foundation

/// External links for the Support / About surfaces. Update the handles here in one place.
enum SupportLinks {
    static let githubUser = "ryleighnewman"
    /// The official site: help, install, release notes, privacy.
    static let site = URL(string: "https://yaptotext.com")!
    static let siteHelp = URL(string: "https://yaptotext.com/help/")!
    static let siteWhatsNew = URL(string: "https://yaptotext.com/whats-new")!
    static let personalSite = URL(string: "https://ryleighnewman.com")!
    static let inputConfigAppStore = URL(string: "https://apps.apple.com/us/app/inputconfig/id6777759147?mt=12")!
    static let repo = URL(string: "https://github.com/ryleighnewman/YapToText")!
    static let issues = URL(string: "https://github.com/ryleighnewman/YapToText/issues")!
    static let releases = URL(string: "https://github.com/ryleighnewman/YapToText/releases")!
    // NOTE: no external donation links (GitHub Sponsors / Buy Me a Coffee). App Store guideline
    // 3.1.1 forbids steering users to payment mechanisms outside StoreKit; tips use IAP only.
    static let privacy = URL(string: "https://yaptotext.com/privacy")!
    static let privacySource = URL(string: "https://github.com/ryleighnewman/YapToText/blob/main/PRIVACY.md")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
