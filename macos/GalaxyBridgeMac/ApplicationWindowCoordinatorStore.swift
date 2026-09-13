#if GALAXYBRIDGE_APP_STORE
import SwiftUI

@MainActor
final class ApplicationWindowCoordinator: ObservableObject {
    func present(application: ApplicationCatalogItem, device: DeviceRow, model: AppModel) {}
    func shutdownForApplicationTermination() async {}
}
#endif
