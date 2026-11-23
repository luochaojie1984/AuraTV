import Foundation
import AVKit
import UIKit
import CoreMedia

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

    /// Applies the source's native refresh rate (with its real format
    /// description) so the TV switches to 24/25/50/60 Hz correctly.
    public func apply(refreshRate: Float, formatDescription: CMFormatDescription?) {
        guard let manager = resolveManager() else { return }
        guard let formatDescription else { return }
        let rate: Float = refreshRate > 0 ? refreshRate : 60
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: rate,
            formatDescription: formatDescription
        )
    }

    public func reset() {
        resolveManager()?.preferredDisplayCriteria = nil
    }
}
