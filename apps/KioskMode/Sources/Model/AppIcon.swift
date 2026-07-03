import UIKit

/// Loads real Home Screen icons via a private UIKit call, with a cache so
/// scrolling the picker doesn't re-render them. Returns nil if the API is
/// unavailable or the app has no icon — callers fall back to a monogram tile.
enum AppIcon {
    private static let cache = NSCache<NSString, UIImage>()
    private static let selector = NSSelectorFromString(
        "_applicationIconImageForBundleIdentifier:format:scale:")
    private static let available = UIImage.responds(to: selector)

    static func image(for bundleID: String) -> UIImage? {
        guard available, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // format 2 ≈ Home Screen size; scale to the current display.
        guard let img = UIImage._applicationIconImage(
            forBundleIdentifier: bundleID, format: 2, scale: UIScreen.main.scale) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
