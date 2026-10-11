import Foundation

/// Public pages and the support address.
///
/// The site's base URL comes from the `VLWebsiteURL` Info.plist key, filled from the
/// `WEBSITE_URL` build setting (release builds take it from the repository variable of the same
/// name). Without one, the page links are hidden rather than pointing somewhere that 404s; the
/// support email always works.
public enum AppLinks {
    public static let supportEmail = "vsv.zhang@gmail.com"

    /// The App Store page, storefront-neutral: Apple sends each visitor to their own storefront.
    public static let appStore = URL(string: "https://apps.apple.com/app/id6800027452")!

    /// The China storefront's page for the same app. Share posters carry it as a QR code and the
    /// share message as a link: they travel mostly through WeChat and 小红书, where readers are in
    /// China and the storefront-neutral link can take an extra redirect inside WeChat's browser.
    public static let appStoreChina = URL(string: "https://apps.apple.com/cn/app/id6800027452")!

    public static var website: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "VLWebsiteURL") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://"), var url = URL(string: trimmed) else { return nil }
        if url.path.hasSuffix("/") == false { url.append(path: "") }
        return url
    }

    public static var privacyPolicy: URL? { website?.appending(path: "privacy.html") }
    public static var termsOfUse: URL? { website?.appending(path: "terms.html") }
    public static var support: URL? { website?.appending(path: "support.html") }

    public static var supportMail: URL {
        URL(string: "mailto:\(supportEmail)?subject=%E9%BA%BB%E8%96%AF%E8%83%8C%E5%8D%95%E8%AF%8D%20%E5%8F%8D%E9%A6%88")!
    }
}
