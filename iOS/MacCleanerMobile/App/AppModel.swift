import Observation
import SwiftUI

/// The app's state: one model per feature, plus the device's storage.
@MainActor
@Observable
final class AppModel {
    enum Tab: Hashable { case overview, clean, protect, guides }

    let photos = PhotoCleanupModel()
    let contacts = ContactCleanupModel()
    let files = FileCleanupModel()
    let protection = ProtectionModel()
    let device = DeviceInfo.current()
    private(set) var storage: DeviceStorage? = DeviceStorage.current()
    var selectedTab: Tab = DebugLaunch.tab ?? .overview
    /// The introduction, shown again from the Overview's info button.
    var showsIntroduction = false

    func refreshStorage() {
        storage = DeviceStorage.current()
    }

    /// What the guides need to pick the ones that help now.
    var guideContext: GuideContext {
        GuideContext(storage: storage, device: device, deletedPhotos: photos.hasDeletedItems,
                     deletedFiles: files.hasDeletedItems, safariProtectionEnabled: protection.safariProtectionEnabled,
                     systemUpToDate: protection.systemUpToDate, passcodeSet: protection.passcodeSet,
                     availableSystemVersion: protection.availableSystemVersion)
    }

    /// Everything the last scans found that could be freed.
    var reclaimableBytes: Int64? {
        let parts = [photos.photoReclaimableBytes, photos.videoReclaimableBytes, files.reclaimableBytes].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}
