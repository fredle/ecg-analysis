import Foundation

enum AppConfig {
    static let baseURLOverrideKey = "apiBaseURL"

    static let defaultBaseURL = URL(string: "https://ecg-analyser-945103730531.europe-west2.run.app")!

    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: baseURLOverrideKey),
           let url = URL(string: s) {
            return url
        }
        return defaultBaseURL
    }

    static var baseURLOverride: String? {
        UserDefaults.standard.string(forKey: baseURLOverrideKey)
    }

    static func setOverride(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.absoluteString, forKey: baseURLOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: baseURLOverrideKey)
        }
    }
}
