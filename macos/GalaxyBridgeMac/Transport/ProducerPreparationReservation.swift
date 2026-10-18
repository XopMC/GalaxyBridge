#if !GALAXYBRIDGE_APP_STORE
import Foundation

private final class ProducerPreparationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var accepting: Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
}

/// Retained before START is queued. A caller losing its result still owns the
/// startup task and must positively retire the producer before releasing it.
@MainActor
final class ProducerPreparationReservation<Resource: Sendable> {
    private let admission = ProducerPreparationAdmission()
    private var operation: ((ProducerPreparationReservation) async throws -> Resource)?
    private var cleanupAction: (() async throws -> Void)?
    private var retirementAction: (() -> Void)?
    private let cancelResource: (Resource) -> Void
    private var startup: Task<Resource, Error>?
    private var cleanupTask: Task<Void, Error>?
    private var cleanupID: UUID?
    private var resource: Resource?
    private var resourceCancelled = false
    private(set) var dispatched = false
    private(set) var retired = false
    var accepting: Bool { admission.accepting && !retired }

    init(operation: @escaping (ProducerPreparationReservation) async throws -> Resource,
         cancelResource: @escaping (Resource) -> Void,
         cleanup: @escaping () async throws -> Void,
         onRetired: @escaping () -> Void = {}) {
        self.operation = operation; self.cancelResource = cancelResource
        cleanupAction = cleanup; retirementAction = onRetired
    }
    func checkAdmission() throws {
        try Task.checkCancellation()
        guard accepting else { throw CancellationError() }
    }
    /// Call synchronously after the transport queues START, without suspension
    /// between the final admission check and this monotonic uncertainty fence.
    func markDispatched() { dispatched = true }

    func value() async throws -> Resource {
        try await withTaskCancellationHandler {
            try checkAdmission()
            let task: Task<Resource, Error>
            if let startup { task = startup }
            else {
                task = Task { [self] in
                    try checkAdmission()
                    guard let operation else { throw CancellationError() }
                    let result = try await operation(self)
                    resource = result
                    if !accepting { cancelReturnedResource() }
                    return result
                }
                startup = task
            }
            let result = try await task.value
            try checkAdmission()
            return result
        } onCancel: { [admission] in admission.close() }
    }
    func cancelAdmission() {
        admission.close()
        startup?.cancel()
        cancelReturnedResource()
    }
    private func cancelReturnedResource() {
        guard let resource, !resourceCancelled else { return }
        resourceCancelled = true; cancelResource(resource)
    }
    func retire() async throws {
        guard !retired else { return }
        cancelAdmission()
        let task: Task<Void, Error>
        let id: UUID
        if let cleanupTask, let cleanupID { task = cleanupTask; id = cleanupID }
        else {
            id = UUID()
            // An independent task must finish STOP even if its awaiting caller
            // is cancelled. It joins only producer startup, never Session.prepare.
            task = Task { [self] in
                if let startup { _ = await startup.result }
                cancelReturnedResource()
                if dispatched { try await cleanupAction?() }
                retired = true
                retirementAction?()
                operation = nil; cleanupAction = nil; retirementAction = nil
                resource = nil; startup = nil
            }
            cleanupTask = task
            cleanupID = id
        }
        defer { if cleanupID == id { cleanupTask = nil; cleanupID = nil } }
        try await task.value
    }
}
#endif
