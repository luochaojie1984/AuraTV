import Foundation
import SwiftUI
import UIKit

public enum ScrubDirection: Int, Sendable {
    case forward = 1
    case backward = -1
}

/// 精确区分 tvOS Siri Remote 左/右键的「短按」与「长按（按住/松手）」。
/// 当 isCaptureEnabled == false（例如弹出字幕设置抽屉或暂停菜单时）自动放行按键给 SwiftUI Focus Engine！
public struct RemoteKeyCaptureView: UIViewControllerRepresentable {
    public var isCaptureEnabled: Bool
    public var onShortPress: (ScrubDirection) -> Void
    public var onLongPressBegan: (ScrubDirection) -> Void
    public var onLongPressEnded: () -> Void
    public var onPlayPause: () -> Void
    public var onMenu: () -> Void

    public init(
        isCaptureEnabled: Bool,
        onShortPress: @escaping (ScrubDirection) -> Void,
        onLongPressBegan: @escaping (ScrubDirection) -> Void,
        onLongPressEnded: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onMenu: @escaping () -> Void
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.onShortPress = onShortPress
        self.onLongPressBegan = onLongPressBegan
        self.onLongPressEnded = onLongPressEnded
        self.onPlayPause = onPlayPause
        self.onMenu = onMenu
    }

    public func makeUIViewController(context: Context) -> KeyCaptureViewController {
        let vc = KeyCaptureViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.isCaptureEnabled = isCaptureEnabled
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public final class Coordinator {
        var parent: RemoteKeyCaptureView
        init(parent: RemoteKeyCaptureView) { self.parent = parent }
    }

    public final class KeyCaptureViewController: UIViewController {
        weak var coordinator: Coordinator?
        var isCaptureEnabled: Bool = true
        private var holdTimer: Timer?
        private var activeDirection: ScrubDirection?
        private var didTriggerLongPress: Bool = false
        private let longPressThreshold: TimeInterval = 0.22 // 220ms 判定为长按

        public override var canBecomeFirstResponder: Bool { true }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard isCaptureEnabled, let press = presses.first else {
                super.pressesBegan(presses, with: event)
                return
            }
            switch press.type {
            case .rightArrow, .leftArrow:
                let dir: ScrubDirection = (press.type == .rightArrow) ? .forward : .backward
                activeDirection = dir
                didTriggerLongPress = false
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let d = self.activeDirection else { return }
                        self.didTriggerLongPress = true
                        self.coordinator?.parent.onLongPressBegan(d)
                    }
                }
            case .playPause:
                coordinator?.parent.onPlayPause()
            case .menu:
                coordinator?.parent.onMenu()
            default:
                super.pressesBegan(presses, with: event)
            }
        }

        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: false)
        }

        public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handlePressRelease(presses: presses, event: event, isCancelled: true)
        }

        private func handlePressRelease(presses: Set<UIPress>, event: UIPressesEvent?, isCancelled: Bool) {
            guard let press = presses.first, press.type == .rightArrow || press.type == .leftArrow else {
                if isCancelled { super.pressesCancelled(presses, with: event) }
                else { super.pressesEnded(presses, with: event) }
                return
            }
            holdTimer?.invalidate()
            holdTimer = nil
            if didTriggerLongPress {
                coordinator?.parent.onLongPressEnded()
            } else if !isCancelled, let dir = activeDirection {
                coordinator?.parent.onShortPress(dir)
            }
            activeDirection = nil
            didTriggerLongPress = false
        }
    }
}
