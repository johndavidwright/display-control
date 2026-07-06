import Foundation
import CDDCPrivate

/// Per-display serial DDC channel with a watchdog.
///
/// Design goals, learned the hard way:
///  • **No overlapping I2C.** Every read/write for a display runs on a single
///    serial `worker` queue, so transactions to a monitor never overlap —
///    concurrent access can wedge a monitor's DDC controller (and, cascading,
///    the whole Apple-Silicon DCP) until a reboot.
///  • **Never block indefinitely.** Each I2C op is run with a caller-side
///    timeout. `IOAVServiceReadI2C`/`WriteI2C` can hang uninterruptibly when a
///    monitor is wedged; the timeout stops that from freezing a display's queue.
///  • **Don't pile onto a stuck display.** After a timeout the session is marked
///    `stalled` and refuses to start new I2C until the stuck op drains, so we
///    never launch a second overlapping transaction or back up unbounded work.
///  • **Confirm writes on flaky panels.** Settled slider values are read back and
///    re-driven a couple of times if the monitor ignored them, then we stop.
final class DDCSession {
  let service: IOAVService?
  private let ioTimeout: TimeInterval

  private let scheduler = DispatchQueue(label: "ddc.scheduler", qos: .userInitiated)
  private let worker = DispatchQueue(label: "ddc.worker", qos: .userInitiated)

  private let lock = NSLock()
  private var latest: [UInt8: UInt16] = [:]
  private var drainScheduled = false

  private let stateLock = NSLock()
  private var _stalled = false

  /// Minimum spacing between write batches while dragging a slider. The UI
  /// updates optimistically and instantly regardless (see Display.set), so this
  /// only paces the hardware writes — it doesn't add perceptible input lag, and
  /// it keeps flaky monitors (which can drop writes fired faster than they can
  /// absorb them) from being flooded mid-drag.
  private let writeThrottle: TimeInterval

  init(service: IOAVService?, ioTimeout: TimeInterval = 2.0, writeThrottle: TimeInterval = 0.08) {
    self.service = service
    self.ioTimeout = ioTimeout
    self.writeThrottle = writeThrottle
  }

  /// False after an I/O timed out and the stuck worker op hasn't drained yet.
  var isResponsive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return !_stalled }
  private var stalled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _stalled }
  private func setStalled(_ v: Bool) { stateLock.lock(); _stalled = v; stateLock.unlock() }

  // MARK: - Public API

  /// Coalesced, throttled, watchdog-protected write for sliders. Fire-and-forget;
  /// multiple rapid updates within the throttle window collapse to the latest
  /// value per VCP code, and are dispatched together after `writeThrottle`.
  func write(_ code: UInt8, _ value: UInt16) {
    lock.lock()
    latest[code] = value
    let schedule = !drainScheduled
    if schedule { drainScheduled = true }
    lock.unlock()
    if schedule {
      scheduler.asyncAfter(deadline: .now() + writeThrottle) { [weak self] in self?.drain() }
    }
  }

  /// Serialized, watchdog-protected read. Call from inside `perform` (never the
  /// main thread). Returns nil on read failure or timeout.
  func read(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
    runOnWorker { Arm64DDC.read(service: self.service, command: code) } ?? nil
  }

  /// One serialized write, no verification (for action opcodes like 0x08).
  func writeOnce(_ code: UInt8, _ value: UInt16) {
    _ = runOnWorker { Arm64DDC.write(service: self.service, command: code, value: value); return true }
  }

  /// Run an orchestration block (e.g. probe, color reset) on the scheduler queue,
  /// serialized with slider writes. Use the passed session's read/write inside.
  func perform(_ block: @escaping (DDCSession) -> Void) {
    scheduler.async { [weak self] in
      guard let self else { return }
      block(self)
    }
  }

  // MARK: - Internals

  private func drain() {
    lock.lock()
    let batch = latest
    latest.removeAll()
    drainScheduled = false
    lock.unlock()

    for (code, value) in batch {
      _ = runOnWorker { Arm64DDC.write(service: self.service, command: code, value: value); return true }
    }

    // Verify only settled values (nothing newer queued) so drags stay smooth.
    lock.lock(); let settled = latest.isEmpty; lock.unlock()
    if settled {
      for (code, value) in batch { verifySettled(code, value) }
    }
  }

  /// Read back a settled value; if the monitor ignored the write, re-drive it a
  /// couple of times, then give up. Bails out if a newer drag value supersedes.
  private func verifySettled(_ code: UInt8, _ value: UInt16, retries: Int = 2) {
    for _ in 0 ..< retries {
      lock.lock(); let superseded = latest[code] != nil; lock.unlock()
      if superseded { return }
      guard let r = runOnWorker({ Arm64DDC.read(service: self.service, command: code) }) ?? nil else {
        return // read unsupported or timed out — stop, don't thrash
      }
      if r.current == value { return }
      _ = runOnWorker { Arm64DDC.write(service: self.service, command: code, value: value); return true }
      usleep(40_000)
    }
  }

  /// Run an I2C op on the serial worker with a caller-side timeout. If a previous
  /// op is stuck (stalled), skip entirely rather than enqueue a second op — this
  /// is what guarantees transactions never overlap under a hung syscall.
  private func runOnWorker<T>(_ op: @escaping () -> T) -> T? {
    if stalled { return nil }
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    worker.async { [weak self] in
      box.value = op()
      sem.signal()
      self?.setStalled(false)
    }
    if sem.wait(timeout: .now() + ioTimeout) == .timedOut {
      setStalled(true)
      return nil
    }
    return box.value
  }
}

private final class Box<T> { var value: T? }
