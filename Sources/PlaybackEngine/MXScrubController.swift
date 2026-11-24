import Foundation
import Combine

/// 仿安卓 MX Player 的三段非线性加速长按跳转控制器（单飞最新覆盖 Single-Flight Coalescing）。
/// 计时器每 100ms 更新目标时间，后台单飞循环始终只解码「最新」关键帧，绝不堆积卡死解码线程。
@MainActor
public final class MXScrubController: ObservableObject {
    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var deltaSeconds: TimeInterval = 0

    private var pressStartTime: Date?
    private var tickTask: Task<Void, Never>?
    private var decodeLoopTask: Task<Void, Never>?
    private var pendingPreviewTarget: TimeInterval?
    private let tickIntervalNs: UInt64 = 100_000_000 // 10 Hz 目标时间推进

    public init() {}

    /// 仿安卓 MX Player 三段非线性加速曲线
    private func secondsPerTick(elapsedHold: TimeInterval) -> TimeInterval {
        switch elapsedHold {
        case ..<1.5: return 1.5    // 约 15s/秒（精细找镜头）
        case ..<4.0: return 4.5    // 约 45s/秒（中速巡航）
        default:     return 12.0   // 约 120s/秒（高速冲刺）
        }
    }

    public func beginHold(
        direction: ScrubDirection,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        cancelHold()
        isScrubbing = true
        targetTime = currentPlaybackTime
        deltaSeconds = 0
        pressStartTime = Date()

        // 1. 10Hz 目标时间推进协程
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isScrubbing {
                let holdElapsed = Date().timeIntervalSince(self.pressStartTime ?? Date())
                let step = self.secondsPerTick(elapsedHold: holdElapsed) * Double(direction.rawValue)
                self.targetTime = min(max(0, self.targetTime + step), max(0, duration))
                self.deltaSeconds = self.targetTime - currentPlaybackTime
                self.pendingPreviewTarget = self.targetTime
                try? await Task.sleep(nanoseconds: self.tickIntervalNs)
            }
        }

        // 2. 单飞最新覆盖解码循环（同一时刻只解 1 帧，出画即立刻抓取最新目标，零积压）
        decodeLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isScrubbing {
                if let nextTarget = self.pendingPreviewTarget {
                    self.pendingPreviewTarget = nil
                    await onPreviewFrame(nextTarget)
                } else {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms idle poll
                }
            }
        }
    }

    public func endHold(onCommit: @escaping (TimeInterval) async -> Void) {
        let finalTarget = targetTime
        cancelHold()
        Task {
            await onCommit(finalTarget)
        }
    }

    public func cancelHold() {
        tickTask?.cancel()
        tickTask = nil
        decodeLoopTask?.cancel()
        decodeLoopTask = nil
        pendingPreviewTarget = nil
        isScrubbing = false
    }
}
