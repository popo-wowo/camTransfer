import Darwin
import Foundation

enum CameraVendorPtpNetworkServiceProfile: Equatable {
  case current
  case responsiveData
}

enum CameraVendorDebugPtpNetworkServicePolicy {
  static let responsiveDataArgument = "--camtransfer-debug-ptp-network-service=responsive-data"

  static func resolve(
    arguments: [String],
    debugBuild: Bool
  ) -> CameraVendorPtpNetworkServiceProfile {
    guard debugBuild, arguments.contains(responsiveDataArgument) else {
      return .current
    }
    return .responsiveData
  }
}

// MARK: - Socket Buffer Profile Experiment (Branch C3/C4)

/// Controls SO_RCVBUF/SO_SNDBUF behavior on the PTP command socket.
///
/// Hypothesis: XApp's ~283 KiB advertised window (vs CamTransfer's ~2.1 MiB) creates
/// TCP backpressure that keeps the camera's WiFi/SD pipeline steady, avoiding the
/// burst-pause pattern that produces 100-900ms data gaps.
///
/// - `production`: current 2 MiB explicit buffer (Window Scale 5, ~2.1 MiB window)
/// - `kernelAutotuning`: no explicit SO_RCVBUF/SO_SNDBUF — let Darwin TCP autotuning
///   dynamically size the window based on RTT and throughput
/// - `xappWindowMatch`: 256 KiB explicit buffer — target Window Scale ~2-3 and
///   advertised window ~256 KiB to approximate XApp's observed TCP feedback profile
/// - `minimal`: 64 KiB explicit buffer — aggressive backpressure test
enum CameraVendorPtpSocketBufferProfile: String, CustomStringConvertible {
  case production = "production"
  case kernelAutotuning = "kernel-autotuning"
  case xappWindowMatch = "xapp-window-match"
  case minimal = "minimal"

  var description: String { rawValue }

  /// Returns the SO_RCVBUF value to set, or nil to skip setsockopt entirely.
  var receiveBufferBytes: Int32? {
    switch self {
    case .production: return 2 * 1024 * 1024
    case .kernelAutotuning: return nil
    case .xappWindowMatch: return 256 * 1024
    case .minimal: return 64 * 1024
    }
  }

  /// Returns the SO_SNDBUF value to set, or nil to skip setsockopt entirely.
  var sendBufferBytes: Int32? {
    switch self {
    case .production:
      return 2 * 1024 * 1024
    case .kernelAutotuning:
      return nil
    case .xappWindowMatch:
      // Keep request-side buffering at the production baseline. This branch
      // is intended to vary only the receive-side TCP feedback.
      return 2 * 1024 * 1024
    case .minimal:
      return 64 * 1024
    }
  }
}

enum CameraVendorDebugPtpSocketBufferPolicy {
  static let argumentPrefix = "--camtransfer-debug-socket-buffer="

  static func resolve(
    arguments: [String],
    debugBuild: Bool
  ) -> CameraVendorPtpSocketBufferProfile {
    guard debugBuild else { return .kernelAutotuning }
    guard let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else {
      return .kernelAutotuning
    }
    let value = String(argument.dropFirst(argumentPrefix.count))
    return CameraVendorPtpSocketBufferProfile(rawValue: value) ?? .kernelAutotuning
  }
}

// MARK: - TCP_NODELAY Experiment

/// Controls whether TCP_NODELAY is set on the PTP command socket.
///
/// Hypothesis: TCP_NODELAY forces immediate ACK transmission, resulting in
/// ACK ratio ~0.10. XApp (likely using NWConnection) shows ACK ratio ~0.04,
/// suggesting delayed/coalesced ACKs. The camera's WiFi firmware may produce
/// steadier data flow when receiving fewer, batched ACKs.
///
/// - `enabled`: current behavior — TCP_NODELAY=1, low-latency ACKs
/// - `disabled`: skip TCP_NODELAY — let kernel use delayed ACK (40ms coalescing)
enum CameraVendorPtpTcpNoDelayPolicy: String, CustomStringConvertible {
  case enabled = "enabled"
  case disabled = "disabled"

  var description: String { rawValue }

  var shouldSetNoDelay: Bool {
    self == .enabled
  }
}

enum CameraVendorDebugPtpTcpNoDelayPolicy {
  static let argumentPrefix = "--camtransfer-debug-tcp-nodelay="

  static func resolve(
    arguments: [String],
    debugBuild: Bool
  ) -> CameraVendorPtpTcpNoDelayPolicy {
    guard debugBuild else { return .enabled }
    guard let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else {
      return .enabled
    }
    let value = String(argument.dropFirst(argumentPrefix.count))
    return CameraVendorPtpTcpNoDelayPolicy(rawValue: value) ?? .enabled
  }
}

typealias CameraVendorPtpReceiveFunction = (
  Int32,
  UnsafeMutableRawPointer?,
  Int,
  Int32
) -> Int

final class CameraVendorPtpSocket {
  private let stateLock = NSLock()
  private var fd: Int32
  private var interruptionReason: String?
  private let receiveFunction: CameraVendorPtpReceiveFunction

  init(
    connectedFileDescriptor: Int32 = -1,
    receiveFunction: @escaping CameraVendorPtpReceiveFunction = { descriptor, buffer, length, flags in
      Darwin.recv(descriptor, buffer, length, flags)
    }
  ) {
    fd = connectedFileDescriptor
    self.receiveFunction = receiveFunction
  }

  private func currentDescriptor() -> Int32 {
    stateLock.lock()
    defer { stateLock.unlock() }
    return fd
  }

  private func cancellationErrorIfInterrupted() -> NSError? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let interruptionReason else { return nil }
    return NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "PTP socket 已中断: \(interruptionReason)"]
    )
  }

  private func throwIfInterrupted() throws {
    if let error = cancellationErrorIfInterrupted() {
      throw error
    }
  }

  func connect(
    host: String,
    port: Int,
    timeout: TimeInterval = 10,
    diagnosticHandler: ((String) -> Void)? = nil,
    networkServiceProfile: CameraVendorPtpNetworkServiceProfile = .current,
    socketBufferProfile: CameraVendorPtpSocketBufferProfile = .kernelAutotuning,
    tcpNoDelayPolicy: CameraVendorPtpTcpNoDelayPolicy = .enabled
  ) throws {
    CameraVendorFileLogger.log("CameraVendorPtpSocket.connect 开始: \(host):\(port) bufferProfile=\(socketBufferProfile) tcpNoDelay=\(tcpNoDelayPolicy)")
    diagnosticHandler?("PTP socket 连接 \(host):\(port)")

    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 socket"])
    }

    // TCP_NODELAY — controlled by experiment policy.
    // enabled: force immediate small-packet send (current baseline, ACK ratio ~0.10)
    // disabled: let kernel use Nagle + delayed ACK (target ACK ratio ~0.04 like XApp)
    if tcpNoDelayPolicy.shouldSetNoDelay {
      var flag: Int32 = 1
      setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
    }
    CameraVendorFileLogger.log(
      "[OBS] PTP_TCP_NODELAY_POLICY policy=\(tcpNoDelayPolicy)"
    )

    // Socket buffer sizing — controlled by experiment profile.
    // production: explicit 2 MiB (current baseline, Window Scale 5)
    // kernelAutotuning: skip setsockopt, let Darwin TCP autotuning manage
    // xappWindowMatch: 256 KiB to approximate XApp's ~283 KiB advertised window
    // minimal: 64 KiB aggressive backpressure
    if let rcvBuf = socketBufferProfile.receiveBufferBytes {
      var bufBytes = rcvBuf
      setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))
    }
    if let sndBuf = socketBufferProfile.sendBufferBytes {
      var bufBytes = sndBuf
      setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))
    }

    // Log actual kernel buffer sizes for experiment correlation with pcap.
    var actualRcvBuf: Int32 = 0
    var actualSndBuf: Int32 = 0
    var optLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(sock, SOL_SOCKET, SO_RCVBUF, &actualRcvBuf, &optLen)
    optLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(sock, SOL_SOCKET, SO_SNDBUF, &actualSndBuf, &optLen)
    CameraVendorFileLogger.log(
      "[OBS] PTP_SOCKET_BUFFER_PROFILE " +
      "profile=\(socketBufferProfile) " +
      "requestedRcv=\(socketBufferProfile.receiveBufferBytes.map(String.init) ?? "auto") " +
      "requestedSnd=\(socketBufferProfile.sendBufferBytes.map(String.init) ?? "auto") " +
      "actualRcv=\(actualRcvBuf) actualSnd=\(actualSndBuf)"
    )

    do {
      try applyNetworkServiceProfile(networkServiceProfile, to: sock)
    } catch {
      Darwin.close(sock)
      throw error
    }

    // Set non-blocking for connect with timeout
    let flags = fcntl(sock, F_GETFL, 0)
    guard flags >= 0 else {
      let err = String(cString: strerror(errno))
      Darwin.close(sock)
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "读取 socket 标志失败: \(err)"]
      )
    }
    guard fcntl(sock, F_SETFL, flags | O_NONBLOCK) == 0 else {
      let err = String(cString: strerror(errno))
      Darwin.close(sock)
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "设置非阻塞 socket 失败: \(err)"]
      )
    }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let connectResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if connectResult < 0 && errno != EINPROGRESS {
      let err = String(cString: strerror(errno))
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: connect 失败: \(err)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "连接相机失败: \(err)"])
    }

    // Wait for connect to complete using poll()
    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
    let timeoutMs = Int32(timeout * 1000)
    let pollResult = poll(&pfd, 1, timeoutMs)

    if pollResult <= 0 {
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接超时 \(host):\(port)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "连接相机超时"])
    }

    // Check for connect error
    var sockErr: Int32 = 0
    var sockErrLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &sockErrLen)
    if sockErr != 0 {
      let err = String(cString: strerror(sockErr))
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接错误: \(err)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "连接相机失败: \(err)"])
    }

    // Restore blocking mode for read/write
    guard fcntl(sock, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      let err = String(cString: strerror(errno))
      Darwin.close(sock)
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "恢复阻塞 socket 失败: \(err)"]
      )
    }

    let previousDescriptor: Int32
    stateLock.lock()
    previousDescriptor = fd
    fd = sock
    interruptionReason = nil
    stateLock.unlock()
    if previousDescriptor >= 0, previousDescriptor != sock {
      _ = Darwin.shutdown(previousDescriptor, SHUT_RDWR)
      Darwin.close(previousDescriptor)
    }
    CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接成功 \(host):\(port) fd=\(sock)")
    diagnosticHandler?("PTP socket 已连接 \(host):\(port)")
  }

  private func applyNetworkServiceProfile(
    _ networkServiceProfile: CameraVendorPtpNetworkServiceProfile,
    to socket: Int32
  ) throws {
    guard networkServiceProfile == .responsiveData else { return }

    var requested = Int32(NET_SERVICE_TYPE_RD)
    let optionLength = socklen_t(MemoryLayout<Int32>.size)
    guard setsockopt(
      socket,
      SOL_SOCKET,
      SO_NET_SERVICE_TYPE,
      &requested,
      optionLength
    ) == 0 else {
      let err = String(cString: strerror(errno))
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "设置 responsive-data 网络服务类型失败: \(err)"]
      )
    }

    var applied: Int32 = 0
    var appliedLength = optionLength
    guard getsockopt(
      socket,
      SOL_SOCKET,
      SO_NET_SERVICE_TYPE,
      &applied,
      &appliedLength
    ) == 0 else {
      let err = String(cString: strerror(errno))
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "读取 responsive-data 网络服务类型失败: \(err)"]
      )
    }
    guard applied == requested else {
      throw NSError(
        domain: "CameraVendorPtpSocket",
        code: 10,
        userInfo: [
          NSLocalizedDescriptionKey:
            "responsive-data 网络服务类型校验失败: requested=\(requested) applied=\(applied)"
        ]
      )
    }

    CameraVendorFileLogger.log(
      "[OBS] PTP_NETWORK_SERVICE_PROFILE branch=responsive-data " +
      "requested=\(requested) applied=\(applied)"
    )
  }

  func write(_ data: Data) throws {
    try throwIfInterrupted()
    let descriptor = currentDescriptor()
    guard descriptor >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "socket 未建立"])
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var written = 0
      while written < data.count {
        let count = Darwin.send(descriptor, baseAddress.advanced(by: written), data.count - written, 0)
        if count <= 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "写入失败: \(err)"])
        }
        written += count
      }
    }
  }

  func readExactly(
    _ length: Int,
    timeout: TimeInterval = 10,
    progressEveryBytes: Int? = nil,
    firstByteHandler: (() -> Void)? = nil,
    progressHandler: ((Int, Int, Int) -> Void)? = nil
  ) throws -> Data {
    try throwIfInterrupted()
    let descriptor = currentDescriptor()
    guard descriptor >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 6, userInfo: [NSLocalizedDescriptionKey: "socket 未建立"])
    }
    guard length > 0 else { return Data() }
    var data = Data(count: length)
    var offset = 0
    let deadline = Date().addingTimeInterval(timeout)
    let startedAt = Date()
    var nextProgressBytes = progressEveryBytes

    try data.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      while offset < length {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
          throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
        }

        // Use poll() to wait for data with timeout.
        var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let pollMs = Int32(min(remaining * 1000, Double(Int32.max)))
        let pollResult = poll(&pfd, 1, pollMs)

        if pollResult < 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
        }
        if pollResult == 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
        }

        // Check for errors, but allow reading if POLLIN is also set (data may arrive with HUP).
        if Int16(pfd.revents) & Int16(POLLERR | POLLNVAL) != 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机断开连接"])
        }

        let count = receiveFunction(
          descriptor,
          baseAddress.advanced(by: offset),
          length - offset,
          MSG_DONTWAIT
        )
        if count < 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { continue }
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
        }
        if count == 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 \(offset)/\(length) 字节)"])
        }
        offset += count
        firstByteHandler?()
        if let progressEveryBytes,
           progressEveryBytes > 0,
           let progressHandler,
           let nextProgressBytesValue = nextProgressBytes,
           offset >= nextProgressBytesValue {
          progressHandler(
            offset,
            length,
            Int(Date().timeIntervalSince(startedAt) * 1000)
          )
          var next = nextProgressBytesValue
          while next <= offset {
            next += progressEveryBytes
          }
          nextProgressBytes = next
        }
      }
    }
    return data
  }

  func readExactlyToFile(
    _ length: Int,
    fileHandle: FileHandle,
    timeout: TimeInterval = 10,
    prefixByteCount: Int = 64
  ) throws -> (
    byteCount: Int,
    prefix: Data,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary
  ) {
    try throwIfInterrupted()
    let descriptor = currentDescriptor()
    guard descriptor >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 6, userInfo: [NSLocalizedDescriptionKey: "socket 未建立"])
    }
    guard length > 0 else { return (0, Data(), 0, 0, CameraVendorPtpReceiveCadenceSummary()) }

    // Elevate this thread to UserInteractive QoS for the duration of the
    // file transfer. This minimizes scheduling latency between poll()/recv()
    // calls, reducing gaps where the kernel buffer fills but userspace hasn't
    // consumed it (which would stall ACKs and slow the camera's data production).
    let previousQoS = qos_class_self()
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    defer { pthread_set_qos_class_self_np(previousQoS, 0) }

    // A PTP partial-object payload is bounded by the negotiated request size
    // (currently at most 12 MiB).  Receive it into one bounded allocation and
    // issue one file write, instead of allocating Data and synchronously
    // writing every 64 KiB received from the socket.
    let receiveStartedAt = Date()
    var payload = Data(count: length)
    var offset = 0
    var cadence = CameraVendorPtpReceiveCadenceSummary()
    // Use mach_absolute_time for deadline checks — avoids Date() syscall overhead
    // in the tight recv loop (called thousands of times per 12 MiB chunk).
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    let deadlineNanos = mach_absolute_time() + UInt64(timeout * 1_000_000_000) * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    // Cap each recv() request to 256 KiB. The kernel returns whatever is
    // available (often much less), but a bounded request ensures we cycle back
    // to poll() regularly, giving the kernel natural ACK pacing opportunities
    // without needing setsockopt.
    let maxRecvChunk = 256 * 1024
    try payload.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      while offset < length {
        if mach_absolute_time() >= deadlineNanos {
          throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
        }

        var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let remainingMs = Int32(min(
          Int64(deadlineNanos - mach_absolute_time()) * Int64(timebaseInfo.numer) / Int64(timebaseInfo.denom) / 1_000_000,
          Int64(Int32.max)
        ))
        let pollResult = poll(&pfd, 1, max(remainingMs, 1))
        if pollResult < 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
        }
        if pollResult == 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
        }
        if Int16(pfd.revents) & Int16(POLLERR | POLLNVAL) != 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机断开连接"])
        }

        let toRead = min(length - offset, maxRecvChunk)
        let count = receiveFunction(
          descriptor,
          baseAddress.advanced(by: offset),
          toRead,
          MSG_DONTWAIT
        )
        if count < 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { continue }
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
        }
        if count == 0 {
          if let error = cancellationErrorIfInterrupted() { throw error }
          throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 \(offset)/\(length) 字节)"])
        }
        cadence.recordRecv()
        offset += count
      }
    }
    let socketReceiveMs = Int(Date().timeIntervalSince(receiveStartedAt) * 1000)
    let prefix = Data(payload.prefix(prefixByteCount))
    let writeStartedAt = Date()
    try fileHandle.write(contentsOf: payload)
    let fileWriteMs = Int(Date().timeIntervalSince(writeStartedAt) * 1000)
    return (offset, prefix, socketReceiveMs, fileWriteMs, cadence)
  }

  @discardableResult
  func interrupt(reason: String) -> Bool {
    let descriptor: Int32
    stateLock.lock()
    descriptor = fd
    if descriptor >= 0 {
      interruptionReason = reason
    }
    stateLock.unlock()
    guard descriptor >= 0 else { return false }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    return true
  }

  func close() {
    let descriptor: Int32
    stateLock.lock()
    descriptor = fd
    fd = -1
    stateLock.unlock()
    guard descriptor >= 0 else { return }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }
}
