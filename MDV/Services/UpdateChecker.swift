import Foundation
import Sparkle

@Observable
final class UpdateChecker: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Only initialize Sparkle if a valid EdDSA key is configured
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !key.isEmpty,
           !key.hasPrefix("PLACEHOLDER") {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            controller?.updater.automaticallyChecksForUpdates = false
            controller?.updater.automaticallyDownloadsUpdates = false
        }
    }

    var isConfigured: Bool {
        controller != nil
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/jayl930/MDV/main/appcast.xml"
    }
}
