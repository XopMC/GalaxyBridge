import Foundation

/// Admission closes synchronously; the returned production operation completes
/// asynchronously only after that exact retirement, including failed sends.
enum CameraControlCommand {
    enum Outcome: Sendable { case sent, unavailable, failed(Error) }
    enum Failure: Error { case unavailable }
    struct Completion: Sendable {
        let outcome: Outcome
        let retirement: Result<Void, Error>?
    }

    final class Operation: Sendable {
        let outcome: Outcome
        private let retirement: CameraRetirement?

        fileprivate init(outcome: Outcome, retirement: CameraRetirement?) {
            self.outcome = outcome
            self.retirement = retirement
        }

        func wait() async -> Completion {
            Completion(outcome: outcome, retirement: await retirement?.wait())
        }

        /// Used by AppModel's synchronous button entry point; no UI caller must
        /// create its own barrier or asynchronous admission window.
        @MainActor
        func observe(isCurrent: @escaping @MainActor @Sendable () -> Bool,
                     apply: @escaping @MainActor @Sendable (Completion) -> Void) -> Task<Void, Never> {
            Task {
                let completion = await wait()
                if isCurrent() { apply(completion) }
            }
        }
    }

    static func run<Control>(enabled: Bool, retireLocal: () -> CameraRetirement?,
                             retireFailedStart: () -> CameraRetirement? = { nil },
                             control: () -> Control?,
                             send: (Control) throws -> Void) -> Operation {
        let retirement = enabled ? nil : retireLocal()
        guard let control = control() else { return Operation(outcome: .unavailable, retirement: retirement) }
        do {
            try send(control)
            return Operation(outcome: .sent, retirement: retirement)
        } catch Failure.unavailable {
            return Operation(outcome: .unavailable, retirement: enabled ? retireFailedStart() : retirement)
        } catch {
            return Operation(outcome: .failed(error), retirement: enabled ? retireFailedStart() : retirement)
        }
    }
}
