import CoreImage
import Darwin
import Foundation
import Network
import UIKit

struct LocalProofingPhoto: Codable, Equatable {
  let id: String
  let filename: String
  let detail: String
  let formatLabel: String
  let hasPreview: Bool
}

struct LocalProofingFavoriteUpdate: Codable, Equatable {
  let id: String
  let favorite: Bool
}

enum LocalProofingPhotoMapper {
  static func photo(from item: WiredCameraImportItem) -> LocalProofingPhoto {
    LocalProofingPhoto(
      id: item.id,
      filename: item.name,
      detail: "\(item.formatLabel) · \(item.fileSizeText)",
      formatLabel: item.formatLabel,
      hasPreview: item.thumbnail != nil
    )
  }
}

enum LocalProofingPreviewEncoder {
  static func jpegData(from image: UIImage?, compressionQuality: CGFloat = 0.72) -> Data? {
    guard let image else { return nil }
    if let data = image.jpegData(compressionQuality: compressionQuality) {
      return data
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).jpegData(withCompressionQuality: compressionQuality) { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }
}

struct LocalProofingHTTPRequest: Equatable {
  let method: String
  let path: String
  let body: Data

  static func isComplete(_ data: Data) -> Bool {
    guard let raw = String(data: data, encoding: .utf8),
          let headerRange = raw.range(of: "\r\n\r\n") else {
      return false
    }

    let headerText = String(raw[..<headerRange.lowerBound])
    let headerData = Data(raw[..<headerRange.upperBound].utf8)
    return data.count >= headerData.count + contentLength(from: headerText)
  }

  static func parse(_ data: Data) -> LocalProofingHTTPRequest? {
    guard let raw = String(data: data, encoding: .utf8),
          let headerRange = raw.range(of: "\r\n\r\n") else {
      return nil
    }

    let headerText = String(raw[..<headerRange.lowerBound])
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard requestParts.count >= 2 else { return nil }

    let headerData = Data(raw[..<headerRange.upperBound].utf8)
    let body = data.dropFirst(headerData.count)
    let path = requestParts[1].components(separatedBy: "?").first ?? requestParts[1]
    return LocalProofingHTTPRequest(method: requestParts[0].uppercased(), path: path, body: Data(body))
  }

  private static func contentLength(from headerText: String) -> Int {
    for line in headerText.components(separatedBy: "\r\n") {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
        return Int(parts[1]) ?? 0
      }
    }
    return 0
  }
}

struct LocalProofingHTTPResponse: Equatable {
  let statusCode: Int
  let contentType: String
  let body: Data

  static func ok(contentType: String, body: Data) -> LocalProofingHTTPResponse {
    LocalProofingHTTPResponse(statusCode: 200, contentType: contentType, body: body)
  }

  static func notFound() -> LocalProofingHTTPResponse {
    LocalProofingHTTPResponse(
      statusCode: 404,
      contentType: "application/json",
      body: Data(#"{"error":"not_found"}"#.utf8)
    )
  }

  static func badRequest() -> LocalProofingHTTPResponse {
    LocalProofingHTTPResponse(
      statusCode: 400,
      contentType: "application/json",
      body: Data(#"{"error":"bad_request"}"#.utf8)
    )
  }

  var wireData: Data {
    var response = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
    response += "Content-Type: \(contentType)\r\n"
    response += "Content-Length: \(body.count)\r\n"
    response += "Cache-Control: no-store\r\n"
    response += "Connection: close\r\n"
    response += "Access-Control-Allow-Origin: *\r\n"
    response += "\r\n"
    var data = Data(response.utf8)
    data.append(body)
    return data
  }

  private var reasonPhrase: String {
    switch statusCode {
    case 200:
      return "OK"
    case 400:
      return "Bad Request"
    case 404:
      return "Not Found"
    default:
      return "OK"
    }
  }
}

enum LocalProofingWebRenderer {
  private struct PhotoPayload: Codable {
    let id: String
    let filename: String
    let detail: String
    let formatLabel: String
    let favorite: Bool
    let previewURL: String?
  }

  private struct PhotosPayload: Codable {
    let photos: [PhotoPayload]
  }

  static func photosJSON(photos: [LocalProofingPhoto], favoriteIDs: Set<String>) throws -> Data {
    let payload = PhotosPayload(photos: photos.map { photo in
      PhotoPayload(
        id: photo.id,
        filename: photo.filename,
        detail: photo.detail,
        formatLabel: photo.formatLabel,
        favorite: favoriteIDs.contains(photo.id),
        previewURL: photo.hasPreview ? "/preview/\(photo.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? photo.id).jpg" : nil
      )
    })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(payload)
  }

  static func favoriteUpdate(from data: Data) throws -> LocalProofingFavoriteUpdate {
    try JSONDecoder().decode(LocalProofingFavoriteUpdate.self, from: data)
  }

  static func galleryHTML(sessionToken: String) -> Data {
    Data("""
    <!doctype html>
    <html lang="zh-Hans">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <title>现场选片</title>
      <style>
        :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f2ec; color: #171511; }
        body { margin: 0; padding: 18px; }
        header { position: sticky; top: 0; z-index: 2; margin: -18px -18px 14px; padding: 14px 18px 12px; background: rgba(245,242,236,.94); backdrop-filter: blur(14px); border-bottom: 1px solid rgba(23,21,17,.08); }
        h1 { margin: 0; font-size: 20px; line-height: 1.2; }
        .meta { margin-top: 4px; font-size: 13px; color: #6f675d; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(122px, 1fr)); gap: 10px; }
        .photo { text-align: left; background: #fffaf2; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 8px rgba(23,21,17,.09); }
        .thumb { position: relative; aspect-ratio: 1; background: #ded8ce; display: grid; place-items: center; color: #80776b; font-size: 13px; }
        .thumbButton { border: 0; padding: 0; width: 100%; background: transparent; display: block; }
        .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
        .badge { position: absolute; top: 8px; right: 8px; width: 34px; height: 34px; border: 0; border-radius: 50%; display: grid; place-items: center; background: rgba(255,250,242,.9); color: #7d7569; font-size: 19px; }
        .photo.favorite .badge { background: #171511; color: #fffaf2; }
        .caption { padding: 8px; min-height: 44px; }
        .name { font-size: 12px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .detail { margin-top: 2px; font-size: 11px; color: #7a7167; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .viewer { position: fixed; inset: 0; z-index: 9; display: none; background: rgba(14,13,11,.94); color: #fffaf2; }
        .viewer.open { display: grid; grid-template-rows: auto 1fr auto; }
        .viewerTop { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: calc(12px + env(safe-area-inset-top)) 14px 10px; }
        .viewerTitle { min-width: 0; font-size: 14px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .viewerClose { border: 0; border-radius: 18px; padding: 8px 12px; background: rgba(255,250,242,.14); color: #fffaf2; font-weight: 700; }
        .viewerStage { min-height: 0; display: grid; place-items: center; overflow: hidden; touch-action: pinch-zoom; }
        .viewerStage img { max-width: 100%; max-height: 100%; object-fit: contain; }
        .viewerFooter { padding: 10px 14px calc(14px + env(safe-area-inset-bottom)); font-size: 13px; color: rgba(255,250,242,.78); }
      </style>
    </head>
    <body data-session="\(sessionToken)">
      <header>
        <h1>现场选片</h1>
        <div class="meta" id="status">正在载入照片</div>
      </header>
      <main class="grid" id="grid"></main>
      <section class="viewer" id="viewer" aria-hidden="true">
        <div class="viewerTop">
          <div class="viewerTitle" id="viewerTitle"></div>
          <button class="viewerClose" type="button" onclick="closeViewer()">关闭</button>
        </div>
        <div class="viewerStage" onclick="closeViewer()">
          <img id="viewerImage" alt="">
        </div>
        <div class="viewerFooter" id="viewerDetail"></div>
      </section>
      <script>
        const grid = document.getElementById('grid');
        const status = document.getElementById('status');
        const viewer = document.getElementById('viewer');
        const viewerImage = document.getElementById('viewerImage');
        const viewerTitle = document.getElementById('viewerTitle');
        const viewerDetail = document.getElementById('viewerDetail');
        let photos = [];

        async function loadPhotos() {
          const response = await fetch('/api/photos', { cache: 'no-store' });
          const payload = await response.json();
          photos = payload.photos || [];
          render();
        }

        function render() {
          status.textContent = `${photos.length} 张 · 已收藏 ${photos.filter(p => p.favorite).length} 张`;
          grid.innerHTML = '';
          for (const photo of photos) {
            const card = document.createElement('article');
            card.className = `photo${photo.favorite ? ' favorite' : ''}`;
            const image = photo.previewURL ? `<img src="${photo.previewURL}" alt="">` : `<span>${photo.formatLabel || 'PHOTO'}</span>`;
            card.innerHTML = `<div class="thumb"><button class="thumbButton" type="button">${image}</button><button class="badge" type="button" aria-label="收藏">${photo.favorite ? '★' : '☆'}</button></div><div class="caption"><div class="name"></div><div class="detail"></div></div>`;
            card.querySelector('.thumbButton').onclick = () => openViewer(photo);
            card.querySelector('.badge').onclick = () => toggleFavorite(photo);
            card.querySelector('.name').textContent = photo.filename;
            card.querySelector('.detail').textContent = photo.detail || photo.formatLabel || '';
            grid.appendChild(card);
          }
        }

        function openViewer(photo) {
          if (!photo.previewURL) return;
          viewerImage.src = photo.previewURL;
          viewerTitle.textContent = photo.filename;
          viewerDetail.textContent = photo.detail || photo.formatLabel || '';
          viewer.classList.add('open');
          viewer.setAttribute('aria-hidden', 'false');
        }

        function closeViewer() {
          viewer.classList.remove('open');
          viewer.setAttribute('aria-hidden', 'true');
          viewerImage.removeAttribute('src');
        }

        async function toggleFavorite(photo) {
          photo.favorite = !photo.favorite;
          render();
          try {
            const response = await fetch('/api/favorite', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: photo.id, favorite: photo.favorite })
            });
            if (!response.ok) throw new Error('favorite failed');
          } catch (error) {
            photo.favorite = !photo.favorite;
            render();
            alert('收藏失败，请确认还连接在同一个 Wi-Fi。');
          }
        }

        loadPhotos().catch(() => { status.textContent = '无法连接摄影师手机，请检查 Wi-Fi。'; });
        setInterval(() => loadPhotos().catch(() => {}), 4000);
      </script>
    </body>
    </html>
    """.utf8)
  }
}

struct LocalProofingRequestRouter {
  let sessionToken: String
  let photosProvider: () -> [LocalProofingPhoto]
  let favoriteIDsProvider: () -> Set<String>
  let previewProvider: (String) -> Data?
  let favoriteHandler: (LocalProofingFavoriteUpdate) -> Void

  func response(for request: LocalProofingHTTPRequest) -> LocalProofingHTTPResponse {
    switch (request.method, request.path) {
    case ("GET", "/s/\(sessionToken)"):
      return .ok(
        contentType: "text/html; charset=utf-8",
        body: LocalProofingWebRenderer.galleryHTML(sessionToken: sessionToken)
      )
    case ("GET", "/health"):
      return .ok(
        contentType: "application/json",
        body: Data(#"{"ok":true}"#.utf8)
      )
    case ("GET", "/api/photos"):
      do {
        return .ok(
          contentType: "application/json",
          body: try LocalProofingWebRenderer.photosJSON(
            photos: photosProvider(),
            favoriteIDs: favoriteIDsProvider()
          )
        )
      } catch {
        return .badRequest()
      }
    case ("POST", "/api/favorite"):
      do {
        let update = try LocalProofingWebRenderer.favoriteUpdate(from: request.body)
        favoriteHandler(update)
        return .ok(contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))
      } catch {
        return .badRequest()
      }
    default:
      guard request.method == "GET",
            request.path.hasPrefix("/preview/"),
            request.path.hasSuffix(".jpg") else {
        return .notFound()
      }
      let encodedID = String(request.path.dropFirst("/preview/".count).dropLast(".jpg".count))
      let id = encodedID.removingPercentEncoding ?? encodedID
      guard let data = previewProvider(id) else { return .notFound() }
      return .ok(contentType: "image/jpeg", body: data)
    }
  }
}

final class LocalProofingServer {
  private let router: LocalProofingRequestRouter
  private let queue = DispatchQueue(label: "com.camtransfer.local-proofing")
  private var listener: NWListener?
  private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

  var onStateChange: ((String) -> Void)?
  var onRequestReceived: ((String) -> Void)?
  private(set) var url: URL?

  init(router: LocalProofingRequestRouter) {
    self.router = router
  }

  func start(
    preferredPort: UInt16 = 8080,
    advertisedInterface: LocalProofingNetworkInterface? = nil
  ) throws -> URL {
    let listener = try makeListener(preferredPort: preferredPort)
    listener.stateUpdateHandler = { [weak self] state in
      self?.onStateChange?(LocalProofingServer.statusText(for: state))
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    self.listener = listener

    let port = preferredPort == 0 ? (listener.port?.rawValue ?? preferredPort) : preferredPort
    guard let startedURL = LocalProofingNetwork.url(
      interface: advertisedInterface ?? LocalProofingNetwork.currentIPv4Address(),
      port: port,
      token: router.sessionToken
    ) else {
      listener.cancel()
      throw LocalProofingServerError.noReachableLocalAddress
    }
    url = startedURL
    return startedURL
  }

  func stop() {
    activeConnections.values.forEach { $0.cancel() }
    activeConnections.removeAll()
    listener?.cancel()
    listener = nil
    url = nil
  }

  private func makeListener(preferredPort: UInt16) throws -> NWListener {
    guard preferredPort != 0 else {
      return try NWListener(using: .tcp, on: .any)
    }
    guard let port = NWEndpoint.Port(rawValue: preferredPort) else {
      return try NWListener(using: .tcp, on: .any)
    }
    return try NWListener(using: .tcp, on: port)
  }

  private func handle(_ connection: NWConnection) {
    let connectionID = ObjectIdentifier(connection)
    activeConnections[connectionID] = connection
    onRequestReceived?("收到访问：\(connection.endpoint)")
    connection.start(queue: queue)
    receiveRequest(from: connection, connectionID: connectionID, accumulatedData: Data())
  }

  private func receiveRequest(
    from connection: NWConnection,
    connectionID: ObjectIdentifier,
    accumulatedData: Data
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
      guard let self else { return }
      var requestData = accumulatedData
      if let data {
        requestData.append(data)
      }

      guard requestData.count <= 1_048_576 else {
        self.send(.badRequest(), to: connection, connectionID: connectionID)
        return
      }

      guard isComplete || LocalProofingHTTPRequest.isComplete(requestData) else {
        self.receiveRequest(
          from: connection,
          connectionID: connectionID,
          accumulatedData: requestData
        )
        return
      }

      let response: LocalProofingHTTPResponse
      if let request = LocalProofingHTTPRequest.parse(requestData) {
        response = router.response(for: request)
      } else {
        response = .badRequest()
      }

      self.send(response, to: connection, connectionID: connectionID)
    }
  }

  private func send(
    _ response: LocalProofingHTTPResponse,
    to connection: NWConnection,
    connectionID: ObjectIdentifier
  ) {
    connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
      self?.activeConnections.removeValue(forKey: connectionID)
      connection.cancel()
    })
  }

  private static func statusText(for state: NWListener.State) -> String {
    switch state {
    case .setup:
      return "服务准备中"
    case .waiting(let error):
      return "服务等待网络：\(error.localizedDescription)"
    case .ready:
      return "服务已就绪"
    case .failed(let error):
      return "服务失败：\(error.localizedDescription)"
    case .cancelled:
      return "服务已停止"
    @unknown default:
      return "服务状态未知"
    }
  }
}

enum LocalProofingServerError: LocalizedError {
  case noReachableLocalAddress

  var errorDescription: String? {
    switch self {
    case .noReachableLocalAddress:
      return "没有检测到可供客户手机访问的 Wi-Fi 地址。请让摄影师手机和客户手机连接同一个 Wi-Fi 后再打开现场选片。"
    }
  }
}

enum LocalProofingSessionToken {
  static func make() -> String {
    let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<6).compactMap { _ in alphabet.randomElement() })
  }
}

enum LocalProofingQRCode {
  static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(Data(string.utf8), forKey: "inputMessage")
    filter?.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter?.outputImage else { return nil }
    let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
    let coreImage = UIImage(cgImage: cgImage)

    let quietZone: CGFloat = 24
    let size = CGSize(
      width: coreImage.size.width + quietZone * 2,
      height: coreImage.size.height + quietZone * 2
    )
    return UIGraphicsImageRenderer(size: size).image { rendererContext in
      UIColor.white.setFill()
      rendererContext.fill(CGRect(origin: .zero, size: size))
      coreImage.draw(in: CGRect(
        x: quietZone,
        y: quietZone,
        width: coreImage.size.width,
        height: coreImage.size.height
      ))
    }
  }
}

struct LocalProofingNetworkInterface: Equatable {
  let name: String
  let address: String
}

struct LocalProofingShareEndpoint: Equatable {
  let interface: LocalProofingNetworkInterface
  let url: URL

  var label: String {
    switch interface.name {
    case "en0":
      return "同一 Wi-Fi"
    case "bridge100":
      return "iPhone 热点"
    default:
      return interface.name
    }
  }

  var hint: String {
    switch interface.name {
    case "en0":
      return "客户手机连接同一个 Wi-Fi 后扫码"
    case "bridge100":
      return "客户手机连接这台 iPhone 的个人热点后扫码"
    default:
      return "客户手机连接同一局域网后扫码"
    }
  }
}

enum LocalProofingNetwork {
  static func url(interface: LocalProofingNetworkInterface?, port: UInt16, token: String) -> URL? {
    guard let interface else { return nil }
    return URL(string: "http://\(interface.address):\(port)/s/\(token)")
  }

  static func preferredAddress(from interfaces: [LocalProofingNetworkInterface]) -> LocalProofingNetworkInterface? {
    for interfaceName in ["en0", "bridge100"] {
      if let address = interfaces.first(where: { $0.name == interfaceName })?.address,
         isPrivateIPv4Address(address) {
        return LocalProofingNetworkInterface(name: interfaceName, address: address)
      }
    }
    return nil
  }

  static func shareEndpoints(
    port: UInt16,
    token: String,
    interfaces: [LocalProofingNetworkInterface] = currentIPv4Interfaces()
  ) -> [LocalProofingShareEndpoint] {
    ["en0", "bridge100"].compactMap { interfaceName in
      guard let interface = interfaces.first(where: {
        $0.name == interfaceName && isPrivateIPv4Address($0.address)
      }),
      let url = url(interface: interface, port: port, token: token) else {
        return nil
      }
      return LocalProofingShareEndpoint(interface: interface, url: url)
    }
  }

  static func currentIPv4Address() -> LocalProofingNetworkInterface? {
    preferredAddress(from: currentIPv4Interfaces())
  }

  static func currentIPv4Interfaces() -> [LocalProofingNetworkInterface] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }

    var localInterfaces: [LocalProofingNetworkInterface] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = pointer?.pointee {
      defer { pointer = interface.ifa_next }

      guard let addressPointer = interface.ifa_addr else { continue }
      let address = addressPointer.pointee
      guard address.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: interface.ifa_name)
      guard name == "en0" || name == "bridge100" else { continue }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      var addr = address
      let result = getnameinfo(
        &addr,
        socklen_t(address.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if result == 0 {
        localInterfaces.append(LocalProofingNetworkInterface(
          name: name,
          address: String(cString: hostname)
        ))
      }
    }
    return localInterfaces
  }

  private static func isPrivateIPv4Address(_ address: String) -> Bool {
    if address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("172.20.") {
      return true
    }

    let parts = address.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 172 && (16...31).contains(parts[1])
  }
}
