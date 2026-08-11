import Darwin
import Foundation

struct CameraVendorOperationResponse {
  let dataPhase: UInt16
  let responseCode: UInt16
  let transactionID: UInt32
  let params: Data
}


struct CameraVendorDataCommandTiming: Equatable {
  let requestToFirstByteMs: Int
  let dataCompleteMs: Int
  let responseCompleteMs: Int
  let totalMs: Int
}


enum CameraVendorDataCommandTimingLogPolicy {
  static func completedMessage(
    operationCode: UInt16,
    handle: UInt32?,
    byteCount: Int,
    timing: CameraVendorDataCommandTiming
  ) -> String {
    "[OBS] PTP_GALLERY_BOOTSTRAP_COMMAND_TIMING " +
      "op=0x\(String(format: "%04X", operationCode)) " +
      "handle=\(handle.map { String(format: "0x%08X", $0) } ?? "nil") " +
      "bytes=\(byteCount) requestToFirstByteMs=\(timing.requestToFirstByteMs) " +
      "dataCompleteMs=\(timing.dataCompleteMs) responseCompleteMs=\(timing.responseCompleteMs) " +
      "totalMs=\(timing.totalMs)"
  }
}


enum CameraVendorPtpResponsePolicy {
  static let okResponseCode: UInt16 = 0x2001

  static func validateTransactionID(
    response: UInt32,
    expected: UInt32
  ) throws {
    guard response == expected else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 15,
        userInfo: [
          NSLocalizedDescriptionKey:
            "PTP response transaction \(response) does not match request transaction \(expected)",
          "expectedTransactionID": NSNumber(value: expected),
          "responseTransactionID": NSNumber(value: response),
        ]
      )
    }
  }

  static func validateOK(
    responseCode: UInt16,
    operationName: String,
    operationCode: UInt16? = nil,
    transactionID: UInt32? = nil
  ) throws {
    guard responseCode == okResponseCode else {
      var userInfo: [String: Any] = [
        NSLocalizedDescriptionKey:
          "\(operationName) 返回 PTP 响应码 0x\(String(format: "%04X", responseCode))",
      ]
      if let operationCode {
        userInfo["operationCode"] = NSNumber(value: operationCode)
      }
      if let transactionID {
        userInfo["transactionID"] = NSNumber(value: transactionID)
      }
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(responseCode),
        userInfo: userInfo
      )
    }
  }
}


enum CameraVendorPtpPacketType {
  static let initCommandRequest = 0x00000001
  static let initCommandAck = 0x00000002
  static let initEventRequest = 0x00000003
  static let initEventAck = 0x00000004
  static let initFail = 0x00000005
  static let operationRequest = 0x00000006
  static let operationResponse = 0x00000007
  static let startDataPacket = 0x00000009
  static let dataPacket = 0x0000000A
  static let endDataPacket = 0x0000000C
}


enum CameraVendorLegacyPacketMapper {
  static func packetType(forKind kind: UInt16) -> Int {
    switch kind {
    case 2, 21:
      return CameraVendorPtpPacketType.dataPacket
    case 3, 12:
      return CameraVendorPtpPacketType.operationResponse
    default:
      return Int(kind)
    }
  }

  static func operationResponsePayload(forKind kind: UInt16, body: Data) -> Data {
    guard kind == 12, body.count >= 6 else {
      return body
    }
    // CameraVendor legacy thumbnail/object streams finish with kind=12 whose first
    // word is not a standard PTP response code. Treat it as OK and preserve
    // the transaction bytes so the shared response parser can finish.
    var payload = Data([0x01, 0x20])
    payload.append(body.dropFirst(2).prefix(4))
    return payload
  }
}


enum CameraVendorPtpOperationCode {
  static let openSession = 0x1002
  static let closeSession = 0x1003
  static let getStorageIDs = 0x1004
  static let getObjectHandles = 0x1007
  static let getObjectInfo = 0x1008
  static let getObject = 0x1009
  static let getThumb = 0x100A
  static let getDevicePropValue = 0x1015
  static let setDevicePropValue = 0x1016
  static let getPartialObject = 0x101B
  static let initiateOpenCapture = 0x101C
  static let mtpGetObjectPropList = 0x9805
  static let cameraVendorGetSearchModeDescAll = 0x9050
  static let cameraVendorSetSearchModeAll = 0x9051
  static let cameraVendorGetSearchModeAll = 0x9052
  static let cameraVendorGetSpecifiedObjectCountGroupByDate = 0x9053
  static let cameraVendorGetLatestObjectInfo = 0x9054
  static let cameraVendorGetExtensionThumb = 0x9055
  static let cameraVendorGetExtensionPartialObject = 0x9056
}


enum CameraVendorDevicePropertyWidth: Equatable {
  case uint16
  case uint32
}


struct CameraVendorDownloadModeProperty: Equatable {
  let code: UInt32
  let value: UInt32
  let width: CameraVendorDevicePropertyWidth
}


enum CameraVendorDevicePropCode {
  static let cameraState: UInt32 = 0xDF00
  static let initSequence: UInt32 = 0xDF01
  static let imageGetVersion: UInt32 = 0xDF21
  static let getObjectVersion: UInt32 = 0xDF22
  static let referenceAppImageHost: UInt32 = 0xDF28
  static let referenceAppReservedReceive: UInt32 = 0xDF29
  static let appVersion: UInt32 = 0xDF24
  static let remoteGetObjectVersion: UInt32 = 0xDF25
  static let referenceAppGalleryObjectContext: UInt32 = 0xD212
  static let referenceAppGalleryReadyMarker: UInt32 = 0xD222
  static let imageForceCompression: UInt32 = 0xD226
  static let imageCompressionRealInfo: UInt32 = 0xD227
  static let objectCompressionSetting: UInt32 = 0xD22E
  static let currentObjectHandle: UInt32 = 0xD22B
  static let compressionCutOff: UInt32 = 0xD235
  static let referenceAppGalleryAccessState: UInt32 = 0xD244
  static let dualSlotStatus: UInt32 = 0xD244
  static let specifiedObjectCount: UInt32 = 0xD620
  static let specifiedObjectHandles: UInt32 = 0xD621
}


enum CameraVendorPtpConstants {
  static let protocolVersion = 0x8F53E4F2
  static let standardPtpIpProtocolVersion = 0x00010000
  static let defaultHost = "192.168.0.1"
  static let commandPort = 55740
  static let eventPort = 55741
  static let allFormats = 0x00000000
  static let allHandles = 0xFFFFFFFF
  static let initGuidBaseWords: [UInt32] = [
    0x5D48A5AD,
    0x0B7FB287,
    0xD0DED5D3,
  ]
  static let initDeviceNameByteCount = 54

  /// Build GUID words. The fourth word is only filled when a caller has
  /// explicitly confirmed the current Wi-Fi IP.
  static func initGuidWords(clientIP: String? = nil) -> [UInt32] {
    var words = initGuidBaseWords
    var ipWord: UInt32 = 0
    if let ip = clientIP,
       isCameraWifiIPv4Address(ip) {
      var addr = in_addr()
      if inet_pton(AF_INET, ip, &addr) == 1 {
        ipWord = UInt32(bigEndian: addr.s_addr)
      }
    }
    words.append(ipWord)
    return words
  }

  static func isCameraWifiIPv4Address(_ ip: String?) -> Bool {
    ip?.hasPrefix("192.168.0.") == true
  }
}


struct CameraVendorPtpPacket {
  let type: Int
  let payload: Data
}


enum CameraVendorPtpPacketBuilder {
  static func mtpObjectPropListParameters(
    objectHandle: UInt32,
    propertyCode: UInt32
  ) -> [UInt32] {
    [
      objectHandle,
      0,
      propertyCode,
      0,
      0,
    ]
  }

  static func buildInitCommandRequest(friendlyName: String, clientIP: String? = nil) -> Data {
    let guidWords = CameraVendorPtpConstants.initGuidWords(clientIP: clientIP)
    var payload = Data()
    payload.append(uint32LE(UInt32(CameraVendorPtpPacketType.initCommandRequest)))
    payload.append(uint32LE(UInt32(CameraVendorPtpConstants.protocolVersion)))
    for word in guidWords {
      payload.append(uint32LE(word))
    }
    payload.append(rawUtf16LEString(friendlyName, paddedTo: CameraVendorPtpConstants.initDeviceNameByteCount))
    // Prepend total length (including the 4-byte length field itself)
    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 4)))
    data.append(payload)
    return data
  }

  static func buildStandardInitCommandRequest(friendlyName: String, clientIP: String? = nil) -> Data {
    let guidWords = CameraVendorPtpConstants.initGuidWords(clientIP: clientIP)
    var payload = Data()
    payload.append(uint32LE(UInt32(CameraVendorPtpPacketType.initCommandRequest)))
    for word in guidWords {
      payload.append(uint32LE(word))
    }
    payload.append(ptpUnicodeString(friendlyName))
    payload.append(uint32LE(UInt32(CameraVendorPtpConstants.standardPtpIpProtocolVersion)))

    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 4)))
    data.append(payload)
    return data
  }

  static func buildInitEventRequest(connectionNumber: UInt32) -> Data {
    wrap(type: CameraVendorPtpPacketType.initEventRequest, payload: uint32LE(connectionNumber))
  }

  /// PTP/IP operation request.
  /// Wire format: [4 length][4 type=6][4 dataPhase][2 op][4 txn][4*N params]
  static func buildOperationRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    parameters: [UInt32] = [],
    dataPhase: UInt32 = 1
  ) -> Data {
    var payload = Data()
    payload.append(uint32LE(dataPhase))
    payload.append(uint16LE(operationCode))
    payload.append(uint32LE(transactionID))
    for parameter in parameters {
      payload.append(uint32LE(parameter))
    }
    return wrap(type: CameraVendorPtpPacketType.operationRequest, payload: payload)
  }

  /// CameraVendor legacy operation request observed from ReferenceApp after the legacy INIT:
  /// [4 length][2 dataPhase][2 op][4 txn][4*N params].
  static func buildCameraVendorLegacyOperationRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    parameters: [UInt32] = [],
    dataPhase: UInt16 = 1
  ) -> Data {
    var data = Data()
    let length = 4 + 2 + 2 + 4 + (parameters.count * 4)
    data.append(uint32LE(UInt32(length)))
    data.append(uint16LE(dataPhase))
    data.append(uint16LE(operationCode))
    data.append(uint32LE(transactionID))
    for parameter in parameters {
      data.append(uint32LE(parameter))
    }
    return data
  }

  static func buildCameraVendorDataOutRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    data: Data
  ) -> Data {
    buildEndDataPacket(transactionID: transactionID, data: data)
  }

  static func buildCameraVendorLegacyDataOutRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    data: Data
  ) -> Data {
    var packet = Data()
    let length = 4 + 2 + 2 + 4 + data.count
    packet.append(uint32LE(UInt32(length)))
    packet.append(uint16LE(2))
    packet.append(uint16LE(operationCode))
    packet.append(uint32LE(transactionID))
    packet.append(data)
    return packet
  }

  /// CameraVendor data packets still use the standard [length][type] header format.
  static func buildStartDataPacket(transactionID: UInt32, totalLength: UInt32) -> Data {
    var payload = Data()
    payload.append(uint32LE(transactionID))
    payload.append(uint32LE(totalLength))
    return wrap(type: CameraVendorPtpPacketType.startDataPacket, payload: payload)
  }

  static func buildEndDataPacket(transactionID: UInt32, data: Data) -> Data {
    var payload = Data()
    payload.append(uint32LE(transactionID))
    payload.append(data)
    return wrap(type: CameraVendorPtpPacketType.endDataPacket, payload: payload)
  }

  private static func wrap(type: Int, payload: Data) -> Data {
    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 8)))
    data.append(uint32LE(UInt32(type)))
    data.append(payload)
    return data
  }

  private static func ptpUnicodeString(_ string: String, paddedTo byteCount: Int? = nil) -> Data {
    var data = Data([UInt8(min(string.count + 1, 255))])
    for scalar in string.unicodeScalars {
      data.append(uint16LE(UInt16(scalar.value)))
    }
    data.append(uint16LE(0))
    if let byteCount {
      if data.count > byteCount {
        data = data.prefix(byteCount)
      } else if data.count < byteCount {
        data.append(Data(repeating: 0, count: byteCount - data.count))
      }
    }
    return data
  }

  private static func uint16LE(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  private static func uint32LE(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  /// Raw UTF-16LE string without PTP length prefix, zero-padded to a fixed byte count.
  /// Used for CameraVendor init packets which expect plain UTF-16LE, not PTP string format.
  private static func rawUtf16LEString(_ string: String, paddedTo byteCount: Int) -> Data {
    var data = Data()
    for scalar in string.unicodeScalars {
      data.append(uint16LE(UInt16(scalar.value)))
    }
    // null terminator
    data.append(uint16LE(0))
    // pad or truncate to exact size
    if data.count > byteCount {
      data = data.prefix(byteCount)
    } else if data.count < byteCount {
      data.append(Data(repeating: 0, count: byteCount - data.count))
    }
    return data
  }
}


enum CameraVendorPtpDataParser {
  static func uint32Array(from data: Data) -> [UInt32] {
    guard data.count >= 4 else { return [] }
    let count = Int(uint32(from: data, offset: 0))
    var values: [UInt32] = []
    for index in 0..<count {
      let offset = 4 + (index * 4)
      guard offset + 4 <= data.count else { break }
      values.append(uint32(from: data, offset: offset))
    }
    return values
  }

  static func specifiedObjectDateGroups(from data: Data) -> [CameraVendorSpecifiedObjectDateGroup] {
    guard data.count >= 4 else { return [] }
    let count = Int(uint32(from: data, offset: 0))
    var offset = 4
    var groups: [CameraVendorSpecifiedObjectDateGroup] = []
    for _ in 0..<count {
      guard offset + 4 <= data.count else { break }
      let entryLength = Int(uint32(from: data, offset: offset))
      guard entryLength >= 8 else { break }
      let entryEnd = offset + entryLength
      guard entryEnd <= data.count else { break }
      let dateOffset = offset + 4
      let dateText = ptpString(from: data, offset: dateOffset)
      let objectCountOffset = dateOffset + ptpStringByteLength(from: data, offset: dateOffset)
      guard objectCountOffset + 4 <= entryEnd else { break }
      groups.append(CameraVendorSpecifiedObjectDateGroup(
        dateText: dateText,
        objectCount: uint32(from: data, offset: objectCountOffset)
      ))
      offset = entryEnd
    }
    return groups
  }

  static func objectInfo(handle: Int, data: Data) -> CameraVendorCameraObjectInfo {
    let storageID = uint32(from: data, offset: 0)
    let formatCode = uint16(from: data, offset: 4)
    let compressedSize = uint32(from: data, offset: 8)
    let thumbCompressedSize = uint32(from: data, offset: 14)
    let filenameOffset = 52
    let filename = ptpString(from: data, offset: filenameOffset)
    let captureDateOffset = filenameOffset + ptpStringByteLength(from: data, offset: filenameOffset)
    let captureDate = ptpString(from: data, offset: captureDateOffset)
    let metadataOffset = captureDateOffset + ptpStringByteLength(from: data, offset: captureDateOffset)
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID,
      formatCode: formatCode,
      compressedSize: compressedSize,
      thumbCompressedSize: thumbCompressedSize,
      filename: filename,
      captureDate: captureDate,
      orientation: cameraVendorOrientation(in: data, offset: metadataOffset)
    )
  }

  static func cameraVendorVendorObjectInfo(handle: Int, data: Data) -> CameraVendorCameraObjectInfo {
    let storageID = uint32(from: data, offset: 0)
    let formatCode = uint16(from: data, offset: 4)
    let compressedSize = uint32(from: data, offset: 8)
    let thumbCompressedSize = uint32(from: data, offset: 14)
    let filenameOffset = 54
    let filename = ptpString(from: data, offset: filenameOffset)
    let captureDateOffset = filenameOffset + ptpStringByteLength(from: data, offset: filenameOffset)
    let captureDate = ptpString(from: data, offset: captureDateOffset)
    let orientationOffset = captureDateOffset + ptpStringByteLength(from: data, offset: captureDateOffset)
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID,
      formatCode: formatCode,
      compressedSize: compressedSize,
      thumbCompressedSize: thumbCompressedSize,
      filename: filename,
      captureDate: captureDate,
      orientation: cameraVendorOrientation(in: data, offset: orientationOffset)
    )
  }

  static func cameraVendorGalleryContextValue(for code: UInt32, in data: Data) -> UInt32? {
    guard data.count >= 10 else { return nil }
    for offset in 0...(data.count - 6) {
      let currentCode = UInt32(uint16(from: data, offset: offset))
      let valueOffset = offset + 2
      if currentCode == code {
        return uint32(from: data, offset: valueOffset)
      }
    }
    return nil
  }

  private static func ptpString(from data: Data, offset: Int) -> String {
    guard offset < data.count else { return "" }
    let charCount = Int(data[offset])
    guard charCount > 0 else { return "" }
    var scalars: [UnicodeScalar] = []
    var position = offset + 1
    for _ in 0..<charCount {
      guard position + 1 < data.count else { break }
      let codeUnit = uint16(from: data, offset: position)
      if codeUnit == 0 { break }
      if let scalar = UnicodeScalar(codeUnit) {
        scalars.append(scalar)
      }
      position += 2
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func ptpStringByteLength(from data: Data, offset: Int) -> Int {
    guard offset < data.count else { return 1 }
    return 1 + (Int(data[offset]) * 2)
  }

  private static func cameraVendorOrientation(in data: Data, offset: Int) -> Int? {
    var currentOffset = offset
    for _ in 0..<12 {
      guard currentOffset < data.count else { return nil }
      if let orientation = orientationFromMetadataString(ptpString(from: data, offset: currentOffset)) {
        return orientation
      }
      currentOffset += max(ptpStringByteLength(from: data, offset: currentOffset), 1)
    }
    return nil
  }

  private static func orientationFromMetadataString(_ value: String) -> Int? {
    guard let range = value.range(
      of: #"(?i)\borientation\s*:\s*([1-8])\b"#,
      options: .regularExpression
    ) else {
      return nil
    }
    let matched = String(value[range])
    guard let rawValue = matched.split(separator: ":").last
      .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
      return nil
    }
    switch rawValue {
    case 1, 2:
      return 1
    case 6, 7:
      return 2
    case 3, 4:
      return 3
    case 5, 8:
      return 4
    default:
      return nil
    }
  }

  private static func uint16(from data: Data, offset: Int) -> UInt16 {
    let low = UInt16(data[offset])
    let high = UInt16(data[offset + 1]) << 8
    return low | high
  }

  private static func uint32(from data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1]) << 8
    let b2 = UInt32(data[offset + 2]) << 16
    let b3 = UInt32(data[offset + 3]) << 24
    return b0 | b1 | b2 | b3
  }
}
