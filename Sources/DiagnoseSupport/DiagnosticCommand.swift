import Foundation

public enum DiagnosticCommand: Equatable {
  case help
  case list
  case set(name: String, code: UInt8, value: UInt16, persist: Bool)
  case persistCheck(name: String, code: UInt8)
  case presetTest
  case colorTest(name: String)

  public static let usage = """
  Usage:
    ddc-diagnose                         Read detected controls
    ddc-diagnose set <name> <vcpHex> <value>
    ddc-diagnose persist-set <name> <vcpHex> <value>
    ddc-diagnose persist-check <name> [vcpHex]
    ddc-diagnose presettest <name>       Write User 1 and red gain
    ddc-diagnose preset-test             Save/reload/apply a temporary preset
    ddc-diagnose --help

  Names must identify exactly one controllable display. Codes are hexadecimal.
  set/presettest/preset-test write hardware. persist-set also saves the confirmed
  value. persist-check restores saved values to the selected monitor.
  Quit other DDC apps before running hardware diagnostics.
  """

  public init(arguments: [String]) throws {
    guard let command = arguments.first else { self = .list; return }
    switch command {
    case "--help", "-h":
      guard arguments.count == 1 else { throw UsageError() }
      self = .help
    case "set", "persist-set":
      guard arguments.count == 4, !arguments[1].isEmpty,
            let code = Self.code(arguments[2]), let value = UInt16(arguments[3]) else { throw UsageError() }
      self = .set(name: arguments[1], code: code, value: value, persist: command == "persist-set")
    case "persist-check":
      guard (2...3).contains(arguments.count), !arguments[1].isEmpty,
            let code = arguments.count == 3 ? Self.code(arguments[2]) : UInt8(0x12) else { throw UsageError() }
      self = .persistCheck(name: arguments[1], code: code)
    case "presettest":
      guard arguments.count == 2, !arguments[1].isEmpty else { throw UsageError() }
      self = .colorTest(name: arguments[1])
    case "preset-test":
      guard arguments.count == 1 else { throw UsageError() }
      self = .presetTest
    default:
      throw UsageError()
    }
  }

  private static func code(_ value: String) -> UInt8? {
    let hex = value.lowercased()
    return UInt8(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16)
  }
}

public struct UsageError: Error {}
