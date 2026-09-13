import Foundation

@main
enum RecordingDestinationSpec {
    static func main() {
        let movies = URL(fileURLWithPath: "/Users/test/Movies", isDirectory: true)
        let chosen = URL(fileURLWithPath: "/Users/test/Desktop/GalaxyBridge.mov")
        var selections = 0

#if GALAXYBRIDGE_APP_STORE
        precondition(
            RecordingDestinationPolicy.requiresUserSelection,
            "the App Store build must require a user-selected recording URL"
        )
        let cancelled = RecordingDestinationPolicy.resolve(
            suggestedFilename: "GalaxyBridge-2026.mov",
            moviesDirectory: movies
        ) {
            selections += 1
            return nil
        }
        precondition(cancelled == nil, "cancelling the save panel must cancel recording")

        let selected = RecordingDestinationPolicy.resolve(
            suggestedFilename: "GalaxyBridge-2026.mov",
            moviesDirectory: movies
        ) {
            selections += 1
            return chosen
        }
        precondition(selected == chosen, "the App Store build must preserve the selected URL")
        precondition(selections == 2, "the App Store build must ask on every new recording")
#else
        precondition(
            !RecordingDestinationPolicy.requiresUserSelection,
            "the Internal build must preserve its automatic Movies destination"
        )
        let resolved = RecordingDestinationPolicy.resolve(
            suggestedFilename: "GalaxyBridge-2026.mov",
            moviesDirectory: movies
        ) {
            selections += 1
            return chosen
        }
        precondition(
            resolved == movies.appendingPathComponent("GalaxyBridge-2026.mov"),
            "the Internal build must continue writing to Movies"
        )
        precondition(selections == 0, "the Internal build must not show a save panel")
#endif

        print("PASS recording destination policy")
    }
}
