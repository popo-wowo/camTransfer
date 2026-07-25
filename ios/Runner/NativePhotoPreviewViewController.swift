import Foundation
import UIKit
import Photos

final class NativeGalleryHighDefinitionPreviewModeController {
  private(set) var isActive = false
  private(set) var pendingHandles: [Int] = []
  private var orderedHandles: [Int] = []

  var hasPendingPreviews: Bool {
    !pendingHandles.isEmpty
  }

  func begin(
    orderedHandles: [Int],
    currentHandle: Int,
    alreadyLoadedHandles: Set<Int>
  ) {
    self.orderedHandles = distinct(orderedHandles)
    isActive = true
    setPending(queue(from: currentHandle, alreadyLoadedHandles: alreadyLoadedHandles))
  }

  func promoteCurrentHandle(
    _ currentHandle: Int,
    alreadyLoadedHandles: Set<Int>
  ) {
    guard isActive else { return }
    let promoted = [currentHandle] + pendingHandles.filter { $0 != currentHandle }
    let missing = queue(from: currentHandle, alreadyLoadedHandles: alreadyLoadedHandles)
      .filter { !promoted.contains($0) }
    setPending((promoted + missing).filter { !alreadyLoadedHandles.contains($0) })
  }

  func markLoaded(_ handle: Int) {
    setPending(pendingHandles.filter { $0 != handle })
  }

  func stop() {
    isActive = false
    orderedHandles = []
    setPending([])
  }

  private func queue(from currentHandle: Int, alreadyLoadedHandles: Set<Int>) -> [Int] {
    guard let currentIndex = orderedHandles.firstIndex(of: currentHandle) else {
      return alreadyLoadedHandles.contains(currentHandle) ? [] : [currentHandle]
    }
    let forward = orderedHandles[currentIndex...]
    let backward = orderedHandles[..<currentIndex]
    return (Array(forward) + Array(backward)).filter { !alreadyLoadedHandles.contains($0) }
  }

  private func setPending(_ handles: [Int]) {
    pendingHandles = distinct(handles)
  }

  private func distinct(_ handles: [Int]) -> [Int] {
    var seen: Set<Int> = []
    var result: [Int] = []
    for handle in handles where !seen.contains(handle) {
      seen.insert(handle)
      result.append(handle)
    }
    return result
  }
}

struct NativeGalleryCachedPreview {
  let data: Data
  let objectOrientation: Int?
}

final class NativeGalleryHighDefinitionPreviewCache {
  private let maxMemoryImages: Int
  private let directory: URL
  private var memory: [Int: Data] = [:]
  private var memoryOrder: [Int] = []
  private var loaded: Set<Int> = []
  private var objectOrientations: [Int: Int] = [:]

  init(
    maxMemoryImages: Int = 30,
    directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("hd-preview-cache", isDirectory: true)
  ) {
    self.maxMemoryImages = max(1, maxMemoryImages)
    self.directory = directory
  }

  var loadedHandles: Set<Int> {
    loaded
  }

  func memoryData(for handle: Int) -> Data? {
    guard let data = memory[handle] else { return nil }
    touch(handle)
    return data
  }

  func store(_ data: Data, for handle: Int, objectOrientation: Int? = nil) {
    loaded.insert(handle)
    objectOrientations[handle] = objectOrientation
    cacheInMemory(data, for: handle)
    writeToDisk(data, for: handle)
  }

  func restoreLoadedData(for handle: Int) -> Data? {
    guard loaded.contains(handle) else { return nil }
    if let data = memoryData(for: handle) {
      return data
    }
    guard let data = try? Data(contentsOf: fileURL(for: handle)) else {
      return nil
    }
    cacheInMemory(data, for: handle)
    return data
  }

  func restoreLoadedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    guard let data = restoreLoadedData(for: handle) else { return nil }
    return NativeGalleryCachedPreview(
      data: data,
      objectOrientation: objectOrientations[handle]
    )
  }

  func reset() {
    memory.removeAll()
    memoryOrder.removeAll()
    loaded.removeAll()
    objectOrientations.removeAll()
    try? FileManager.default.removeItem(at: directory)
  }

  private func cacheInMemory(_ data: Data, for handle: Int) {
    memory[handle] = data
    touch(handle)
    while memoryOrder.count > maxMemoryImages {
      let evicted = memoryOrder.removeFirst()
      memory.removeValue(forKey: evicted)
    }
  }

  private func touch(_ handle: Int) {
    memoryOrder.removeAll { $0 == handle }
    memoryOrder.append(handle)
  }

  private func writeToDisk(_ data: Data, for handle: Int) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL(for: handle), options: .atomic)
  }

  private func fileURL(for handle: Int) -> URL {
    directory.appendingPathComponent("\(handle).bin", isDirectory: false)
  }
}
@MainActor

final class NativePhotoPreviewViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
  private let items: [CameraVendorGalleryItem]
  private let runtime: CameraSessionRuntime
  private let shouldLoadPreviewThumbnail: () -> Bool
  private let cachedThumbnailImageProvider: (Int) -> UIImage?
  private let displayStateProvider: (Int) -> CameraGalleryEntryViewState?
  private let isSelected: (Int) -> Bool
  private let downloadStateProvider: (Int) -> CameraVendorDownloadState
  private let onSelectionToggle: (CameraVendorGalleryItem) -> Void
  private let onDownload: (CameraVendorGalleryItem) -> Void
  private let isTransferLocked: () -> Bool
  private let onTransferLockedDismissAttempt: () -> Void
  private let previewImageCache = NativeGalleryHighDefinitionPreviewCache()
  private var currentIndex: Int
  private var pageController: UIPageViewController!
  private var controlsHidden = false

  private let topBar: NativeGradientChromeView = {
    let view = NativeGradientChromeView(direction: .topToBottom)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = .white
    label.textAlignment = .center
    return label
  }()

  private let subtitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = UIColor.white.withAlphaComponent(0.7)
    label.textAlignment = .center
    return label
  }()

  private let closeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "关闭"
    return button
  }()

  private let rotateButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "rotate.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "向右旋转"
    return button
  }()

  private let rotateLeftButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "rotate.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "向左旋转"
    return button
  }()

  private let bottomBar: NativeGradientChromeView = {
    let view = NativeGradientChromeView(direction: .bottomToTop)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let selectionButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.accessibilityLabel = "选择当前照片"
    return button
  }()

  private let downloadButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.title = "下载原图"
    config.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
    config.imagePadding = 6
    config.cornerStyle = .capsule
    config.baseBackgroundColor = .white
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    config.attributedTitle = AttributedString("下载原图", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    button.configuration = config
    return button
  }()

  init(
    items: [CameraVendorGalleryItem],
    initialIndex: Int,
    runtime: CameraSessionRuntime,
    shouldLoadPreviewThumbnail: @escaping () -> Bool,
    cachedThumbnailImageProvider: @escaping (Int) -> UIImage?,
    displayStateProvider: @escaping (Int) -> CameraGalleryEntryViewState?,
    isSelected: @escaping (Int) -> Bool,
    downloadStateProvider: @escaping (Int) -> CameraVendorDownloadState,
    onSelectionToggle: @escaping (CameraVendorGalleryItem) -> Void,
    onDownload: @escaping (CameraVendorGalleryItem) -> Void,
    isTransferLocked: @escaping () -> Bool,
    onTransferLockedDismissAttempt: @escaping () -> Void
  ) {
    self.items = items
    self.currentIndex = min(max(initialIndex, 0), max(items.count - 1, 0))
    self.runtime = runtime
    self.shouldLoadPreviewThumbnail = shouldLoadPreviewThumbnail
    self.cachedThumbnailImageProvider = cachedThumbnailImageProvider
    self.displayStateProvider = displayStateProvider
    self.isSelected = isSelected
    self.downloadStateProvider = downloadStateProvider
    self.onSelectionToggle = onSelectionToggle
    self.onDownload = onDownload
    self.isTransferLocked = isTransferLocked
    self.onTransferLockedDismissAttempt = onTransferLockedDismissAttempt
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    setupUI()
    refreshChromeForCurrentItem()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(downloadStateChanged),
      name: .nativeDownloadStateDidChange,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .lightContent
  }

  override var prefersStatusBarHidden: Bool {
    controlsHidden
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    controlsHidden
  }

  private func setupUI() {
    view.backgroundColor = .black

    pageController = UIPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: [UIPageViewController.OptionsKey.interPageSpacing: 24]
    )
    pageController.dataSource = self
    pageController.delegate = self
    addChild(pageController)
    view.addSubview(pageController.view)
    pageController.view.translatesAutoresizingMaskIntoConstraints = false
    pageController.didMove(toParent: self)

    if items.indices.contains(currentIndex) {
      let initialPage = makePage(for: currentIndex)
      pageController.setViewControllers([initialPage], direction: .forward, animated: false)
    }

    view.addSubview(topBar)
    topBar.addSubview(closeButton)
    topBar.addSubview(titleLabel)
    topBar.addSubview(subtitleLabel)

    view.addSubview(bottomBar)
    bottomBar.addSubview(selectionButton)
    bottomBar.addSubview(rotateLeftButton)
    bottomBar.addSubview(rotateButton)
    bottomBar.addSubview(downloadButton)

    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    rotateLeftButton.addTarget(self, action: #selector(rotateLeftTapped), for: .touchUpInside)
    rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
    downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    tap.cancelsTouchesInView = false
    pageController.view.addGestureRecognizer(tap)

    NSLayoutConstraint.activate([
      pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
      pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),

      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
      closeButton.widthAnchor.constraint(equalToConstant: 36),
      closeButton.heightAnchor.constraint(equalToConstant: 36),

      titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -2),

      subtitleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
      subtitleLabel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -68),

      selectionButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 22),
      selectionButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 14),
      selectionButton.widthAnchor.constraint(equalToConstant: 44),
      selectionButton.heightAnchor.constraint(equalToConstant: 44),

      rotateLeftButton.leadingAnchor.constraint(equalTo: selectionButton.trailingAnchor, constant: 12),
      rotateLeftButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      rotateLeftButton.widthAnchor.constraint(equalToConstant: 40),
      rotateLeftButton.heightAnchor.constraint(equalToConstant: 40),

      rotateButton.leadingAnchor.constraint(equalTo: rotateLeftButton.trailingAnchor, constant: 8),
      rotateButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      rotateButton.widthAnchor.constraint(equalToConstant: 40),
      rotateButton.heightAnchor.constraint(equalToConstant: 40),

      downloadButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -18),
      downloadButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      downloadButton.leadingAnchor.constraint(greaterThanOrEqualTo: rotateButton.trailingAnchor, constant: 12),
    ])
  }

  private func makePage(for index: Int) -> NativePhotoPreviewPageController {
    let item = items[index]
    return NativePhotoPreviewPageController(
      item: item,
      index: index,
      runtime: runtime,
      cachedThumbnailImage: cachedThumbnailImageProvider(item.handle),
      canDismiss: { [weak self] in
        guard let self else { return true }
        return NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: self.isTransferLocked())
      },
      shouldLoadPreviewThumbnail: shouldLoadPreviewThumbnail,
      onDismissDrag: { [weak self] progress in
        self?.applyDismissDragProgress(progress)
      },
      onDismissBlocked: { [weak self] in
        self?.onTransferLockedDismissAttempt()
      },
      onDismissCommit: { [weak self] in
        self?.dismissPreview()
      },
      onDismissCancel: { [weak self] in
        self?.applyDismissDragProgress(0)
      },
      previewImageDataProvider: { [weak self] handle in
        self?.previewImageCache.restoreLoadedPreview(for: handle)
      },
      onPreviewImageDataLoaded: { [weak self] handle, data, orientation in
        self?.previewImageCache.store(data, for: handle, objectOrientation: orientation)
      }
    )
  }

  private func applyDismissDragProgress(_ progress: CGFloat) {
    let clamped = max(0, min(1, progress))
    view.backgroundColor = UIColor.black.withAlphaComponent(1 - clamped * 0.65)
    topBar.alpha = 1 - clamped
    bottomBar.alpha = 1 - clamped
  }

  private func refreshChromeForCurrentItem() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    titleLabel.text = item.filename
    subtitleLabel.text = NativeGalleryFormatDisplayPolicy.previewSubtitle(
      index: currentIndex,
      total: items.count,
      item: item,
      viewState: displayStateProvider(item.handle)
    )
    let state = downloadStateProvider(item.handle)
    configureDownloadButton(for: item, state: state)
    updateSelectionButton(for: item)
    updateCloseButton()
  }

  private func configureDownloadButton(for item: CameraVendorGalleryItem, state: CameraVendorDownloadState) {
    guard CameraVendorGalleryDownloadPolicy.canDownloadOriginal(item) else {
      downloadButton.configuration?.attributedTitle = AttributedString("暂不支持", attributes: AttributeContainer([
        .font: UIFont.systemFont(ofSize: 13, weight: .bold)
      ]))
      downloadButton.isEnabled = false
      downloadButton.alpha = 0.55
      return
    }
    let title: String
    let enabled: Bool
    switch state {
    case .idle:
      title = "下载原图"; enabled = true
    case .queued:
      title = "下载列表中"; enabled = false
    case .downloading:
      title = "下载中…"; enabled = false
    case .saved:
      title = "已保存"; enabled = false
    case .failed:
      title = "重试下载"; enabled = true
    }
    downloadButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    downloadButton.isEnabled = enabled
    downloadButton.alpha = enabled ? 1 : 0.62
  }

  private func updateSelectionButton(for item: CameraVendorGalleryItem) {
    let canSelect = NativeGalleryDownloadSelectionPolicy.canSelect(
      downloadState: downloadStateProvider(item.handle)
    )
    let symbol = isSelected(item.handle) ? "checkmark.circle.fill" : "circle"
    let configuration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
    selectionButton.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
    selectionButton.isEnabled = canSelect
    selectionButton.alpha = canSelect ? 1 : 0.45
  }

  private func updateCloseButton() {
    let canDismiss = NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: isTransferLocked())
    closeButton.isEnabled = canDismiss
    closeButton.alpha = canDismiss ? 1 : 0.35
  }

  @objc private func toggleControls() {
    controlsHidden.toggle()
    UIView.animate(withDuration: 0.22) {
      self.topBar.alpha = self.controlsHidden ? 0 : 1
      self.bottomBar.alpha = self.controlsHidden ? 0 : 1
      self.setNeedsStatusBarAppearanceUpdate()
      self.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }

  private func dismissPreview() {
    guard NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: isTransferLocked()) else {
      onTransferLockedDismissAttempt()
      return
    }
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  @objc private func closeTapped() {
    dismissPreview()
  }

  @objc private func selectionTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    onSelectionToggle(item)
    updateSelectionButton(for: item)
  }

  @objc private func rotateLeftTapped() {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    page.rotateCounterClockwise()
  }

  @objc private func rotateTapped() {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    page.rotateClockwise()
  }

  @objc private func downloadTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    guard CameraVendorGalleryDownloadPolicy.canDownloadOriginal(item),
          NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: downloadStateProvider(item.handle)) else {
      return
    }
    cancelPreviewThumbnailLoads()
    onDownload(item)
    refreshChromeForCurrentItem()
  }

  @objc private func downloadStateChanged() {
    refreshChromeForCurrentItem()
  }

  private func cancelPreviewThumbnailLoads() {
    for controller in pageController.viewControllers ?? [] {
      (controller as? NativePhotoPreviewPageController)?.cancelThumbnailLoadForPriorityDownload()
    }
  }

  // MARK: - UIPageViewControllerDataSource

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativePhotoPreviewPageController else { return nil }
    let prev = page.index - 1
    guard items.indices.contains(prev) else { return nil }
    return makePage(for: prev)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativePhotoPreviewPageController else { return nil }
    let next = page.index + 1
    guard items.indices.contains(next) else { return nil }
    return makePage(for: next)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]
  ) {
    guard let page = pendingViewControllers.first as? NativePhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChromeForCurrentItem()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChromeForCurrentItem()
  }
}

final class NativePhotoPreviewPageController: UIViewController, UIScrollViewDelegate {
  let index: Int
  let item: CameraVendorGalleryItem
  private let runtime: CameraSessionRuntime
  private let cachedThumbnailImage: UIImage?
  private let canDismiss: () -> Bool
  private let shouldLoadPreviewThumbnail: () -> Bool
  private let onDismissDrag: (CGFloat) -> Void
  private let onDismissBlocked: () -> Void
  private let onDismissCommit: () -> Void
  private let onDismissCancel: () -> Void
  private let previewImageDataProvider: (Int) -> NativeGalleryCachedPreview?
  private let onPreviewImageDataLoaded: (Int, Data, Int?) -> Void
  private var loadTask: Task<Void, Never>?

  private let scrollView: UIScrollView = {
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 4
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.bouncesZoom = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.alwaysBounceVertical = false
    scroll.alwaysBounceHorizontal = false
    return scroll
  }()

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    view.isUserInteractionEnabled = true
    view.clipsToBounds = true
    return view
  }()

  private let placeholderView: UIImageView = {
    let view = UIImageView(image: UIImage(systemName: "photo"))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.tintColor = UIColor.white.withAlphaComponent(0.18)
    view.contentMode = .center
    return view
  }()

  private let spinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = .white
    spinner.hidesWhenStopped = true
    return spinner
  }()

  private var imageWidthConstraint: NSLayoutConstraint?
  private var imageHeightConstraint: NSLayoutConstraint?
  private var dismissStartTransform: CGAffineTransform = .identity
  private var sourceImage: UIImage?
  private var sourceImageData: Data?
  private var appliedObjectOrientation: Int?
  private var runtimePresentationObserverID: UUID?
  private var manualRotationDegrees = 0

  init(
    item: CameraVendorGalleryItem,
    index: Int,
    runtime: CameraSessionRuntime,
    cachedThumbnailImage: UIImage?,
    canDismiss: @escaping () -> Bool,
    shouldLoadPreviewThumbnail: @escaping () -> Bool,
    onDismissDrag: @escaping (CGFloat) -> Void,
    onDismissBlocked: @escaping () -> Void,
    onDismissCommit: @escaping () -> Void,
    onDismissCancel: @escaping () -> Void,
    previewImageDataProvider: @escaping (Int) -> NativeGalleryCachedPreview?,
    onPreviewImageDataLoaded: @escaping (Int, Data, Int?) -> Void
  ) {
    self.item = item
    self.index = index
    self.runtime = runtime
    self.cachedThumbnailImage = cachedThumbnailImage
    self.canDismiss = canDismiss
    self.shouldLoadPreviewThumbnail = shouldLoadPreviewThumbnail
    self.onDismissDrag = onDismissDrag
    self.onDismissBlocked = onDismissBlocked
    self.onDismissCommit = onDismissCommit
    self.onDismissCancel = onDismissCancel
    self.previewImageDataProvider = previewImageDataProvider
    self.onPreviewImageDataLoaded = onPreviewImageDataLoaded
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    loadTask?.cancel()
    if let runtimePresentationObserverID {
      Task { @MainActor [runtime] in
        runtime.removeObserver(runtimePresentationObserverID)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.addSubview(placeholderView)
    view.addSubview(scrollView)
    view.addSubview(spinner)
    scrollView.addSubview(imageView)
    scrollView.delegate = self

    let widthC = imageView.widthAnchor.constraint(equalToConstant: 0)
    let heightC = imageView.heightAnchor.constraint(equalToConstant: 0)
    imageWidthConstraint = widthC
    imageHeightConstraint = heightC

    NSLayoutConstraint.activate([
      placeholderView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      placeholderView.widthAnchor.constraint(equalToConstant: 80),
      placeholderView.heightAnchor.constraint(equalToConstant: 80),

      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      widthC,
      heightC,

      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    pan.delegate = self
    scrollView.addGestureRecognizer(pan)

    runtimePresentationObserverID = runtime.observe { [weak self] presentation in
      self?.applyLateObjectOrientation(from: presentation.catalog)
    }

    loadImage()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    if let image = imageView.image, sourceImage != nil {
      layout(image: image)
    } else {
      centerImage()
    }
  }

  private func loadImage() {
    if let data = item.thumbnailData,
       let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: item.orientation) {
      setSourceImage(image, imageData: data, objectOrientation: item.orientation)
    } else if let image = NativePhotoPreviewInitialImagePolicy.initialImage(
      item: item,
      cachedThumbnailImage: cachedThumbnailImage
    ) {
      setSourceImage(image)
    } else {
      spinner.startAnimating()
    }
    if let cachedPreview = previewImageDataProvider(item.handle),
       let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: cachedPreview.data,
        objectOrientation: cachedPreview.objectOrientation ?? item.orientation
       ) {
      setSourceImage(
        image,
        imageData: cachedPreview.data,
        objectOrientation: cachedPreview.objectOrientation ?? item.orientation
      )
      spinner.stopAnimating()
      return
    }
    guard loadTask == nil else { return }
    guard shouldLoadPreviewThumbnail() else {
      spinner.stopAnimating()
      return
    }
    loadTask = Task { [weak self] in
      guard let self else { return }
      guard self.shouldLoadPreviewThumbnail() else {
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
        return
      }
      do {
        var hasLoadedPreviewImage = false
        if let cachedPreview = self.previewImageDataProvider(self.item.handle),
           let image = CameraVendorGalleryThumbnailRenderer.decoded(
            from: cachedPreview.data,
            objectOrientation: cachedPreview.objectOrientation ?? self.item.orientation
           ) {
          hasLoadedPreviewImage = true
          await MainActor.run {
            self.setSourceImage(
              image,
              imageData: cachedPreview.data,
              objectOrientation: cachedPreview.objectOrientation ?? self.item.orientation
            )
          }
        }
        if NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
          item: item,
          hasPreviewImage: false,
          hasLoadedPreviewData: hasLoadedPreviewImage
        ) {
          let preview = try await runtime.requestPreviewImageWithInfo(for: item.handle)
          if Task.isCancelled { return }
          let data = preview.data
          let previewOrientation = preview.item?.orientation ?? item.orientation
          let image = CameraVendorGalleryThumbnailRenderer.decoded(
            from: data,
            objectOrientation: previewOrientation
          )
          if let image {
            hasLoadedPreviewImage = true
            onPreviewImageDataLoaded(item.handle, data, previewOrientation)
            await MainActor.run {
              self.setSourceImage(image, imageData: data, objectOrientation: previewOrientation)
            }
          }
        }
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
      } catch {
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
      }
    }
  }

  func cancelThumbnailLoadForPriorityDownload() {
    loadTask?.cancel()
    loadTask = nil
    spinner.stopAnimating()
  }

  func rotateClockwise() {
    guard sourceImage != nil else { return }
    manualRotationDegrees = NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(manualRotationDegrees)
    renderSourceImage()
  }

  func rotateCounterClockwise() {
    guard sourceImage != nil else { return }
    manualRotationDegrees = NativePhotoPreviewRotationPolicy.previousManualRotationDegrees(manualRotationDegrees)
    renderSourceImage()
  }

  private func setSourceImage(
    _ image: UIImage,
    imageData: Data? = nil,
    objectOrientation: Int? = nil
  ) {
    sourceImage = image
    if let imageData {
      sourceImageData = imageData
      appliedObjectOrientation = objectOrientation
    }
    renderSourceImage()
  }

  private func applyLateObjectOrientation(from presentation: CameraGalleryPresentation) {
    guard let updatedItem = presentation.items.first(where: {
      $0.handle == item.handle
    }),
      let data = sourceImageData,
      NativePhotoPreviewOrientationRefreshPolicy.shouldRerender(
        previousObjectOrientation: appliedObjectOrientation,
        updatedObjectOrientation: updatedItem.orientation,
        hasLoadedImageData: true
      ),
      let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: data,
        objectOrientation: updatedItem.orientation
      ) else {
      return
    }
    setSourceImage(image, imageData: data, objectOrientation: updatedItem.orientation)
    CameraVendorFileLogger.log(
      "[ORIENTATION_PREVIEW] rerendered handle=\(item.handle) orientation=\(updatedItem.orientation!) reason=late-object-info"
    )
  }

  private func renderSourceImage() {
    guard let sourceImage else { return }
    let image = NativePhotoPreviewImageRenderer.rendered(
      image: sourceImage,
      manualRotationDegrees: manualRotationDegrees
    )
    imageView.image = image
    placeholderView.isHidden = true
    layout(image: image)
  }

  private func layout(image: UIImage) {
    let bounds = view.bounds.size
    guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let displaySize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    imageWidthConstraint?.constant = displaySize.width
    imageHeightConstraint?.constant = displaySize.height
    scrollView.zoomScale = 1
    scrollView.layoutIfNeeded()
    centerImage()
  }

  private func centerImage() {
    let scrollSize = scrollView.bounds.size
    let contentSize = scrollView.contentSize
    let horizontalInset = max(0, (scrollSize.width - contentSize.width) / 2)
    let verticalInset = max(0, (scrollSize.height - contentSize.height) / 2)
    scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    if scrollView.zoomScale > scrollView.minimumZoomScale {
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
    } else {
      let location = gesture.location(in: imageView)
      let zoom: CGFloat = 2.5
      let width = scrollView.bounds.width / zoom
      let height = scrollView.bounds.height / zoom
      let rect = CGRect(x: location.x - width / 2, y: location.y - height / 2, width: width, height: height)
      scrollView.zoom(to: rect, animated: true)
    }
  }

  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
    guard canDismiss() else {
      if gesture.state == .began {
        onDismissBlocked()
      }
      onDismissCancel()
      return
    }
    let translation = gesture.translation(in: view)
    switch gesture.state {
    case .began:
      dismissStartTransform = imageView.transform
    case .changed:
      let progress = max(0, translation.y) / max(view.bounds.height, 1)
      let scale = max(0.6, 1 - progress * 0.4)
      imageView.transform = CGAffineTransform(translationX: translation.x, y: translation.y).scaledBy(x: scale, y: scale)
      onDismissDrag(progress)
    case .ended, .cancelled:
      let progress = max(0, translation.y) / max(view.bounds.height, 1)
      let velocity = gesture.velocity(in: view).y
      if progress > 0.18 || velocity > 900 {
        UIView.animate(withDuration: 0.22, animations: {
          self.imageView.transform = CGAffineTransform(translationX: translation.x, y: self.view.bounds.height).scaledBy(x: 0.5, y: 0.5)
          self.imageView.alpha = 0
          self.onDismissDrag(1)
        }, completion: { _ in self.onDismissCommit() })
      } else {
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4, animations: {
          self.imageView.transform = self.dismissStartTransform
          self.onDismissDrag(0)
        })
        onDismissCancel()
      }
    default:
      break
    }
  }

  // MARK: - UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
  }
}

extension NativePhotoPreviewPageController: UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: view)
    if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 { return false }
    return abs(velocity.y) > abs(velocity.x) * 1.2
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
}

enum CameraVendorPhotoLibrarySaver {
  static func save(
    file: CameraVendorDownloadedFile,
    commitGate: CameraSessionRuntimeTransferCommitGate,
    onPhotoLibraryCommit: @escaping @MainActor () -> Void
  ) async throws {
    guard commitGate.allowsPhotoLibraryCommit else {
      throw CancellationError()
    }
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let status: PHAuthorizationStatus
    if current == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    } else {
      status = current
    }

    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "CameraVendorPhotoLibrarySaver",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
      )
    }

    guard commitGate.allowsPhotoLibraryCommit else {
      throw CancellationError()
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        guard commitGate.beginPhotoLibraryCommit() else { return }
        switch file.mediaType {
        case .photo, .raw:
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = file.filename
          if CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
            filename: file.filename,
            mediaType: file.mediaType
          ), let data = try? Data(contentsOf: file.fileURL) {
            request.addResource(
              with: .photo,
              data: CameraVendorImageDataNormalizer.imageData(from: data),
              options: options
            )
          } else {
            request.addResource(with: .photo, fileURL: file.fileURL, options: options)
          }
        case .video:
          _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.fileURL)
        }
      }) { success, error in
        try? FileManager.default.removeItem(at: file.fileURL)
        guard commitGate.didBeginPhotoLibraryCommit else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          Task { @MainActor in
            onPhotoLibraryCommit()
            continuation.resume()
          }
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "CameraVendorPhotoLibrarySaver",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "保存文件失败"]
            )
          )
        }
      }
    }
  }

  static func save(data: Data, filename: String) async throws {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let status: PHAuthorizationStatus
    if current == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    } else {
      status = current
    }

    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "CameraVendorPhotoLibrarySaver",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
      )
    }

    // Skip the disk round-trip: write data directly into the photo asset
    // via `addResource(with:data:)` instead of temp-file → asset import.
    // For a 30 MB JPG this saves ~150-300 ms of synchronous I/O per save.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = filename
        request.addResource(with: .photo, data: data, options: options)
      }) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "CameraVendorPhotoLibrarySaver",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "保存照片失败"]
            )
          )
        }
      }
    }
  }
}
