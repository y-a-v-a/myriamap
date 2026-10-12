import Foundation

/// Result slots written from concurrent iterations, each slot exactly once.
private final class ResultSlots<T>: @unchecked Sendable {
    var results: [T?]
    init(_ n: Int) { results = Array(repeating: nil, count: n) }
}

/// Maps `0..<count` concurrently, preserving order.
func parallelMap<T: Sendable>(_ count: Int, _ transform: @Sendable (Int) -> T) -> [T] {
    guard count > 0 else { return [] }
    let slots = ResultSlots<T>(count)
    let chunk = max(1, count / (ProcessInfo.processInfo.activeProcessorCount * 8))
    let chunks = (count + chunk - 1) / chunk
    slots.results.withUnsafeMutableBufferPointer { buffer in
        nonisolated(unsafe) let out = buffer
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let start = c * chunk, end = min(count, start + chunk)
            for i in start..<end { out[i] = transform(i) }
        }
    }
    return slots.results.map { $0! }
}
