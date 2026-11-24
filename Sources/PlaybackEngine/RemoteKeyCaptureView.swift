import Foundation
import SwiftUI
import UIKit

public enum ScrubDirection: Int, Sendable {
    case forward = 1
    case backward = -1
}

/// tvOS 正统焦点按键捕获视图：
/// - 当 `isCaptureEnabled == true`（全屏无 HUD / 抽屉关闭）时，`canBecomeFocused = true` 并主动抢占焦点，
///   在 tvOS 上聚焦的 UIView 100% 必然收到 Siri Remote 左/右键的 `pressesBegan` 与 `pressesEnded`，
///   精准区分短按 (<220ms) 与长按 (≥220ms)。
/// - 当 `isCaptureEnabled == false`（HUD 或抽屉弹出）时，`canBecomeFocused = false`，
///   将全部方向键无缝交还给 SwiftUI Focus Engine 操作按钮与滑块。
public struct RemoteKeyCaptureView: UIViewControllerRepresentable {
    public var isCaptureEnabled: Bool
    public var onShortPress: (ScrubDirection) -> Void
    public var onLongPressBegan: (ScrubDirection) -> Void
    public var onLongPressEnded: () -> Void
    public var onShowHUD: () -> Void
    public var onPlayPause: () -> Void
    public var onMenu: () -> Void

    public init(
        isCaptureEnabled: Bool,
        onShortPress: @escaping (ScrubDirection) -> Void,
        onLongPressBegan: @escaping (ScrubDirection) -> Void,
        onLongPressEnded: @escaping () -> Void,
        onShowHUD: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onMenu: @escaping () -> Void
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.onShortPress = onShortPress
        self.onLongPressBegan = onLongPressBegan
        self.onLongPressEnded = onLongPressEnded
        self.onShowHUD = onShowHUD
        self.onPlayPause = onPlayPause
        self.onMenu = onMenu
    }

    public func makeUIViewController(context: Context) -> KeyCaptureViewController {
        let vc = KeyCaptureViewController()
        vc.coordinator = context.coordinator
        vc.setCaptureEnabled(isCaptureEnabled)
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.setCaptureEnabled(isCaptureEnabled)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public final class Coordinator {
        var parent: RemoteKeyCaptureView
        init(parent: RemoteKeyCaptureView) { self.parent = parent }
    }

    public final class FocusableCaptureView: UIView {
        var captureActive: Bool = true
        override public var canBecomeFocused: Bool { captureActive }
        override public var canBecomeFirstResponder: Bool { captureActive }
    }

    public final class KeyCaptureViewController: UIViewController {
        weak var coordinator: Coordinator?
        private let captureView = FocusableCaptureView()
        private var holdTimer: Timer?
        private var activeDirection: ScrubDirection?
        private var didTriggerLongPress: Bool = false
        private let longPressThreshold: TimeInterval = 0.22 // 220ms 判定为长按

        public override func loadView() {
            captureView.backgroundColor = .clear
            self.view = captureView
        }

        public override var preferredFocusEnvironments: [UIFocusEnvironment] {
            captureView.captureActive ? [captureView] : []
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            requestFocusIfEnabled()
        }

        func setCaptureEnabled(_ enabled: Bool) {
            let changed = (captureView.captureActive != enabled)
            captureView.captureActive = enabled
            captureView.isUserInteractionEnabled = enabled
            if !enabled {
                holdTimer?.invalidate()
                holdTimer = nil
                activeDirection = nil
                didTriggerLongPress = false
            } else if changed {
                requestFocusIfEnabled()
            }
        }

        private func requestFocusIfEnabled() {
            guard captureView.captureActive else { return }
            captureView.becomeFirstResponder()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard captureView.captureActive, let press = presses.first else {
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
            case .upArrow, .downArrow, .select:
                coordinator?.parent.onShowHUD()
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
