import Combine
import Foundation
import Sparkle

struct UpdateConfiguration {
    let feedURL: URL?
    let publicEDKey: String?

    init(feedURL: URL?, publicEDKey: String?) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }

    init(bundle: Bundle) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        feedURL = feed.flatMap(URL.init(string:))
        publicEDKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }

    var isUsable: Bool {
        feedURL?.scheme == "https" && !(publicEDKey?.isEmpty ?? true)
    }
}

struct UpdateDriverState: Equatable {
    let canCheckForUpdates: Bool
    let automaticallyDownloadsUpdates: Bool
}

@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var stateDidChange: ((UpdateDriverState) -> Void)? { get set }

    func checkForUpdates()
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var automaticallyInstallsUpdates: Bool

    let isAvailable: Bool
    private let driver: UpdateDriving?

    convenience init(bundle: Bundle = .main) {
        let configuration = UpdateConfiguration(bundle: bundle)
        self.init(driver: configuration.isUsable ? SparkleUpdateDriver() : nil)
    }

    init(driver: UpdateDriving?) {
        self.driver = driver
        isAvailable = driver != nil
        canCheckForUpdates = driver?.canCheckForUpdates ?? false
        automaticallyInstallsUpdates = driver?.automaticallyDownloadsUpdates ?? false

        driver?.stateDidChange = { [weak self] state in
            self?.apply(state)
        }
    }

    func refresh() {
        guard let driver else { return }
        apply(UpdateDriverState(
            canCheckForUpdates: driver.canCheckForUpdates,
            automaticallyDownloadsUpdates: driver.automaticallyDownloadsUpdates
        ))
    }

    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        guard let driver else { return }
        // Update prompts depend on scheduled checks. This app intentionally keeps checks
        // enabled even when the user opts out of automatic installation.
        if !driver.automaticallyChecksForUpdates {
            driver.automaticallyChecksForUpdates = true
        }
        driver.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        guard let driver, driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    private func apply(_ state: UpdateDriverState) {
        canCheckForUpdates = state.canCheckForUpdates
        automaticallyInstallsUpdates = state.automaticallyDownloadsUpdates
    }
}

@MainActor
private final class SparkleUpdateDriver: UpdateDriving {
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    var stateDidChange: ((UpdateDriverState) -> Void)? {
        didSet { publishState() }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishState() }
            },
            controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishState() }
            },
        ]
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func publishState() {
        stateDidChange?(UpdateDriverState(
            canCheckForUpdates: canCheckForUpdates,
            automaticallyDownloadsUpdates: automaticallyDownloadsUpdates
        ))
    }
}
