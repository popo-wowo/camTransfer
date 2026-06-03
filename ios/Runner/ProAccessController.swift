import StoreKit
import UIKit

struct CamTransferProPaywallConfiguration {
  var trialText: String = "7 天免费试用"
  var freePlanText: String = "试用后每天 20 张 JPG"
  var monthlyPriceText: String = "¥6/月"
  var lifetimePriceText: String = "¥50"
  var lifetimeValueText: String = "约 9 个月回本"
  var featuredPlanID: String = "lifetime"
}

enum CamTransferProPurchaseOption: CaseIterable {
  case monthly
  case lifetime

  var productID: String {
    switch self {
    case .monthly:
      return "com.camtransfer.app.pro.monthly"
    case .lifetime:
      return "com.camtransfer.app.pro.lifetime"
    }
  }

  var fallbackPriceText: String {
    switch self {
    case .monthly:
      return CamTransferProAccessController.shared.configuration.monthlyPriceText
    case .lifetime:
      return CamTransferProAccessController.shared.configuration.lifetimePriceText
    }
  }
}

enum CamTransferProRestrictionReason {
  case nonJPG
  case tooManyFiles(limit: Int)
  case dailyLimitReached(limit: Int)

  var title: String {
    switch self {
    case .nonJPG:
      return "原图格式需要 Pro"
    case .tooManyFiles:
      return "批量导出需要 Pro"
    case .dailyLimitReached:
      return "今天的免费额度已用完"
    }
  }

  var message: String {
    switch self {
    case .nonJPG:
      return "免费版每天可导出 20 张 JPG。RAW、HEIF、原图和批量导出可升级 Pro 解锁。"
    case .tooManyFiles(let limit):
      return "免费版每天最多导出 \(limit) 张 JPG。升级 Pro 后不限张数。"
    case .dailyLimitReached(let limit):
      return "免费版每天可导出 \(limit) 张 JPG。明天可继续免费导出，或现在升级 Pro。"
    }
  }
}

final class CamTransferProAccessController {
  static let shared = CamTransferProAccessController()

  private let proUnlockedKey = "camtransfer.pro.unlocked.v1"
  private let dailyUsageKey = "camtransfer.pro.freeDailyUsage.v1"
  private let trialStartDateKey = "camtransfer.pro.trialStartDate.v1"
  private let calendar = Calendar(identifier: .gregorian)

  var configuration = CamTransferProPaywallConfiguration()
  let freeDailyJPGDownloadLimit = 20
  let freeTrialLengthDays = 7

  var isProUnlocked: Bool {
    get { UserDefaults.standard.bool(forKey: proUnlockedKey) }
    set { UserDefaults.standard.set(newValue, forKey: proUnlockedKey) }
  }

  private init() {}

  func restriction(for items: [CameraVendorGalleryItem], now: Date = Date()) -> CamTransferProRestrictionReason? {
    guard !isProUnlocked else { return nil }
    guard !isTrialActive(now: now) else { return nil }
    guard !items.isEmpty else { return nil }
    if items.contains(where: { $0.formatLabel.uppercased() != "JPG" }) {
      return .nonJPG
    }
    let remaining = remainingFreeJPGDownloads(now: now)
    if remaining <= 0 {
      return .dailyLimitReached(limit: freeDailyJPGDownloadLimit)
    }
    if items.count > remaining {
      return .tooManyFiles(limit: freeDailyJPGDownloadLimit)
    }
    return nil
  }

  func registerFreeDownloads(items: [CameraVendorGalleryItem], now: Date = Date()) {
    guard !isProUnlocked else { return }
    guard !isTrialActive(now: now) else { return }
    let jpgCount = items.filter { $0.formatLabel.uppercased() == "JPG" }.count
    guard jpgCount > 0 else { return }
    var usage = dailyUsage(now: now)
    usage.count += jpgCount
    saveDailyUsage(usage)
  }

  func remainingFreeJPGDownloads(now: Date = Date()) -> Int {
    max(0, freeDailyJPGDownloadLimit - dailyUsage(now: now).count)
  }

  func isTrialActive(now: Date = Date()) -> Bool {
    let startDate = trialStartDate(now: now)
    guard let endDate = calendar.date(byAdding: .day, value: freeTrialLengthDays, to: startDate) else {
      return false
    }
    return now < endDate
  }

  func trialDaysRemaining(now: Date = Date()) -> Int {
    let startDate = trialStartDate(now: now)
    guard let endDate = calendar.date(byAdding: .day, value: freeTrialLengthDays, to: startDate) else {
      return 0
    }
    let remaining = calendar.dateComponents([.day], from: now, to: endDate).day ?? 0
    return max(0, min(freeTrialLengthDays, remaining + 1))
  }

  #if DEBUG
  func resetForTesting() {
    UserDefaults.standard.removeObject(forKey: proUnlockedKey)
    UserDefaults.standard.removeObject(forKey: dailyUsageKey)
    UserDefaults.standard.removeObject(forKey: trialStartDateKey)
  }

  func setTrialStartDateForTesting(_ date: Date) {
    UserDefaults.standard.set(date, forKey: trialStartDateKey)
  }
  #endif

  private func trialStartDate(now: Date) -> Date {
    if let date = UserDefaults.standard.object(forKey: trialStartDateKey) as? Date {
      return date
    }
    UserDefaults.standard.set(now, forKey: trialStartDateKey)
    return now
  }

  private func dailyUsage(now: Date) -> DailyUsage {
    let dateKey = Self.dayKey(for: now, calendar: calendar)
    guard let raw = UserDefaults.standard.dictionary(forKey: dailyUsageKey),
          raw["date"] as? String == dateKey,
          let count = raw["count"] as? Int else {
      return DailyUsage(date: dateKey, count: 0)
    }
    return DailyUsage(date: dateKey, count: count)
  }

  private func saveDailyUsage(_ usage: DailyUsage) {
    UserDefaults.standard.set(["date": usage.date, "count": usage.count], forKey: dailyUsageKey)
  }

  private static func dayKey(for date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
  }
}

private struct DailyUsage {
  var date: String
  var count: Int
}

enum CamTransferProStoreError: LocalizedError {
  case productUnavailable
  case pendingApproval
  case unverifiedTransaction

  var errorDescription: String? {
    switch self {
    case .productUnavailable:
      return "暂时无法连接 App Store 商品。请确认内购商品已在 App Store Connect 配置，或稍后再试。"
    case .pendingApproval:
      return "购买正在等待确认。完成确认后，Pro 会自动解锁。"
    case .unverifiedTransaction:
      return "App Store 没有返回可验证的购买凭证。请稍后重试或使用恢复购买。"
    }
  }
}

final class CamTransferProStore {
  static let shared = CamTransferProStore(access: .shared)

  private let access: CamTransferProAccessController
  private var transactionUpdatesTask: Task<Void, Never>?
  private(set) var productsByID: [String: Product] = [:]

  init(access: CamTransferProAccessController) {
    self.access = access
    transactionUpdatesTask = Task { [weak self] in
      await self?.listenForTransactionUpdates()
    }
  }

  deinit {
    transactionUpdatesTask?.cancel()
  }

  var productIDs: [String] {
    CamTransferProPurchaseOption.allCases.map(\.productID)
  }

  func loadProducts() async throws -> [Product] {
    let products = try await Product.products(for: productIDs)
    productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
    return productIDs.compactMap { productsByID[$0] }
  }

  func product(for option: CamTransferProPurchaseOption) async throws -> Product {
    if let product = productsByID[option.productID] {
      return product
    }
    _ = try await loadProducts()
    guard let product = productsByID[option.productID] else {
      throw CamTransferProStoreError.productUnavailable
    }
    return product
  }

  @discardableResult
  func purchase(_ option: CamTransferProPurchaseOption) async throws -> Bool {
    let product = try await product(for: option)
    let result = try await product.purchase()
    switch result {
    case .success(let verificationResult):
      let transaction = try verifiedTransaction(from: verificationResult)
      apply(transaction: transaction)
      await transaction.finish()
      return true
    case .userCancelled:
      return false
    case .pending:
      throw CamTransferProStoreError.pendingApproval
    @unknown default:
      return false
    }
  }

  @discardableResult
  func restorePurchases() async throws -> Bool {
    try await AppStore.sync()
    return await refreshPurchasedEntitlements()
  }

  @discardableResult
  func refreshPurchasedEntitlements() async -> Bool {
    var hasActiveProEntitlement = false
    for await verificationResult in Transaction.currentEntitlements {
      guard let transaction = try? verifiedTransaction(from: verificationResult) else {
        continue
      }
      if isActiveProTransaction(transaction) {
        hasActiveProEntitlement = true
      }
    }
    access.isProUnlocked = hasActiveProEntitlement
    return hasActiveProEntitlement
  }

  private func listenForTransactionUpdates() async {
    for await verificationResult in Transaction.updates {
      guard let transaction = try? verifiedTransaction(from: verificationResult) else {
        continue
      }
      apply(transaction: transaction)
      await transaction.finish()
    }
  }

  private func verifiedTransaction(from result: VerificationResult<Transaction>) throws -> Transaction {
    switch result {
    case .verified(let transaction):
      return transaction
    case .unverified:
      throw CamTransferProStoreError.unverifiedTransaction
    }
  }

  private func apply(transaction: Transaction) {
    guard productIDs.contains(transaction.productID) else { return }
    access.isProUnlocked = isActiveProTransaction(transaction)
  }

  private func isActiveProTransaction(_ transaction: Transaction, now: Date = Date()) -> Bool {
    guard productIDs.contains(transaction.productID) else { return false }
    guard transaction.revocationDate == nil else { return false }
    if let expirationDate = transaction.expirationDate {
      return expirationDate > now
    }
    return true
  }
}

extension UIViewController {
  func presentCamTransferPaywall(reason: CamTransferProRestrictionReason? = nil) {
    let controller = CamTransferPaywallViewController(reason: reason)
    controller.modalPresentationStyle = .pageSheet
    if let sheet = controller.sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    present(controller, animated: true)
  }
}
