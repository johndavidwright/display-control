// Apple Silicon DDC/CI core.
// I2C packet framing, checksum, IORegistry traversal and IOAVService lookup are
// adapted from MonitorControl's Arm64DDC.swift (MIT, © MonitorControl authors).
// Display<->service matching here uses public CoreGraphics APIs (vendor/product/
// serial) rather than the private CoreDisplay info dictionary.

import CoreGraphics
import Foundation
import IOKit
import CDDCPrivate

let ARM64_DDC_7BIT_ADDRESS: UInt8 = 0x37 // DisplayPort DDC 7-bit address
let ARM64_DDC_DATA_ADDRESS: UInt8 = 0x51

enum Arm64DDC {
  static let MAX_MATCH_SCORE = 20

  struct IOregService {
    var edidUUID = ""
    var manufacturerID = ""
    var productName = ""
    var serialNumber: Int64 = 0
    var alphanumericSerialNumber = ""
    var location = ""
    var ioDisplayLocation = ""
    var transportUpstream = ""
    var transportDownstream = ""
    var service: IOAVService?
    var serviceLocation = 0
  }

  struct Match {
    var displayID: CGDirectDisplayID
    var service: IOAVService?
    var details: IOregService
    var matchScore: Int
  }

  // MARK: - Matching

  static func getServiceMatches(displayIDs: [CGDirectDisplayID]) -> [Match] {
    let services = self.getIoregServicesForMatching()
    var scored: [Int: [Match]] = [:]
    for displayID in displayIDs {
      for svc in services {
        let score = self.matchScore(displayID: displayID, svc: svc)
        scored[score, default: []].append(Match(displayID: displayID, service: svc.service, details: svc, matchScore: score))
      }
    }
    var matched: [Match] = []
    var takenLocations: [Int] = []
    var takenDisplayIDs: [CGDirectDisplayID] = []
    for score in stride(from: self.MAX_MATCH_SCORE, to: 0, by: -1) {
      guard let candidates = scored[score] else { continue }
      for c in candidates where !(takenDisplayIDs.contains(c.displayID) || takenLocations.contains(c.details.serviceLocation)) {
        takenDisplayIDs.append(c.displayID)
        takenLocations.append(c.details.serviceLocation)
        matched.append(c)
      }
    }
    return matched
  }

  /// Score an EDID-UUID service against a CG display using vendor/product/serial.
  static func matchScore(displayID: CGDirectDisplayID, svc: IOregService) -> Int {
    var score = 0
    let uuid = svc.edidUUID.uppercased()
    let vendor = CGDisplayVendorNumber(displayID)
    let model = CGDisplayModelNumber(displayID)
    let serial = CGDisplaySerialNumber(displayID)

    // Vendor ID lives at UUID chars [0,4)
    let vendorKey = String(format: "%04X", UInt16(truncatingIfNeeded: vendor))
    if uuid.count >= 4, String(uuid.prefix(4)) == vendorKey { score += 1 }

    // Product ID (byte-swapped) at UUID chars [4,8)
    let p = UInt16(truncatingIfNeeded: model)
    let productKey = String(format: "%02X%02X", UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF))
    if uuid.count >= 8 {
      let i4 = uuid.index(uuid.startIndex, offsetBy: 4)
      let i8 = uuid.index(uuid.startIndex, offsetBy: 8)
      if String(uuid[i4 ..< i8]) == productKey { score += 1 }
    }

    // Serial is the strongest signal when both sides report one.
    if serial != 0, Int64(serial) == svc.serialNumber { score += 5 }
    return score
  }

  // MARK: - I2C read / write

  static func read(service: IOAVService?, command: UInt8) -> (current: UInt16, max: UInt16)? {
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: 11)
    guard self.performDDCCommunication(service: service, send: &send, reply: &reply) else { return nil }
    let max = UInt16(reply[6]) * 256 + UInt16(reply[7])
    let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
    return (current, max)
  }

  @discardableResult
  static func write(service: IOAVService?, command: UInt8, value: UInt16) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
    var reply: [UInt8] = []
    return self.performDDCCommunication(service: service, send: &send, reply: &reply)
  }

  static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8],
                                      writeSleepTime: UInt32 = 10000, numOfWriteCycles: UInt8 = 2,
                                      readSleepTime: UInt32 = 50000, numOfRetryAttemps: UInt8 = 4,
                                      retrySleepTime: UInt32 = 20000) -> Bool {
    guard service != nil else { return false }
    let dataAddress = ARM64_DDC_DATA_ADDRESS
    var success = false
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
    packet[packet.count - 1] = self.checksum(chk: send.count == 1 ? ARM64_DDC_7BIT_ADDRESS << 1 : ARM64_DDC_7BIT_ADDRESS << 1 ^ dataAddress, data: &packet, start: 0, end: packet.count - 2)
    for _ in 1 ... numOfRetryAttemps + 1 {
      for _ in 1 ... max(numOfWriteCycles, 1) {
        usleep(writeSleepTime)
        success = IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &packet, UInt32(packet.count)) == 0
      }
      if !reply.isEmpty {
        usleep(readSleepTime)
        if IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), 0, &reply, UInt32(reply.count)) == 0 {
          success = self.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
        }
      }
      if success { return true }
      usleep(retrySleepTime)
    }
    return success
  }

  static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
    var c = chk
    for i in start ... end { c ^= data[i] }
    return c
  }

  // MARK: - IORegistry traversal (ported from MonitorControl)

  static func getIoregServicesForMatching() -> [IOregService] {
    var serviceLocation = 0
    var results: [IOregService] = []
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return results
    }
    defer { IOObjectRelease(iterator) }
    let keyProxy = "DCPAVServiceProxy"
    let keysFB = ["AppleCLCD2", "IOMobileFramebufferShim"]
    var current = IOregService()
    while let obj = self.iterateToNextObjectOfInterest(interests: [keyProxy] + keysFB, iterator: &iterator) {
      if keysFB.contains(obj.name) {
        current = self.appleCLCD2Properties(entry: obj.entry)
        serviceLocation += 1
        current.serviceLocation = serviceLocation
      } else if obj.name == keyProxy {
        self.dcpavServiceProxy(entry: obj.entry, ioregService: &current)
        results.append(current)
      }
    }
    return results
  }

  static func iterateToNextObjectOfInterest(interests: [String], iterator: inout io_iterator_t) -> (name: String, entry: io_service_t)? {
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { name.deallocate() }
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != MACH_PORT_NULL, IORegistryEntryGetName(entry, name) == KERN_SUCCESS else { break }
      let nameString = String(cString: name)
      for interest in interests where entry != IO_OBJECT_NULL && nameString.contains(interest) {
        return (nameString, entry)
      }
    }
    return nil
  }

  static func appleCLCD2Properties(entry: io_service_t) -> IOregService {
    var s = IOregService()
    if let u = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
       let edid = u.takeRetainedValue() as? String {
      s.edidUUID = edid
    }
    let cpath = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
    defer { cpath.deallocate() }
    IORegistryEntryGetPath(entry, kIOServicePlane, cpath)
    s.ioDisplayLocation = String(cString: cpath)
    if let u = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
       let attrs = u.takeRetainedValue() as? NSDictionary,
       let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary {
      s.manufacturerID = product.value(forKey: "ManufacturerID") as? String ?? ""
      s.productName = product.value(forKey: "ProductName") as? String ?? ""
      s.serialNumber = product.value(forKey: "SerialNumber") as? Int64 ?? 0
      s.alphanumericSerialNumber = product.value(forKey: "AlphanumericSerialNumber") as? String ?? ""
    }
    if let u = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
       let transport = u.takeRetainedValue() as? NSDictionary {
      s.transportUpstream = transport.value(forKey: "Upstream") as? String ?? ""
      s.transportDownstream = transport.value(forKey: "Downstream") as? String ?? ""
    }
    return s
  }

  static func dcpavServiceProxy(entry: io_service_t, ioregService: inout IOregService) {
    if let u = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
       let location = u.takeRetainedValue() as? String {
      ioregService.location = location
      if location == "External" {
        ioregService.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() as IOAVService?
      }
    }
  }
}
