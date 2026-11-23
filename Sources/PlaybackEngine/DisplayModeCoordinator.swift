import Foundation
import AVKit
import UIKit

/// Drives `AVDisplayManager` so the TV switches to the source's native frame
/// rate / dynamic range on playback start and cleanly returns to 4K60 SDR on exit.
@MainActor
public final class DisplayModeCoordinator {
    public static let shared = DisplayModeCoordinator()

    private init() {}

    private func resolveManager() -> AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let manager = scene.windows.first?.avDisplayManager {
                return manager
            }
        }
        return nil
    }

    /// - Parameter info: probed source technical info; `dynamicRange` is SDR/HDR10/HLG/DV.
    public func apply(info: MediaTechnicalInfo) {
        guard let manager = resolveManager() else { return }
        let refresh: Float = info.frameRate > 0 ? Float(info.frameRate) : 60
        let range: Int
        switch info.dynamicRange.uppercased() {
        case "SDR": range = 0
        default: range = 1
        }
        let criteria = AVDisplayCriteria(refreshRate: refresh, videoDynamicRange: range)
        manager.preferredDisplayCriteria = criteria
    }

    public func reset() {
        resolveManager()?.preferredDisplayCriteria = nil
    }
}
