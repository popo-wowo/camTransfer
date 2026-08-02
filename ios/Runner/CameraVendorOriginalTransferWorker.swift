import Foundation

struct CameraVendorOriginalReadImageTransactionResult {
  let byteCount: Int
  let prefix: Data
  let requestToFirstByteMs: Int
  let socketReceiveMs: Int
  let fileWriteMs: Int
  let receiveCadence: CameraVendorPtpReceiveCadenceSummary
  let responseCode: UInt16
  let responseTransactionID: UInt32

  init(
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary = CameraVendorPtpReceiveCadenceSummary(),
    responseCode: UInt16,
    responseTransactionID: UInt32
  ) {
    self.byteCount = byteCount
    self.prefix = prefix
    self.requestToFirstByteMs = requestToFirstByteMs
    self.socketReceiveMs = socketReceiveMs
    self.fileWriteMs = fileWriteMs
    self.receiveCadence = receiveCadence
    self.responseCode = responseCode
    self.responseTransactionID = responseTransactionID
  }
}

struct CameraVendorPtpReceiveCadenceSummary: Equatable, Sendable {
  private(set) var pollWaitMs = 0
  private(set) var maxPollWaitMs = 0
  private(set) var pollWaitCount = 0
  private(set) var immediatePollCount = 0
  private(set) var recvCallCount = 0

  mutating func recordPoll(waitMs: Int) {
    let normalizedWaitMs = max(0, waitMs)
    pollWaitMs += normalizedWaitMs
    maxPollWaitMs = max(maxPollWaitMs, normalizedWaitMs)
    if normalizedWaitMs > 0 {
      pollWaitCount += 1
    } else {
      immediatePollCount += 1
    }
  }

  mutating func recordRecv() {
    recvCallCount += 1
  }

  mutating func merge(_ other: CameraVendorPtpReceiveCadenceSummary) {
    pollWaitMs += other.pollWaitMs
    maxPollWaitMs = max(maxPollWaitMs, other.maxPollWaitMs)
    pollWaitCount += other.pollWaitCount
    immediatePollCount += other.immediatePollCount
    recvCallCount += other.recvCallCount
  }
}

struct CameraVendorOriginalReadImageExecutionResult {
  let byteCount: Int
  let prefix: Data
  let requestToFirstByteMs: Int
  let socketReceiveMs: Int
  let fileWriteMs: Int
  let receiveCadence: CameraVendorPtpReceiveCadenceSummary
  let elapsedMs: Int
  let finalReadSize: UInt32
  let fallbackCount: Int

  init(
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary = CameraVendorPtpReceiveCadenceSummary(),
    elapsedMs: Int,
    finalReadSize: UInt32,
    fallbackCount: Int
  ) {
    self.byteCount = byteCount
    self.prefix = prefix
    self.requestToFirstByteMs = requestToFirstByteMs
    self.socketReceiveMs = socketReceiveMs
    self.fileWriteMs = fileWriteMs
    self.receiveCadence = receiveCadence
    self.elapsedMs = elapsedMs
    self.finalReadSize = finalReadSize
    self.fallbackCount = fallbackCount
  }
}

final class CameraVendorOriginalTransferWorker {
  private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
      lock.lock()
      self.result = result
      lock.unlock()
    }

    func take() -> Result<Value, Error> {
      lock.lock()
      defer { lock.unlock() }
      return result!
    }
  }

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()

  init(
    label: String = "com.camtransfer.camera-vendor.original-transfer",
    qos: DispatchQoS = .userInitiated
  ) {
    queue = DispatchQueue(label: label, qos: qos)
    queue.setSpecific(key: queueKey, value: 1)
  }

  func execute<T>(_ operation: @escaping () throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }

    let resultBox = ResultBox<T>()
    let completion = DispatchSemaphore(value: 0)
    queue.async {
      resultBox.store(Result {
        try operation()
      })
      completion.signal()
    }
    completion.wait()
    return try resultBox.take().get()
  }
}

struct CameraVendorOriginalReadImageExecutor {
  private let nextTransactionID: () -> UInt32
  private let sendRequest: (_ transactionID: UInt32, _ handle: UInt32, _ offset: UInt64, _ size: UInt32) throws -> Void
  private let receivePayloadAndResponse: (_ transactionID: UInt32, _ expectedMaximum: Int, _ sink: FileHandle) throws -> CameraVendorOriginalReadImageTransactionResult
  private let cancellationCheck: () throws -> Void
  private let fallbackReadSize: (_ error: Error, _ currentReadSize: UInt32, _ bytesWritten: Int) -> UInt32?
  private let report: (String) -> Void

  init(
    nextTransactionID: @escaping () -> UInt32,
    sendRequest: @escaping (_ transactionID: UInt32, _ handle: UInt32, _ offset: UInt64, _ size: UInt32) throws -> Void,
    receivePayloadAndResponse: @escaping (_ transactionID: UInt32, _ expectedMaximum: Int, _ sink: FileHandle) throws -> CameraVendorOriginalReadImageTransactionResult,
    cancellationCheck: @escaping () throws -> Void,
    fallbackReadSize: @escaping (_ error: Error, _ currentReadSize: UInt32, _ bytesWritten: Int) -> UInt32? = { _, _, _ in nil },
    report: @escaping (String) -> Void = { _ in }
  ) {
    self.nextTransactionID = nextTransactionID
    self.sendRequest = sendRequest
    self.receivePayloadAndResponse = receivePayloadAndResponse
    self.cancellationCheck = cancellationCheck
    self.fallbackReadSize = fallbackReadSize
    self.report = report
  }

  func execute(
    handle: UInt32,
    expectedByteCount: UInt64?,
    maximumByteCount: UInt64,
    initialReadSize: UInt32,
    fileHandle: FileHandle,
    withSerializedLease: (_ body: () throws -> CameraVendorOriginalReadImageExecutionResult) throws -> CameraVendorOriginalReadImageExecutionResult
  ) throws -> CameraVendorOriginalReadImageExecutionResult {
    report(
      "[OBS] PTP_ORIGINAL_COMMAND_LOCK_WAIT " +
      "handle=0x\(String(format: "%08X", handle))"
    )
    return try withSerializedLease {
      report(
        "[OBS] PTP_ORIGINAL_COMMAND_LOCK_ACQUIRED " +
        "handle=0x\(String(format: "%08X", handle))"
      )
      defer {
        report(
          "[OBS] PTP_ORIGINAL_COMMAND_LOCK_RELEASED " +
          "handle=0x\(String(format: "%08X", handle))"
        )
      }
      let startedAt = Date()
      var state = CameraVendorAdaptiveDownloadChunkState(readSize: initialReadSize)
      var offset: UInt64 = 0
      var totalBytes = 0
      var prefix = Data()
      var requestToFirstByteMs = 0
      var socketReceiveMs = 0
      var fileWriteMs = 0
      var receiveCadence = CameraVendorPtpReceiveCadenceSummary()
      var fallbackCount = 0

      while offset < maximumByteCount {
        try cancellationCheck()
        let remaining = maximumByteCount - offset
        let requestSize = CameraVendorTransferChunkProfile.requestSize(
          remaining: remaining,
          selectedReadSize: state.readSize
        )
        let transactionID = nextTransactionID()
        let chunkStartedAt = Date()
        report(
          "[OBS] PTP_ORIGINAL_REQUEST_SEND_BEGIN " +
          "handle=0x\(String(format: "%08X", handle)) transaction=\(transactionID) " +
          "offset=\(offset) size=\(requestSize)"
        )
        try sendRequest(transactionID, handle, offset, requestSize)
        report(
          "[OBS] PTP_ORIGINAL_REQUEST_SEND_END " +
          "handle=0x\(String(format: "%08X", handle)) transaction=\(transactionID)"
        )

        let streamedChunk: CameraVendorOriginalReadImageTransactionResult
        do {
          report(
            "[OBS] PTP_ORIGINAL_RECEIVE_BEGIN " +
            "handle=0x\(String(format: "%08X", handle)) transaction=\(transactionID)"
          )
          streamedChunk = try receivePayloadAndResponse(
            transactionID,
            Int(requestSize),
            fileHandle
          )
          report(
            "[OBS] PTP_ORIGINAL_RESPONSE_RECEIVED " +
            "handle=0x\(String(format: "%08X", handle)) transaction=\(transactionID) " +
            "response=0x\(String(format: "%04X", streamedChunk.responseCode)) " +
            "bytes=\(streamedChunk.byteCount)"
          )
        } catch {
          throw error
        }

        guard streamedChunk.responseTransactionID == transactionID else {
          throw NSError(
            domain: "CameraVendorPtpSession",
            code: 12,
            userInfo: [
              NSLocalizedDescriptionKey: "原图 ReadImage 响应 transaction 不匹配，期望 \(transactionID)，实际 \(streamedChunk.responseTransactionID)"
            ]
          )
        }

        do {
          try CameraVendorPtpResponsePolicy.validateOK(
            responseCode: streamedChunk.responseCode,
            operationName: "原图 ReadImage transaction \(transactionID)"
          )
        } catch {
          if streamedChunk.byteCount == 0,
             let reducedReadSize = fallbackReadSize(error, state.readSize, totalBytes) {
            let previousReadSize = state.readSize
            state.readSize = reducedReadSize
            fallbackCount += 1
            report(
              "[OBS] PTP_ORIGINAL_READ_IMAGE_FALLBACK_READ_SIZE " +
              "handle=0x\(String(format: "%08X", handle)) offset=\(offset) " +
              "from=\(previousReadSize) to=\(reducedReadSize)"
            )
            continue
          }
          throw error
        }

        try cancellationCheck()
        guard streamedChunk.byteCount > 0 else { break }
        if prefix.count < 64 {
          prefix.append(streamedChunk.prefix.prefix(64 - prefix.count))
        }
        totalBytes += streamedChunk.byteCount
        offset += UInt64(streamedChunk.byteCount)
        requestToFirstByteMs += streamedChunk.requestToFirstByteMs
        socketReceiveMs += streamedChunk.socketReceiveMs
        fileWriteMs += streamedChunk.fileWriteMs
        receiveCadence.merge(streamedChunk.receiveCadence)

        let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
        CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
          byteCount: streamedChunk.byteCount,
          elapsedMs: chunkElapsedMs,
          state: &state
        )

        if let expectedByteCount, UInt64(totalBytes) >= expectedByteCount {
          break
        }
      }

      if let expectedByteCount, UInt64(totalBytes) != expectedByteCount {
        throw NSError(
          domain: "CameraVendorPtpSession",
          code: 14,
          userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 文件长度不完整，期望 \(expectedByteCount)，实际 \(totalBytes)"
          ]
        )
      }

      return CameraVendorOriginalReadImageExecutionResult(
        byteCount: totalBytes,
        prefix: prefix,
        requestToFirstByteMs: requestToFirstByteMs,
        socketReceiveMs: socketReceiveMs,
        fileWriteMs: fileWriteMs,
        receiveCadence: receiveCadence,
        elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
        finalReadSize: state.readSize,
        fallbackCount: fallbackCount
      )
    }
  }
}

enum CameraVendorOriginalReadImageExecutorPolicy {
  static func rawReadSize(from data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    return UInt32(data[0]) |
      (UInt32(data[1]) << 8) |
      (UInt32(data[2]) << 16) |
      (UInt32(data[3]) << 24)
  }

  static func negotiatedReadSize(from data: Data) -> UInt32? {
    guard data.count >= 4,
          let readSize = rawReadSize(from: data),
          readSize == 0x00BFFFE0 ||
            readSize == 0x00400000 ||
            readSize == 0x00100000 else {
      return nil
    }
    return readSize
  }

  static func initialReadSize(
    cachedReadSize: UInt32?,
    negotiatedReadSize: UInt32? = nil
  ) -> UInt32 {
    _ = cachedReadSize
    if let negotiatedReadSize,
       CameraVendorTransferChunkProfile.isSupportedReadSize(negotiatedReadSize) {
      return negotiatedReadSize
    }
    return CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
  }

  static func profileSource(negotiatedReadSize: UInt32?) -> String {
    negotiatedReadSize == nil ? "safe-fallback-4mb" : "d235"
  }

  static func shouldUse(
    downloadMode: CameraVendorTransferDownloadMode,
    purpose: String
  ) -> Bool {
    downloadMode == .original && purpose == "download-file"
  }
}
