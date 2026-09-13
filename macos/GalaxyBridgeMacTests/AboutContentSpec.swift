import Foundation

@main
enum AboutContentSpec {
    static func main() {
        precondition(AboutContent.author == "Mikhail Khoroshavin aka XopMC")
        precondition(AboutContent.githubURL.scheme == "https")
        precondition(AboutContent.githubURL.host == "github.com")
        precondition(AboutContent.githubURL.path == "/XopMC")
        print("PASS about content credits the author and canonical GitHub profile")
    }
}
