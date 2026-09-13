import CoreMediaIO
import Foundation

let source = GalaxyBridgeCameraProviderSource()
let provider = CMIOExtensionProvider(source: source, clientQueue: nil)
try source.installDevice(on: provider)
CMIOExtensionProvider.startService(provider: provider)
RunLoop.main.run()
