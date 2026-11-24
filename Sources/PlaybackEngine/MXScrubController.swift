import Foundation
import CoreGraphics
import Combine

public enum ScrubVisualMode: Equatable, Sendable {
    case idle
    /// Multi-stage gear shuttle: -5..-1 (rewind -64x..-4x), +1..+5 (forward +4x..+64x).
    case shuttle(gear: Int)
    /// Hold-to-scrub nonlinear fast ramp (12x -> 30x -> 60x -> 150x).
    case hold(direction: ScrubDirection, speedMultiplier: Int)
    /// Direct Siri Remote touchpad horizontal drag (MX Player swipe-to-seek).
    case touchpad
}

public enum ShuttleStepResult: Equatable, Sendable {
    case active(gear: Int)
    case exitedToNormalPlayback(commitTime: TimeInterval)
}

/// 仿安卓 MX Player 的三合一实时出画快进/快退控制器（单飞最新覆盖 Single-Flight Coalescing）：
/// 1. 多级实时加速（短按右键 4x -> 8x -> 16x -> 32x -> 64x，短按左键降档或 -4x ~ -64x 实时倒退，全程全屏同步出画）
/// 2. 长按无级极速快进/快退（0.8s 12x -> 2.0s 30x -> 3.5s 60x -> 150x，松手即从当前帧恢复播放）
/// 3. Siri Remote 触控板左右划屏（仿安卓 MX Player 大拇指拖进度，全屏实时跟手出画）
@MainActor
public final class MXScrubController: ObservableObject {
    public typealias PreviewFrameLoader = @Sendable (TimeInterval) async -> ScrubPreviewFrame?

    public static let shuttleSpeedTable: [Int] = [0, 4, 8, 16, 32, 64]

    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var activeMode: ScrubVisualMode = .idle
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var displayedFrameTime: TimeInterval = 0
    @Published public private(set) var deltaSeconds: TimeInterval = 0
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var isCommitting: Bool = false

    private var anchorTime: TimeInterval = 0
    private var currentDuration: TimeInterval = 0
    private var pressStartTime: Date?
    private var tickTask: Task<Void, Never>?
    private var decodeLoopTask: Task<Void, Never>?
    private var pendingPreviewTarget: TimeInterval?
    private var lastDecodedRequestTarget: TimeInterval = -.infinity
    private var commitEpoch: UInt64 = 0
    private let tickIntervalNs: UInt64 = 80_000_000 // 12.5 Hz smooth target clock

    public init() {}

    public var isShuttleActive: Bool {
        if case .shuttle = activeMode { return true }
        return false
    }

    public var shuttleGear: Int {
        if case .shuttle(let g) = activeMode { return g }
        return 0
    }

    public var speedBadgeText: String {
        switch activeMode {
        case .idle:
            return ""
        case .shuttle(let gear):
            let absG = min(max(abs(gear), 1), Self.shuttleSpeedTable.count - 1)
            let speed = Self.shuttleSpeedTable[absG]
            return gear >= 0 ? "\(absG)级 \(speed)x" : "\(absG)级 -\(speed)x"
        case .hold(let dir, let mult):
            return dir == .forward ? "长按 \(mult)x" : "长按 -\(mult)x"
        case .touchpad:
            return "MX 划屏"
        }
    }

    public var hintText: String {
        switch activeMode {
        case .shuttle:
            return "按 确认 / 播放键 立即从当前画面恢复播放 · 左/右键调档"
        case .hold:
            return "松开方向键立即从当前画面恢复播放"
        case .touchpad:
            return "松开拇指立即从当前画面恢复播放"
        case .idle:
            return ""
        }
    }

    /// 仿 MX Player 极速四段非线性长按曲线（倍速）
    private func holdSpeedMultiplier(elapsedHold: TimeInterval) -> Double {
        switch elapsedHold {
        case ..<0.8: return 12.0   // 12x：立刻有感快进，精细找镜头
        case ..<2.0: return 30.0   // 30x：中速扫片
        case ..<3.5: return 60.0   // 60x：每按 1 秒扫过 1 分钟
        default:     return 150.0  // 150x：每按 1 秒扫过 2.5 分钟，长片几秒直达片尾
        }
    }

    // MARK: - Mode 1: Multi-Stage Live Visual Shuttle (4x -> 8x -> 16x -> 32x -> 64x)

    @discardableResult
    public func stepShuttle(
        direction: ScrubDirection,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewFrameLoader
    ) -> ShuttleStepResult {
        let currentGear: Int
        if case .shuttle(let g) = activeMode {
            currentGear = g
        } else {
            currentGear = 0
        }

        let nextGear = max(-5, min(5, currentGear + direction.rawValue))
        if nextGear == 0 {
            return .exitedToNormalPlayback(commitTime: targetTime)
        }

        let wasIdle = !isScrubbing
        if wasIdle {
            beginSession(anchor: currentPlaybackTime, duration: duration)
            // Immediately nudge target slightly so the first frame reflects the chosen direction right away
            let initialNudge = 1.0 * Double(direction.rawValue)
            targetTime = clampTime(targetTime + initialNudge, duration: duration)
            deltaSeconds = targetTime - anchorTime
            pendingPreviewTarget = targetTime
        } else {
            currentDuration = duration
        }

        activeMode = .shuttle(gear: nextGear)
        startShuttleTickLoop(gear: nextGear)
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
        return .active(gear: nextGear)
    }

    // MARK: - Mode 2: Hold-to-Scrub (12x -> 30x -> 60x -> 150x)

    public func beginHold(
        direction: ScrubDirection,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewFrameLoader
    ) {
        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
        } else {
            currentDuration = duration
        }

        pressStartTime = Date()
        let initialSpeed = Int(holdSpeedMultiplier(elapsedHold: 0))
        activeMode = .hold(direction: direction, speedMultiplier: initialSpeed)

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            let dt = Double(self.tickIntervalNs) / 1_000_000_000.0
            while !Task.isCancelled && self.isScrubbing {
                let elapsed = Date().timeIntervalSince(self.pressStartTime ?? Date())
                let speed = self.holdSpeedMultiplier(elapsedHold: elapsed)
                self.activeMode = .hold(direction: direction, speedMultiplier: Int(speed))
                let step = speed * dt * Double(direction.rawValue)
                let next = self.clampTime(self.targetTime + step, duration: self.currentDuration)
                if next != self.targetTime || self.pendingPreviewTarget == nil {
                    self.targetTime = next
                    self.deltaSeconds = self.targetTime - self.anchorTime
                    self.pendingPreviewTarget = self.targetTime
                }
                try? await Task.sleep(nanoseconds: self.tickIntervalNs)
            }
        }

        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
    }

    // MARK: - Mode 3: Siri Remote Touchpad Pan (MX Player Thumb Swipe)

    public func beginTouchpadPan(
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewFrameLoader
    ) {
        tickTask?.cancel()
        tickTask = nil
        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
        } else {
            currentDuration = duration
        }
        activeMode = .touchpad
        pendingPreviewTarget = targetTime
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
    }

    public func updateTouchpadPan(deltaPoints: CGFloat, velocityPointsPerSec: CGFloat) {
        guard isScrubbing, activeMode == .touchpad else { return }

        let absVel = abs(Double(velocityPointsPerSec))
        let secPerPoint: Double
        switch absVel {
        case ..<280: secPerPoint = 0.14   // 慢划微调（精细逐段找画面）
        case ..<800: secPerPoint = 0.48   // 中速滑屏（一划几分钟）
        default:     secPerPoint = 1.25   // 快扫（一划十几分钟）
        }

        // Keep short clips (< 5 min) controllable without overshooting
        let durationScale: Double = (currentDuration > 0 && currentDuration < 300)
            ? max(0.25, currentDuration / 300.0)
            : 1.0

        let deltaSec = Double(deltaPoints) * secPerPoint * durationScale
        targetTime = clampTime(targetTime + deltaSec, duration: currentDuration)
        deltaSeconds = targetTime - anchorTime
        pendingPreviewTarget = targetTime
    }

    // MARK: - Commit & Cancel (Zero-Flicker Handoff)

    /// Stops scrubbing loops while keeping the last decoded `previewImage` visible on screen
    /// until `onCommit` finishes seeking and resuming 1x playback, then smoothly clears it.
    public func commit(onCommit: @escaping @MainActor (TimeInterval) async -> Void) {
        // Commit to the exact visible frame's timestamp when live preview is displayed ->
        // instant I-frame seek AND zero jump between preview frame and resumed playback!
        let finalTarget = (previewImage != nil) ? displayedFrameTime : targetTime
        stopLoopsOnly()
        isScrubbing = false
        activeMode = .idle
        isCommitting = true
        commitEpoch &+= 1
        let epoch = commitEpoch

        Task { @MainActor [weak self] in
            await onCommit(finalTarget)
            // Brief 100ms grace so the main KSPlayer/AVPlayer Metal layer presents the resumed frame
            // before lifting the preview overlay -> zero black flash!
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, self.commitEpoch == epoch, !self.isScrubbing else { return }
            self.previewImage = nil
            self.isCommitting = false
        }
    }

    public func cancelAll() {
        stopLoopsOnly()
        commitEpoch &+= 1
        isScrubbing = false
        activeMode = .idle
        isCommitting = false
        previewImage = nil
    }

    // MARK: - Internal Helpers

    private func beginSession(anchor: TimeInterval, duration: TimeInterval) {
        commitEpoch &+= 1
        isCommitting = false
        isScrubbing = true
        anchorTime = anchor
        targetTime = anchor
        displayedFrameTime = anchor
        deltaSeconds = 0
        currentDuration = duration
        lastDecodedRequestTarget = -.infinity
    }

    private func startShuttleTickLoop(gear: Int) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            let absGear = min(max(abs(gear), 1), Self.shuttleSpeedTable.count - 1)
            let speed = Double(Self.shuttleSpeedTable[absGear])
            let dirSign = gear >= 0 ? 1.0 : -1.0
            let dt = Double(self.tickIntervalNs) / 1_000_000_000.0

            while !Task.isCancelled && self.isScrubbing {
                let next = self.clampTime(self.targetTime + speed * dt * dirSign, duration: self.currentDuration)
                if next != self.targetTime {
                    self.targetTime = next
                    self.deltaSeconds = self.targetTime - self.anchorTime
                    self.pendingPreviewTarget = self.targetTime
                }
                try? await Task.sleep(nanoseconds: self.tickIntervalNs)
            }
        }
    }

    private func startDecodeLoopIfNeeded(onPreviewFrame: @escaping PreviewFrameLoader) {
        if decodeLoopTask != nil { return }
        decodeLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isScrubbing {
                if let nextTarget = self.pendingPreviewTarget {
                    self.pendingPreviewTarget = nil
                    // Avoid re-decoding near-identical timestamp twice in a row
                    if abs(nextTarget - self.lastDecodedRequestTarget) < 0.25 && self.previewImage != nil {
                        try? await Task.sleep(nanoseconds: 16_000_000)
                        continue
                    }
                    self.lastDecodedRequestTarget = nextTarget
                    if let frame = await onPreviewFrame(nextTarget) {
                        if !Task.isCancelled && self.isScrubbing {
                            self.previewImage = frame.cgImage
                            self.displayedFrameTime = frame.actualTime
                        }
                    } else if !Task.isCancelled && self.isScrubbing {
                        self.displayedFrameTime = nextTarget
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
        }
    }

    private func stopLoopsOnly() {
        tickTask?.cancel()
        tickTask = nil
        decodeLoopTask?.cancel()
        decodeLoopTask = nil
        pendingPreviewTarget = nil
    }

    private func clampTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }
}
