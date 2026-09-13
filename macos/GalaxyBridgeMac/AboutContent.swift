import Foundation

enum AboutContent {
    static let author = "Mikhail Khoroshavin aka XopMC"
    static let githubURL = URL(string: "https://github.com/XopMC")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
