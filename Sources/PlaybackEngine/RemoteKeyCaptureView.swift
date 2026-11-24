import Foundation
import SwiftUI
import UIKit

public enum ScrubDirection: Int, Sendable {
    case forward = 1
    case backward = -1
}

/// tvOS 正统焦点按键 + Siri Remote 触控板手势捕获视图：
/// - `isCaptureEnabled == true`（全屏播放且无 HUD/抽屉）时主动持有焦点，精准捕获：
///   1. 左/右键短按 (<220ms) → 触发多级实时快进/快退（或定长跳秒）
///   2. 左/右键长按 (≥220ms) → 触发 MX 无级实时快进/快退，松手即恢复
///   3. Siri Remote 触控板左右划动（48pt 防误触死区 + 水平主方向判定）→ 仿安卓 MX Player 拇指实时滑屏
///   4. 确认键 (Select) / 播放暂停键 / 返回键 (Menu) → 快进中直接定格并从当前画面恢复播放
/// - `isCaptureEnabled == false`（HUD 或抽屉打开）时释放焦点与手势，交还 SwiftUI Focus Engine。
public struct RemoteKeyCaptureView: UIViewControllerRepresentable {
    public var isCaptureEnabled: Bool
    public var enableTouchpadScrub: Bool
    public var onShortPress: (ScrubDirection) -> Void
    public var onLongPressBegan: (ScrubDirection) -> Void
    public var onLongPressEnded: () -> Void
    public var onTouchpadPanBegan: () -> Void
    public var onTouchpadPanChanged: (_ deltaPoints: CGFloat, _ velocityPointsPerSec: CGFloat) -> Void
    public var onTouchpadPanEnded: () -> Void
    public var onSelectPress: () -> Void
    public var onShowHUD: () -> Void
    public var onPlayPause: () -> Void
    public var onMenu: () -> Void

    public init(
        isCaptureEnabled: Bool,
        enableTouchpadScrub: Bool = true,
        onShortPress: @escaping (ScrubDirection) -> Void,
        onLongPressBegan: @escaping (ScrubDirection) -> Void,
        onLongPressEnded: @escaping () -> Void,
        onTouchpadPanBegan: @escaping () -> Void = {},
        onTouchpadPanChanged: @escaping (_ deltaPoints: CGFloat, _ velocityPointsPerSec: CGFloat) -> Void = { _, _ in },
        onTouchpadPanEnded: @escaping () -> Void = {},
        onSelectPress: @escaping () -> Void = {},
        onShowHUD: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onMenu: @escaping () -> Void
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.enableTouchpadScrub = enableTouchpadScrub
        self.onShortPress = onShortPress
        self.onLongPressBegan = onLongPressBegan
        self.onLongPressEnded = onLongPressEnded
        self.onTouchpadPanBegan = onTouchpadPanBegan
        self.onTouchpadPanChanged = onTouchpadPanChanged
        self.onTouchpadPanEnded = onTouchpadPanEnded
        self.onSelectPress = onSelectPress
        self.onShowHUD = onShowHUD
        self.onPlayPause = onPlayPause
        self.onMenu = onMenu
    }

    public func makeUIViewController(context: Context) -> KeyCaptureViewController {
        let vc = KeyCaptureViewController()
        vc.coordinator = context.coordinator
        vc.setCaptureEnabled(isCaptureEnabled, touchpadEnabled: enableTouchpadScrub)
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.setCaptureEnabled(isCaptureEnabled, touchpadEnabled: enableTouchpadScrub)
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
        private let longPressThreshold: TimeInterval = 0.18 // 180ms 灵敏判定为长按

        // Siri Remote touchpad pan scrub state
        private var panGesture: UIPanGestureRecognizer?
        private var isTouchpadScrubbing: Bool = false
        private var lastPanX: CGFloat = 0
        private let panActivationDeadzone: CGFloat = 48.0

        public override func loadView() {
            captureView.backgroundColor = .clear
            self.view = captureView
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouchpadPan(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            captureView.addGestureRecognizer(pan)
            self.panGesture = pan
        }

        public override var preferredFocusEnvironments: [UIFocusEnvironment] {
            captureView.captureActive ? [captureView] : []
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            requestFocusIfEnabled()
        }

        func setCaptureEnabled(_ enabled: Bool, touchpadEnabled: Bool) {
            let changed = (captureView.captureActive != enabled)
            captureView.captureActive = enabled
            captureView.isUserInteractionEnabled = enabled
            panGesture?.isEnabled = enabled && touchpadEnabled

            if !enabled {
                holdTimer?.invalidate()
                holdTimer = nil
                activeDirection = nil
                didTriggerLongPress = false
                if isTouchpadScrubbing {
                    isTouchpadScrubbing = false
                    coordinator?.parent.onTouchpadPanEnded()
                }
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

        @objc private func handleTouchpadPan(_ gesture: UIPanGestureRecognizer) {
            guard captureView.captureActive,
                  coordinator?.parent.enableTouchpadScrub == true,
                  activeDirection == nil else {
                return
            }

            switch gesture.state {
            case .began:
                isTouchpadScrubbing = false
                lastPanX = 0

            case .changed:
                let translation = gesture.translation(in: captureView)
                let velocity = gesture.velocity(in: captureView)

                if !isTouchpadScrubbing {
                    // Require clear horizontal intent beyond 48pt deadzone to avoid accidental thumb rest
                    if abs(translation.x) >= panActivationDeadzone && abs(translation.x) > abs(translation.y) * 1.4 {
                        isTouchpadScrubbing = true
                        lastPanX = translation.x
                        coordinator?.parent.onTouchpadPanBegan()
                    }
                } else {
                    let dx = translation.x - lastPanX
                    lastPanX = translation.x
                    if abs(dx) > 0.25 {
                        coordinator?.parent.onTouchpadPanChanged(dx, velocity.x)
                    }
                }

            case .ended, .cancelled, .failed:
                if isTouchpadScrubbing {
                    isTouchpadScrubbing = false
                    coordinator?.parent.onTouchpadPanEnded()
                }

            default:
                break
            }
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard captureView.captureActive, let press = presses.first else {
                super.pressesBegan(presses, with: event)
                return
            }

            // If user clicks a physical button while thumb is still resting on touchpad, finish pan cleanly
            if isTouchpadScrubbing {
                isTouchpadScrubbing = false
                coordinator?.parent.onTouchpadPanEnded()
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
            case .select:
                coordinator?.parent.onSelectPress()
            case .upArrow, .downArrow:
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
