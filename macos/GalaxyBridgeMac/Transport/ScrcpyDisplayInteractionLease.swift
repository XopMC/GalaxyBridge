#if !GALAXYBRIDGE_APP_STORE
import Foundation

/// A producer closes admission immediately, but releases its shared logical
/// owner only after its exact media resources have physically settled.
@MainActor
final class ScrcpyDisplayInteractionLease {
    private let id = UUID()
    private let admission = PhoneDisplayInteractionAdmission()
    private let coordinator: PhoneDisplayInteractionCoordinator
    private let onFailure: () -> Void
    private(set) var admitted = false
    private(set) var cancelled = false
    private(set) var retired = false
    private var preparationStarted = false

    init(coordinator: PhoneDisplayInteractionCoordinator, onFailure: @escaping () -> Void = {}) throws {
        self.coordinator = coordinator; self.onFailure = onFailure
        try coordinator.reserve(id, admission: admission, onFailure: { [weak self] in
            guard let self, self.admitted, self.admission.isOpen, !self.cancelled, !self.retired else { return }
            self.onFailure()
        })
    }
    func prepare() async throws {
        guard !preparationStarted, !cancelled, !retired else { throw PhoneDisplayInteractionCoordinator.Failure.unavailable }
        preparationStarted = true
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await coordinator.prepare(id)
                try Task.checkCancellation()
                guard admission.isOpen, !cancelled, !retired else { throw CancellationError() }
                admitted = true
            } catch {
                cancelAdmission()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { [admission] in admission.close() }
    }
    func ready() {
        guard admitted, admission.isOpen, !cancelled, !retired else { return }
        coordinator.ready(id)
    }
    func cancelAdmission() {
        guard !cancelled, !retired else { return }
        cancelled = true; admitted = false
        admission.close()
        coordinator.cancelAdmission(id)
    }
    func retire(producerPhysicallySettled: Bool) async throws {
        guard !retired else { return }
        cancelAdmission()
        guard producerPhysicallySettled else { throw PhoneDisplayInteractionCoordinator.Failure.cleanupIncomplete }
        try await coordinator.release(id)
        retired = true
    }
}
#endif
