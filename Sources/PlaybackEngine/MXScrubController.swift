import Foundation
import CoreGraphics
import QuartzCore
import Combine
import AppPreferences

public enum ScrubVisualMode: Equatable, Sendable {
    case idle
    /// Rapid fixed-step jump (±5s, ±10s, ±15s ... coalesced seamlessly on multi-taps).
    case shortStep(direction: ScrubDirection)
    /// Multi-stage gear shuttle: -6..-1 (rewind -64x..-2x), +1..+6 (forward +2x..+64x).
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

/// 仿安卓 MX Player 丝滑实时出画、闭环测速同步的快进/快退控制器：
/// - 视频帧通过 GPU `AVSampleBufferDisplayLayer` 零拷贝上屏（无 SwiftUI 重绘，24~60fps 丝滑渲染）
/// - 闭环时钟限幅 + 实时视频帧测速：UI 倍速与进度条始终与画面真实运动同步（显示几倍速，画面即几倍速）
@MainActor
public final class MXScrubController: ObservableObject {
    public typealias PreviewFrameLoader = @Sendable (TimeInterval, Double) async -> ScrubDecodeOutcome

    public static let shuttleSpeedTable: [Int] = [0, 2, 4, 8, 16, 32, 64, 128]

    /// Direct GPU CoreAnimation presenter — updates video frames WITHOUT triggering SwiftUI view diffs!
    public let framePresenter = ScrubFramePresenter()

    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var isShowingBar: Bool = false
    @Published public private(set) var activeMode: ScrubVisualMode = .idle
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var displayedFrameTime: TimeInterval = 0
    @Published public private(set) var deltaSeconds: TimeInterval = 0
    @Published public private(set) var actualVisualSpeed: Double = 0
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
    private var currentRequestedSpeed: Double = 0
    private var currentDirectionSign: Double = 1.0
    private var hasRenderedFrameInSession: Bool = false
    private var speedSamples: [(wall: CFTimeInterval, media: TimeInterval)] = []
    private var lastFrameWallTime: CFTimeInterval = 0
    private var commitEpoch: UInt64 = 0
    private let tickIntervalNs: UInt64 = 16_666_667 // ~60 Hz silky synchronized clock

    public init() {}

    public var isShuttleActive: Bool {
        if case .shuttle = activeMode { return true }
        return false
    }

    public var synchronizedDisplayTime: TimeInterval {
        if case .shortStep = activeMode {
            return targetTime
        }
        return framePresenter.isVisible ? displayedFrameTime : targetTime
    }

    public var synchronizedDeltaSeconds: TimeInterval {
        synchronizedDisplayTime - anchorTime
    }

    public var speedLabel: String {
        switch activeMode {
        case .idle:
            return ""
        case .shortStep(let dir):
            return dir == .forward ? ">>>" : "<<<"
        case .shuttle(let gear):
            let absG = min(max(abs(gear), 1), Self.shuttleSpeedTable.count - 1)
            let requested = Double(Self.shuttleSpeedTable[absG])
            let synced = synchronizedDisplaySpeed(requested: requested)
            return gear >= 0 ? ">>> \(synced)x" : "<<< -\(synced)x"
        case .hold(let dir, let mult):
            let synced = synchronizedDisplaySpeed(requested: Double(max(1, mult)))
            return dir == .forward ? ">>> \(synced)x" : "<<< -\(synced)x"
        case .touchpad:
            return synchronizedDeltaSeconds >= 0 ? ">>>" : "<<<"
        }
    }

    private func synchronizedDisplaySpeed(requested: Double) -> Int {
        let req = max(1.0, requested)
        if actualVisualSpeed < 0.5 {
            return max(1, Int(req.rounded()))
        }
        if abs(actualVisualSpeed - req) / req <= 0.18 {
            return max(1, Int(req.rounded()))
        }
        return max(1, Int(actualVisualSpeed.rounded()))
    }

    /// 连续指数平滑加速曲线（平滑起步、无档位顿挫）
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
        currentRequestedSpeed = 8.0
        currentDirectionSign = Double(direction.rawValue)

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

    // MARK: - Mode 1: Multi-Stage Live Visual Shuttle (2x -> 4x -> 8x -> 16x -> 32x -> 64x)

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

        let maxGear = Self.shuttleSpeedTable.count - 1
        let nextGear = max(-maxGear, min(maxGear, currentGear + direction.rawValue))
        if nextGear == 0 {
            return .exitedToNormalPlayback(commitTime: synchronizedDisplayTime)
        }

        if !isScrubbing {
            beginSession(anchor: currentPlaybackTime, duration: duration)
            let initStep = 0.25 * Double(direction.rawValue)
            targetTime = clampTime(targetTime + initStep, duration: duration)
            deltaSeconds = targetTime - anchorTime
            pendingPreviewTarget = targetTime
        } else {
            currentDuration = duration
        }

        let absG = min(max(abs(nextGear), 1), maxGear)
        currentRequestedSpeed = Double(Self.shuttleSpeedTable[absG])
        currentDirectionSign = nextGear >= 0 ? 1.0 : -1.0

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
        currentRequestedSpeed = initialSpeed
        currentDirectionSign = Double(direction.rawValue)
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
            var lastTick = CACurrentMediaTime()
            try? await Task.sleep(nanoseconds: self.tickIntervalNs)
            while !Task.isCancelled && self.isScrubbing {
                let nowWall = CACurrentMediaTime()
                let dt = min(0.05, max(0.004, nowWall - lastTick))
                lastTick = nowWall
                let elapsed = Date().timeIntervalSince(self.pressStartTime ?? start)
                let speed = self.holdSpeedMultiplier(elapsedHold: elapsed, profile: speedProfile)
                self.activeMode = .hold(direction: direction, speedMultiplier: max(1, Int(speed.rounded())))
                self.advanceClock(speed: speed, dt: dt, dirSign: Double(direction.rawValue))
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
        currentRequestedSpeed = 8.0
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
        if deltaSec != 0 {
            currentDirectionSign = deltaSec >= 0 ? 1.0 : -1.0
        }
        targetTime = clampTime(targetTime + deltaSec, duration: currentDuration)
        deltaSeconds = targetTime - anchorTime
        pendingPreviewTarget = targetTime
    }

    // MARK: - Commit & Cancel (Zero-Flicker Handoff)

    public func commit(
        keepBarBriefly: Bool = false,
        onCommit: @escaping @MainActor (TimeInterval) async -> Void
    ) {
        let finalTarget = synchronizedDisplayTime

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
        actualVisualSpeed = 0
        currentRequestedSpeed = 0
        hasRenderedFrameInSession = false
        speedSamples.removeAll(keepingCapacity: true)
        framePresenter.clear()
    }

    // MARK: - Internal Synchronized Clock & Decode Loop

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
        actualVisualSpeed = 0
        currentRequestedSpeed = 0
        hasRenderedFrameInSession = false
        speedSamples.removeAll(keepingCapacity: true)
        lastFrameWallTime = CACurrentMediaTime()
    }

    private func startShuttleTickLoop(gear: Int) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            let absGear = min(max(abs(gear), 1), Self.shuttleSpeedTable.count - 1)
            let speed = Double(Self.shuttleSpeedTable[absGear])
            let dirSign = gear >= 0 ? 1.0 : -1.0
            var lastTick = CACurrentMediaTime()

            while !Task.isCancelled && self.isScrubbing {
                try? await Task.sleep(nanoseconds: self.tickIntervalNs)
                guard !Task.isCancelled && self.isScrubbing else { break }
                let nowWall = CACurrentMediaTime()
                let dt = min(0.05, max(0.004, nowWall - lastTick))
                lastTick = nowWall
                self.advanceClock(speed: speed, dt: dt, dirSign: dirSign)
            }
        }
    }

    private func advanceClock(speed: Double, dt: Double, dirSign: Double) {
        currentRequestedSpeed = speed
        currentDirectionSign = dirSign

        var desired = clampTime(targetTime + speed * dt * dirSign, duration: currentDuration)

        // Closed-loop lead clamping: prevent virtual clock/bar from running away from decoded frames.
        if hasRenderedFrameInSession {
            let maxLead = max(0.8, speed * 0.45)
            if dirSign > 0 {
                if desired > displayedFrameTime + maxLead {
                    desired = max(targetTime, displayedFrameTime + maxLead)
                }
            } else {
                if desired < displayedFrameTime - maxLead {
                    desired = min(targetTime, displayedFrameTime - maxLead)
                }
            }
            if CACurrentMediaTime() - lastFrameWallTime > 0.65 && actualVisualSpeed > 0.5 {
                actualVisualSpeed *= 0.88
            }
        }

        targetTime = desired
        deltaSeconds = targetTime - anchorTime

        let aheadByDir = (targetTime - displayedFrameTime) * dirSign
        if !hasRenderedFrameInSession || aheadByDir >= -0.02 || pendingPreviewTarget == nil {
            pendingPreviewTarget = targetTime
        }
    }

    private func recordRenderedFrame(actualTime: TimeInterval) {
        let now = CACurrentMediaTime()
        lastFrameWallTime = now
        speedSamples.append((wall: now, media: actualTime))
        let windowStart = now - 0.65
        while speedSamples.count > 2, let first = speedSamples.first, first.wall < windowStart {
            speedSamples.removeFirst()
        }
        guard let oldest = speedSamples.first, speedSamples.count >= 2 else { return }
        let dtWall = now - oldest.wall
        guard dtWall >= 0.08 else { return }
        let instantSpeed = abs(actualTime - oldest.media) / dtWall
        guard instantSpeed.isFinite else { return }
        let bounded = min(max(0, instantSpeed), max(4.0, currentRequestedSpeed * 2.2))
        if actualVisualSpeed < 0.5 {
            actualVisualSpeed = bounded
        } else {
            actualVisualSpeed = actualVisualSpeed * 0.65 + bounded * 0.35
        }
    }

    private func startDecodeLoopIfNeeded(onPreviewFrame: @escaping PreviewFrameLoader) {
        if decodeLoopTask != nil { return }
        decodeLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isScrubbing {
                if let nextTarget = self.pendingPreviewTarget {
                    if self.hasRenderedFrameInSession,
                       self.activeMode != .touchpad {
                        let isShort: Bool
                        if case .shortStep = self.activeMode { isShort = true } else { isShort = false }
                        if !isShort {
                            let overshoot = (self.displayedFrameTime - nextTarget) * self.currentDirectionSign
                            let maxHoldMedia = max(0.35, self.currentRequestedSpeed * 0.25)
                            if overshoot > maxHoldMedia {
                                self.targetTime = self.clampTime(self.displayedFrameTime, duration: self.currentDuration)
                                self.deltaSeconds = self.targetTime - self.anchorTime
                            } else if overshoot > 0.08 {
                                // Smoothly pace until clock catches up to ahead keyframe at requested speed
                                try? await Task.sleep(nanoseconds: 16_000_000)
                                continue
                            }
                        }
                    }

                    let requestTarget = self.pendingPreviewTarget ?? nextTarget
                    self.pendingPreviewTarget = nil
                    if abs(requestTarget - self.lastDecodedRequestTarget) < 0.04 && self.framePresenter.isVisible {
                        try? await Task.sleep(nanoseconds: 4_000_000)
                        continue
                    }
                    self.lastDecodedRequestTarget = requestTarget
                    let reqSpeed = max(1.0, self.currentRequestedSpeed)
                    let outcome = await onPreviewFrame(requestTarget, reqSpeed)
                    guard !Task.isCancelled && self.isScrubbing else { break }
                    switch outcome {
                    case .frame(let frame):
                        self.framePresenter.present(frame)
                        self.displayedFrameTime = frame.actualTime
                        self.hasRenderedFrameInSession = true
                        self.recordRenderedFrame(actualTime: frame.actualTime)
                    case .unchanged(let actualTime):
                        self.displayedFrameTime = actualTime
                    case .unavailable:
                        self.displayedFrameTime = requestTarget
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
