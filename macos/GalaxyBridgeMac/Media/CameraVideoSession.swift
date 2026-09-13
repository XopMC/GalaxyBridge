import Foundation
import GalaxyBridgeCore

/// Each Start constructs a new decoder whose closures permanently capture that
/// attempt's permit. Ingress snapshots this session before the first queued hop.
final class CameraVideoSession: @unchecked Sendable {
    let permit: CameraPublicationPermit
    private let lock = NSLock()
    private var epoch: UInt32?
    private let decoder: VideoToolboxDecoder
    private let preview: CameraPreviewDelivery

    init(permit: CameraPublicationPermit, publication: CameraPublication,
         preview: CameraPreviewDelivery, failure: @escaping @Sendable (Error) -> Void) {
        self.permit = permit
        self.preview = preview
        decoder = VideoToolboxDecoder(
            cameraAdmission: { permit.isAdmitted },
            frameHandler: { pixelBuffer, time, epoch in
                guard permit.isAdmitted else { return }
                let frame = CameraPublicationFrame(pixelBuffer: pixelBuffer, presentationTime: time,
                                                   epoch: epoch, permit: permit)
                publication.submit(frame)
                preview.submit(frame)
            },
            failureHandler: { error in
                guard permit.isAdmitted else { return }
                failure(error)
            }
        )
    }

    func consume(_ packet: MediaPacket) {
        lock.withLock {
            guard permit.isAdmitted else { return }
            if epoch != packet.epoch {
                epoch = packet.epoch
                decoder.consume(.codec(.h264))
                decoder.consume(.videoSession(.init(width: 1, height: 1, clientResized: true)), epoch: packet.epoch)
            }
            decoder.consume(.packet(.init(isConfiguration: packet.flags.contains(.configuration),
                                          isKeyFrame: packet.flags.contains(.keyFrame),
                                          presentationTimeUs: packet.flags.contains(.configuration) ? nil : packet.presentationTimeUs,
                                          payload: packet.payload)), epoch: packet.epoch)
        }
    }

    func invalidate() {
        permit.revoke()
        preview.clear()
        decoder.invalidate()
    }
}

/// One authenticated connection's ingress. An empty/reconnected ingress cannot
/// acquire ownership from unsolicited media. Only AppModel's Start installs it.
final class CameraMediaIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CameraVideoSession?

    func install(_ session: CameraVideoSession) { lock.withLock { self.session = session } }

    func consume(_ packet: MediaPacket) {
        let stampedSession = lock.withLock { session }
        stampedSession?.consume(packet)
    }

    func invalidate() {
        let old = lock.withLock { let value = session; session = nil; return value }
        old?.invalidate()
    }
}
