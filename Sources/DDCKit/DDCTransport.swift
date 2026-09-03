import Foundation
import CDDCPrivate

struct DDCValue: Equatable {
  let current: UInt16
  let max: UInt16
}

/// Synchronous operations, called only on a session's worker.
protocol DDCTransport {
  func read(_ code: UInt8) -> DDCValue?
  func write(_ code: UInt8, _ value: UInt16) -> Bool
}

protocol DDCI2C {
  func write(_ packet: [UInt8]) -> Bool
  func read(count: Int) -> [UInt8]?
}

struct IOAVI2C: DDCI2C {
  let service: IOAVService

  func write(_ packet: [UInt8]) -> Bool {
    var bytes = packet
    return IOAVServiceWriteI2C(service, 0x37, 0x51, &bytes, UInt32(bytes.count)) == 0
  }

  func read(count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    guard IOAVServiceReadI2C(service, 0x37, 0, &bytes, UInt32(count)) == 0 else { return nil }
    return bytes
  }
}

/// Apple Silicon framing/timing adapted from MonitorControl (see THIRD_PARTY).
/// A read succeeds only after validating the entire Get VCP reply.
final class PacketDDCTransport: DDCTransport {
  private let io: DDCI2C
  private let sleep: (UInt32) -> Void

  init(io: DDCI2C, sleep: @escaping (UInt32) -> Void = { usleep($0) }) {
    self.io = io
    self.sleep = sleep
  }

  func read(_ code: UInt8) -> DDCValue? {
    let packet = Self.packet([code])
    for _ in 0..<5 {
      guard send(packet) else { sleep(20_000); continue }
      sleep(50_000)
      guard let reply = io.read(count: 11), Self.validReply(reply, code: code) else {
        sleep(20_000)
        continue
      }
      // Unsupported is a valid response, but never a usable feature value.
      guard reply[3] == 0 else { return nil }
      return DDCValue(current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                      max: UInt16(reply[6]) << 8 | UInt16(reply[7]))
    }
    return nil
  }

  func write(_ code: UInt8, _ value: UInt16) -> Bool {
    let packet = Self.packet([code, UInt8(value >> 8), UInt8(value & 255)])
    for _ in 0..<5 {
      if send(packet) { return true }
      sleep(20_000)
    }
    return false
  }

  private func send(_ packet: [UInt8]) -> Bool {
    var success = false
    for _ in 0..<2 {
      sleep(10_000)
      success = io.write(packet)
    }
    return success
  }

  private static func packet(_ payload: [UInt8]) -> [UInt8] {
    var bytes = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
    // Preserve the IOAVService read-request checksum convention used upstream.
    let seed: UInt8 = payload.count == 1 ? 0x6E : 0x6E ^ 0x51
    bytes.append(bytes.reduce(seed, ^))
    return bytes
  }

  private static func validReply(_ bytes: [UInt8], code: UInt8) -> Bool {
    bytes.count == 11 && bytes[0] == 0x6E && bytes[1] == 0x88 &&
      bytes[2] == 0x02 && bytes[3] <= 1 && bytes[4] == code && bytes[5] <= 1 &&
      bytes.dropLast().reduce(UInt8(0x50), ^) == bytes.last!
  }
}
