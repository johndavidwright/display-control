import Foundation

enum DDCWriteResult {
  case confirmed(DDCValue)
  case failed(actual: DDCValue?)
  case superseded
}

/// One scheduler and worker survive service replacement/reconnection.
/// A timed-out syscall keeps the worker occupied until it actually returns.
final class DDCSession {
  private let scheduler = DispatchQueue(label: "ddc.scheduler", qos: .userInitiated)
  private let worker = DispatchQueue(label: "ddc.worker", qos: .userInitiated)
  private let lock = NSLock()
  private var transport: DDCTransport?
  private var activeOperation: UUID?
  private var generation = UUID()
  // Accessed only on the scheduler; pins multi-step operations to a connection.
  private var orchestrationGeneration: UUID?
  private var latest: [UInt8: PendingWrite] = [:]
  private var drainScheduled = false
  private let ioTimeout: TimeInterval
  private let writeThrottle: TimeInterval
  private let settleDelay: UInt32

  private struct PendingWrite {
    let generation: UUID
    let value: UInt16
    let completion: (DDCWriteResult) -> Void
  }

  init(transport: DDCTransport?, ioTimeout: TimeInterval = 2,
       writeThrottle: TimeInterval = 0.08, settleDelay: UInt32 = 50_000) {
    self.transport = transport
    self.ioTimeout = ioTimeout
    self.writeThrottle = writeThrottle
    self.settleDelay = settleDelay
  }

  func replaceTransport(_ transport: DDCTransport?) {
    lock.lock(); self.transport = transport; lock.unlock()
  }

  func cancelPendingWrites() {
    lock.lock()
    generation = UUID()
    let cancelled = latest
    latest.removeAll()
    lock.unlock()
    for pending in cancelled.values { pending.completion(.superseded) }
  }

  func write(_ code: UInt8, _ value: UInt16, completion: @escaping (DDCWriteResult) -> Void) {
    lock.lock()
    let replaced = latest.updateValue(PendingWrite(generation: generation, value: value, completion: completion), forKey: code)
    let schedule = !drainScheduled
    drainScheduled = true
    lock.unlock()
    replaced?.completion(.superseded)
    if schedule {
      scheduler.asyncAfter(deadline: .now() + writeThrottle) { [weak self] in self?.drain() }
    }
  }

  func read(_ code: UInt8) -> DDCValue? {
    runOnWorker(expectedGeneration: orchestrationGeneration) { $0.read(code) } ?? nil
  }

  @discardableResult
  func writeOnce(_ code: UInt8, _ value: UInt16, generation: UUID? = nil) -> Bool {
    runOnWorker(expectedGeneration: generation ?? orchestrationGeneration) { $0.write(code, value) } ?? false
  }

  func perform(_ block: @escaping (DDCSession) -> Void) {
    lock.lock(); let token = generation; lock.unlock()
    scheduler.async {
      self.orchestrationGeneration = token
      defer { self.orchestrationGeneration = nil }
      block(self)
    }
  }

  private func isSuperseded(_ code: UInt8, generation expected: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return generation != expected || latest[code] != nil
  }

  private func drain() {
    lock.lock()
    let batch = latest
    latest.removeAll()
    drainScheduled = false
    lock.unlock()

    // Select and verify the color slot before adjusting its gains.
    let codes = batch.keys.sorted { ($0 == 0x14 ? -1 : Int($0)) < ($1 == 0x14 ? -1 : Int($1)) }
    for code in codes {
      guard let pending = batch[code] else { continue }
      pending.completion(verifyWrite(code, pending.value, generation: pending.generation))
    }
  }

  private func verifyWrite(_ code: UInt8, _ value: UInt16, generation: UUID) -> DDCWriteResult {
    var actual: DDCValue?
    for _ in 0..<3 {
      if isSuperseded(code, generation: generation) { return .superseded }
      let sent = writeOnce(code, value, generation: generation)
      if settleDelay > 0 { usleep(settleDelay) }
      actual = read(code)
      if isSuperseded(code, generation: generation) { return .superseded }
      if let actual, actual.current == value { return .confirmed(actual) }
      if !sent || actual == nil { break }
    }
    return .failed(actual: actual)
  }

  private func runOnWorker<T>(expectedGeneration: UUID? = nil, _ op: @escaping (DDCTransport) -> T) -> T? {
    lock.lock()
    guard activeOperation == nil, expectedGeneration == nil || expectedGeneration == generation, let transport else { lock.unlock(); return nil }
    let token = UUID()
    activeOperation = token
    lock.unlock()

    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    worker.async {
      let value = op(transport)
      self.lock.lock()
      box.value = value
      if self.activeOperation == token { self.activeOperation = nil }
      self.lock.unlock()
      done.signal()
    }
    // Timeout never mutates worker state: completion alone releases the slot.
    guard done.wait(timeout: .now() + ioTimeout) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return box.value
  }
}

private final class ResultBox<T> { var value: T? }
