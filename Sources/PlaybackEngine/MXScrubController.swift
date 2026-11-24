import Foundation
import CoreGraphics
import Combine
import AppPreferences

public enum ScrubVisualMode: Equatable, Sendable {
    case idle
    /// Rapid fixed-step jump (±5s, ±10s, ±15s ... coalesced seamlessly on multi-taps).
    case shortStep(direction: ScrubDirection)
    /// Multi-stage gear shuttle: -5..-1 (rewind -64x..-4x), +1..+5 (forward +4x..+64x).
    case shuttle(gear: Int)
    /// Hold-to-scrub nonlinear fast ramp driven by `LongPressSpeedProfile`.
    case hold(direction: ScrubDirection, speedMultiplier: Int)
    /// Direct Siri Remote touchpad horizontal drag (MX Player swipe-to-seek).
    case touchpad
}

public enum ShuttleStepResult: Equatable, Sendable {
    case active(gear: Int)
    case exitedToNormalPlayback(commitTime: TimeInterval)
}

/// 仿安卓 MX Player 丝滑实时出画快进/快退控制器：
/// - 视频帧通过 `framePresenter` 直接写入 `CALayer.contents`（<0.1ms，零 SwiftUI 重绘开销，30~60fps 丝滑刷帧）
/// - 支持：5秒为单位定长连点跳秒 + MX 三档可调长按极速快进 + 多级加速 + Siri Remote 触控板划屏
@MainActor
public final class MXScrubController: ObservableObject {
    public typealias PreviewFrameLoader = @Sendable (TimeInterval) async -> ScrubDecodeOutcome

    public static let shuttleSpeedTable: [Int] = [0, 4, 8, 16, 32, 64]

    /// Direct CoreAnimation presenter — updates video frames WITHOUT triggering SwiftUI view diffs!
    public let framePresenter = ScrubFramePresenter()

    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var isShowingBar: Bool = false
    @Published public private(set) var activeMode: ScrubVisualMode = .idle
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var displayedFrameTime: TimeInterval = 0
    @Published public private(set) var deltaSeconds: TimeInterval = 0
    @Published public private(set) var isCommitting: Bool = false

    private var anchorTime: TimeInterval = 0
    private var currentDuration: TimeInterval = 0
    private var pressStartTime: Date?
    private var tickTask: Task<Void, Never>?
    private var decodeLoopTask: Task<Void, Never>?
    private var shortCommitTask: Task<Void, Never>?
    private var barHideTask: Task<Void, Never>?
    private var pendingPreviewTarget: TimeInterval?
    private var lastDecodedRequestTarget: TimeInterval = -.infinity
    private var commitEpoch: UInt64 = 0
    private let tickIntervalNs: UInt64 = 33_000_000 // ~30 Hz silky target clock

    public init() {}

    public var isShuttleActive: Bool {
        if case .shuttle = activeMode { return true }
        return false
    }

    public var speedLabel: String {
        switch activeMode {
        case .idle:
            return ""
        case .shortStep(let dir):
            return dir == .forward ? ">>>" : "<<<"
        case .shuttle(let gear):
            let absG = min(max(abs(gear), 1), Self.shuttleSpeedTable.count - 1)
            let speed = Self.shuttleSpeedTable[absG]
            return gear >= 0 ? ">>> \(speed)x" : "<<< -\(speed)x"
        case .hold(let dir, let mult):
            return dir == .forward ? ">>> \(mult)x" : "<<< -\(mult)x"
        case .touchpad:
            return deltaSeconds >= 0 ? ">>>" : "<<<"
        }
    }

    /// 连续指数平滑加速曲线（无顿挫档位跳变，按住越久越快并带平滑速度上限）
    private func holdSpeedMultiplier(elapsedHold: TimeInterval, profile: LongPressSpeedProfile) -> Double {
        let t = max(0, elapsedHold)
        switch profile {
        case .gentle:
            return min(60.0, 4.0 * pow(2.15, t))
        case .mxStandard:
            return min(120.0, 6.0 * pow(2.25, t))
        case .turbo:
            return min(240.0, 10.0 * pow(2.40, t))
        }
    }

    // MARK: - Mode 0: Rapid-Tap Coalesced Fixed-Step Jump (5s, 10s, 15s, 20s...)

    public func triggerShortStep(
        direction: ScrubDirection,
        stepSeconds: Double,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewFrameLoader,
        onCommit: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        barHideTask?.cancel()
        shortCommitTask?.cancel()
        tickTask?.cancel()
        tickTask = nil

        let isContinuingShortStep: Bool
        if case .shortStep = activeMode, isScrubbing {
            isContinuingShortStep = true
        } else {
            isContinuingShortStep = false
        }

        if !isContinuingShortStep {
            beginSession(anchor: currentPlaybackTime, duration: duration)
        } else {
            currentDuration = duration
        }

        activeMode = .shortStep(direction: direction)
        isShowingBar = true

        let step = max(5.0, stepSeconds) * Double(direction.rawValue)
        targetTime = clampTime(targetTime + step, duration: duration)
        deltaSeconds = targetTime - anchorTime
        pendingPreviewTarget = targetTime
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)

        // Coalesce rapid multi-clicks within 220ms; commits smoothly right after taps stop!
        shortCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .shortStep = self.activeMode {
                self.commit(keepBarBriefly: true, onCommit: onCommit)
            }
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
        barHideTask?.cancel()
        shortCommitTask?.cancel()

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

        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
            targetTime = clampTime(targetTime + Double(direction.rawValue), duration: duration)
            deltaSeconds = targetTime - anchorTime
            pendingPreviewTarget = targetTime
        } else {
            currentDuration = duration
        }

        activeMode = .shuttle(gear: nextGear)
        isShowingBar = true
        startShuttleTickLoop(gear: nextGear)
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
        return .active(gear: nextGear)
    }

    // MARK: - Mode 2: Hold-to-Scrub (MX Player Nonlinear Speed Ramp)

    public func beginHold(
        direction: ScrubDirection,
        speedProfile: LongPressSpeedProfile,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping PreviewFrameLoader
    ) {
        barHideTask?.cancel()
        shortCommitTask?.cancel()

        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
        } else {
            currentDuration = duration
        }

        let start = Date()
        pressStartTime = start
        let initialSpeed = holdSpeedMultiplier(elapsedHold: 0, profile: speedProfile)
        activeMode = .hold(direction: direction, speedMultiplier: max(1, Int(initialSpeed.rounded())))
        isShowingBar = true

        // Immediately advance the first micro-step so frame 1 starts decoding right away.
        let baseDt = Double(tickIntervalNs) / 1_000_000_000.0
        targetTime = clampTime(targetTime + initialSpeed * baseDt * Double(direction.rawValue), duration: duration)
        deltaSeconds = targetTime - anchorTime
        pendingPreviewTarget = targetTime

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            var lastTick = start
            try? await Task.sleep(nanoseconds: self.tickIntervalNs)
            while !Task.isCancelled && self.isScrubbing {
                let now = Date()
                let dt = min(0.08, max(0.01, now.timeIntervalSince(lastTick)))
                lastTick = now
                let elapsed = now.timeIntervalSince(self.pressStartTime ?? now)
                let speed = self.holdSpeedMultiplier(elapsedHold: elapsed, profile: speedProfile)
                self.activeMode = .hold(direction: direction, speedMultiplier: max(1, Int(speed.rounded())))
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
        barHideTask?.cancel()
        shortCommitTask?.cancel()
        tickTask?.cancel()
        tickTask = nil

        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
        } else {
            currentDuration = duration
        }
        activeMode = .touchpad
        isShowingBar = true
        pendingPreviewTarget = targetTime
        startDecodeLoopIfNeeded(onPreviewFrame: onPreviewFrame)
    }

    public func updateTouchpadPan(deltaPoints: CGFloat, velocityPointsPerSec: CGFloat) {
        guard isScrubbing, activeMode == .touchpad else { return }

        let absVel = abs(Double(velocityPointsPerSec))
        let secPerPoint: Double
        switch absVel {
        case ..<280: secPerPoint = 0.14
        case ..<800: secPerPoint = 0.48
        default:     secPerPoint = 1.25
        }

        let durationScale: Double = (currentDuration > 0 && currentDuration < 300)
            ? max(0.25, currentDuration / 300.0)
            : 1.0

        let deltaSec = Double(deltaPoints) * secPerPoint * durationScale
        targetTime = clampTime(targetTime + deltaSec, duration: currentDuration)
        deltaSeconds = targetTime - anchorTime
        pendingPreviewTarget = targetTime
    }

    // MARK: - Commit & Cancel (Zero-Flicker Handoff)

    public func commit(
        keepBarBriefly: Bool = false,
        onCommit: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        let finalTarget: TimeInterval
        if case .shortStep = activeMode {
            // Fixed-step jumps honor exact requested +5s/+10s target
            finalTarget = targetTime
        } else {
            // Continuous visual scrubbing lands on the exact visible keyframe -> instant resume & zero jump!
            finalTarget = framePresenter.isVisible ? displayedFrameTime : targetTime
        }

        stopLoopsOnly()
        isScrubbing = false
        if !keepBarBriefly {
            isShowingBar = false
            activeMode = .idle
        }
        isCommitting = true
        commitEpoch &+= 1
        let epoch = commitEpoch

        Task { @MainActor [weak self] in
            await onCommit(finalTarget)
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard let self, self.commitEpoch == epoch, !self.isScrubbing else { return }
            self.framePresenter.clear()
            self.isCommitting = false

            if keepBarBriefly {
                self.barHideTask?.cancel()
                self.barHideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard let self, !Task.isCancelled, !self.isScrubbing else { return }
                    self.isShowingBar = false
                    self.activeMode = .idle
                }
            }
        }
    }

    public func cancelAll() {
        stopLoopsOnly()
        barHideTask?.cancel()
        barHideTask = nil
        commitEpoch &+= 1
        isScrubbing = false
        isShowingBar = false
        activeMode = .idle
        isCommitting = false
        framePresenter.clear()
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
                    if abs(nextTarget - self.lastDecodedRequestTarget) < 0.05 && self.framePresenter.isVisible {
                        try? await Task.sleep(nanoseconds: 4_000_000)
                        continue
                    }
                    self.lastDecodedRequestTarget = nextTarget
                    let outcome = await onPreviewFrame(nextTarget)
                    guard !Task.isCancelled && self.isScrubbing else { break }
                    switch outcome {
                    case .frame(let frame):
                        // Direct CALayer.contents swap (<0.1ms, ZERO SwiftUI layout/diffing!)
                        self.framePresenter.present(frame.cgImage)
                        self.displayedFrameTime = frame.actualTime
                    case .unchanged(let actualTime):
                        self.displayedFrameTime = actualTime
                    case .unavailable:
                        self.displayedFrameTime = nextTarget
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
            }
        }
    }

    private func stopLoopsOnly() {
        tickTask?.cancel()
        tickTask = nil
        decodeLoopTask?.cancel()
        decodeLoopTask = nil
        shortCommitTask?.cancel()
        shortCommitTask = nil
        pendingPreviewTarget = nil
    }

    private func clampTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }
}
