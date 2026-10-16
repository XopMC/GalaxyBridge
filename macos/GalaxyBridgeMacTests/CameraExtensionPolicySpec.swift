import Foundation
import SystemExtensions

@main
struct CameraExtensionPolicySpec {
    static func main() {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        func replace(_ oldVersion: String, _ oldBuild: String, _ newVersion: String, _ newBuild: String) -> Bool {
            CameraExtensionPolicy.shouldReplace(existingVersion: oldVersion, existingBuild: oldBuild, incomingVersion: newVersion, incomingBuild: newBuild)
        }
        expect(replace("0.1.9", "99", "0.1.10", "1"), "Numeric version upgrade must replace")
        expect(!replace("0.1.10", "1", "0.1.9", "99"), "Numeric downgrade must not replace")
        expect(replace("0.1.1", "2", "0.1.1", "10"), "Same version with newer build must replace")
        expect(!replace("0.1.1", "10", "0.1.1", "2"), "Build downgrade must not replace")
        expect(!replace("0.1.1", "2", "0.1.1", "2"), "Identical release must not replace")
        expect(!replace("1.0", "2", "1.0.0", "2"), "Trailing zeros denote equal versions")
        expect(!replace("1.0", "2", "bogus", "3"), "Malformed release must not replace")
        expect(CameraExtensionPolicy.completionStatusKey(.completed) == "CAMERA_EXTENSION_READY", "Completed activation can report ready")
        expect(CameraExtensionPolicy.completionStatusKey(.willCompleteAfterReboot) != "CAMERA_EXTENSION_READY", "Reboot required must never report ready")
        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS camera extension numeric upgrade/build policy and reboot completion")
    }
}
