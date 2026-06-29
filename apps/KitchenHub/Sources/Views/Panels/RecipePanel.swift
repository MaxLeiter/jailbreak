import SwiftUI

/// Shows a recipe site in a web view. The URL is configurable per panel via the
/// settings gear in edit mode (stored in the panel config).
struct RecipePanel: View {
    static let defaultURL = "https://www.allrecipes.com"
    let urlString: String

    var body: some View {
        if let url = resolvedURL {
            WebView(url: url)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.subtext)
                Text("Set a recipe URL")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Edit mode → gear icon")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtext)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
    }

    private var resolvedURL: URL? {
        let s = urlString.trimmingCharacters(in: .whitespaces)
        let candidate = s.isEmpty ? Self.defaultURL : s
        guard let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}
