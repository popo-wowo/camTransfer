import Foundation

final class CameraGalleryFilterStateStore {
  private let defaults: UserDefaults
  private let keyPrefix: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "camtransfer.gallery.filter."
  ) {
    self.defaults = defaults
    self.keyPrefix = keyPrefix
  }

  func load(for identity: CameraSessionIdentity) -> CameraGalleryFilterIntent {
    guard let data = defaults.data(forKey: key(for: identity)),
          let state = try? decoder.decode(CameraGalleryFilterIntent.self, from: data) else {
      return .all
    }
    return state
  }

  func save(_ state: CameraGalleryFilterIntent, for identity: CameraSessionIdentity) {
    guard let data = try? encoder.encode(state) else { return }
    defaults.set(data, forKey: key(for: identity))
  }

  private func key(for identity: CameraSessionIdentity) -> String {
    keyPrefix + identity.historyKey
  }
}
