import Foundation
import OSLog

/// Accumulates terminal output data into a buffer and flushes adaptively.
///
/// Three flush modes adapt to the current workload:
/// - Low throughput: flush every 16ms, roughly 60 fps.
/// - High throughput: flush at larger batches or every 100ms.
/// - Burst output: flush immediately at 64KB.
@MainActor
class PTYBufferManager {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pty-buffer")
    private var buffer = Data()
    private var flushTimer: DispatchSourceTimer?
    private let onFlush: (Data) -> Void
    private var workloadHints = WorkloadHints()

    private var currentThreshold = 16 * 1024
    private var currentInterval: DispatchTimeInterval = .milliseconds(50)

    var currentBufferSize: Int { buffer.count }

    init(onFlush: @escaping (Data) -> Void) {
        self.onFlush = onFlush
    }

    func append(_ data: Data) {
        let start = CFAbsoluteTimeGetCurrent()
        buffer.append(data)
        workloadHints.record(bytes: data.count)

        if buffer.count >= 64 * 1024 {
            flush(withLatency: CFAbsoluteTimeGetCurrent() - start)
            return
        }

        tuneThresholds()

        if buffer.count >= currentThreshold {
            flush(withLatency: CFAbsoluteTimeGetCurrent() - start)
            return
        }

        if flushTimer == nil {
            startTimer()
        }
    }

    func flush() {
        flush(withLatency: 0)
    }

    func reset() {
        cancel()
        buffer.removeAll()
        workloadHints.reset()
    }

    func cancel() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func tuneThresholds() {
        let recentBps = workloadHints.bytesPerSecond

        switch recentBps {
        case ..<10_000:
            currentThreshold = 4 * 1024
            currentInterval = .milliseconds(16)
        case 10_000..<500_000:
            currentThreshold = 16 * 1024
            currentInterval = .milliseconds(50)
        default:
            currentThreshold = 32 * 1024
            currentInterval = .milliseconds(100)

            if recentBps > 2_000_000 {
                cancelTimer()
                return
            }
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + currentInterval, repeating: currentInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
        timer.resume()
        flushTimer = timer
    }

    private func cancelTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func flush(withLatency additionalLatency: Double) {
        cancelTimer()
        guard !buffer.isEmpty else { return }

        let start = CFAbsoluteTimeGetCurrent()
        let chunk = buffer
        buffer = Data()

        let latencyMs = (CFAbsoluteTimeGetCurrent() - start + additionalLatency) * 1000
        onFlush(chunk)

        PTYProfiler.shared.recordFlush(batchSize: chunk.count, latencyMs: latencyMs)
    }
}

private struct WorkloadHints {
    private var samples: [(time: CFAbsoluteTime, bytes: Int)] = []
    private let window: CFAbsoluteTime = 1.0

    mutating func record(bytes: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        samples.append((now, bytes))
        prune(now: now)
    }

    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let totalBytes = samples.reduce(0) { $0 + $1.bytes }
        let span = last.time - first.time
        return span > 0 ? Double(totalBytes) / span : 0
    }

    private mutating func prune(now: CFAbsoluteTime) {
        samples.removeAll { now - $0.time > window }
    }

    mutating func reset() {
        samples.removeAll()
    }
}
