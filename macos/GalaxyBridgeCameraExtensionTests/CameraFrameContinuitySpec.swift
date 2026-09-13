import Foundation

@main
enum CameraFrameContinuitySpec {
    static func main() {
        var policy = CameraFrameContinuityPolicy(staleAfterNanoseconds: 750_000_000)

        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: false, nowNanoseconds: 10) == .placeholder,
               "a stream without a first frame must publish a placeholder")
        expect(policy.decide(hasFreshFrame: true, hasCachedFrame: false, nowNanoseconds: 100) == .fresh,
               "a valid producer frame must be accepted")
        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: true, nowNanoseconds: 749_999_999) == .cached,
               "the last valid frame must bridge short producer gaps")
        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: true, nowNanoseconds: 750_000_100) == .cached,
               "the hold timeout is measured from the latest fresh frame")
        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: true, nowNanoseconds: 750_000_101) == .placeholder,
               "a missing source must become a placeholder after 750 ms")

        expect(policy.decide(hasFreshFrame: true, hasCachedFrame: true, nowNanoseconds: 900_000_000) == .fresh,
               "a resumed producer must replace the cached frame")
        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: true, nowNanoseconds: 1_649_999_999) == .cached,
               "a resumed frame starts a new hold interval")
        expect(policy.decide(hasFreshFrame: false, hasCachedFrame: true, nowNanoseconds: 1_650_000_001) == .placeholder,
               "the restarted hold interval must also expire")

        print("Camera frame continuity spec passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
