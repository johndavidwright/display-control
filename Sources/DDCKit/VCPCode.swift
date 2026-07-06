import Foundation

/// A Virtual Control Panel feature (a DDC/CI opcode we can read/write).
public struct VCPCode: Hashable, Sendable {
  public let code: UInt8
  public let name: String
  public let isColor: Bool

  public init(_ code: UInt8, _ name: String, color: Bool = false) {
    self.code = code
    self.name = name
    self.isColor = color
  }

  // The set of features we probe for on each display. Rendering is gated on
  // whether the display actually answers a read for the code (see Display.probe).
  public static let catalog: [VCPCode] = [
    VCPCode(0x10, "Brightness"),
    VCPCode(0x12, "Contrast"),
    VCPCode(0x62, "Volume"),
    VCPCode(0x16, "Red", color: true),
    VCPCode(0x18, "Green", color: true),
    VCPCode(0x1A, "Blue", color: true),
    VCPCode(0x14, "Preset", color: true),
  ]

  // Non-catalog opcode used for the color-reset action.
  public static let restoreColorDefaults: UInt8 = 0x08
}

/// Names for VCP 0x14 (Select Color Preset) values, per the VESA MCCS
/// convention. Confirmed against hardware: both Dells report max=12 (through
/// "User 2") and were sitting on 12; the Corsair reports max=11 (through
/// "User 1"). RGB gain writes are only honored while a "User" slot is active —
/// fixed-Kelvin presets lock the gains out on some monitors.
public enum ColorPreset {
  public static let names: [UInt16: String] = [
    1: "sRGB", 2: "Display Native", 3: "4000K", 4: "5000K", 5: "6500K",
    6: "7500K", 7: "8200K", 8: "9300K", 9: "10000K", 10: "11500K",
    11: "User 1", 12: "User 2", 13: "User 3",
  ]

  public static func name(for value: UInt16) -> String {
    names[value] ?? "Preset \(value)"
  }
}

/// Live state of one feature on one display.
public struct Feature: Identifiable, Sendable {
  public let code: VCPCode
  public var current: UInt16
  public var max: UInt16
  public var id: UInt8 { code.code }
}
