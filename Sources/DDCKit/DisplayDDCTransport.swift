import Foundation

/// Device-specific value conventions, isolated from packet validation and the
/// generic display model. Never apply these conversions to other monitors.
struct DisplayDDCTransport: DDCTransport {
  private let base: DDCTransport
  private let percentageRGB: Bool

  init(base: DDCTransport, identityKey: String) {
    self.base = base
    // XENEON EDGE, EDID vendor/product 0E58/ED00: Set VCP RGB accepts
    // percentages, but Get VCP returns 0...255. Hardware readbacks for the
    // existing 99/83/74 calibration are 252/211/188 respectively. Preserve the
    // stored/write units and normalize only RGB readbacks reporting max=255.
    self.percentageRGB = identityKey.uppercased().hasPrefix("0E5800ED-")
  }

  func read(_ code: UInt8) -> DDCValue? {
    guard let value = base.read(code) else { return nil }
    guard percentageRGB, [UInt8(0x16), 0x18, 0x1A].contains(code), value.max == 255 else { return value }
    guard value.current <= value.max else { return nil }
    let percentage = UInt16((Double(value.current) * 100 / Double(value.max)).rounded())
    return DDCValue(current: percentage, max: 100)
  }

  func write(_ code: UInt8, _ value: UInt16) -> Bool {
    base.write(code, value)
  }
}
