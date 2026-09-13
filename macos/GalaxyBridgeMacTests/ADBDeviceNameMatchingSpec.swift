import Foundation

@main
enum ADBDeviceNameMatchingSpec {
    static func main() {
        precondition(ADBDeviceNameMatching.matches(model: "SM_S928B", companionName: "samsung SM-S928B"), "S24 must remain identifiable when Fold also connects")
        precondition(ADBDeviceNameMatching.matches(model: "SM_F946B", companionName: "samsung SM-F946B"))
        precondition(!ADBDeviceNameMatching.matches(model: "SM_F946B", companionName: "samsung SM-S928B"))
        precondition(!ADBDeviceNameMatching.matches(model: "", companionName: "samsung SM-S928B"))
        precondition(!ADBDeviceNameMatching.matches(model: "___", companionName: "samsung SM-S928B"))
        print("ADB/Companion model spelling and multiple-phone candidate checks passed")
    }
}
