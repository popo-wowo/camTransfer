import Foundation
import UIKit

struct NativeGalleryHDFullScreenContext {
  let catalogIdentity: CameraGalleryCatalogIdentity
  let orderedItems: [CameraVendorGalleryItem]
  let initialHandle: Int
}

@MainActor
final class NativeGalleryHDFullScreenViewController: UIViewController,
  UIPageViewControllerDataSource,
  UIPageViewControllerDelegate {
  private let context: NativeGalleryHDFullScreenContext
  private let runtime: CameraSessionRuntime
  private let cachedThumbnailImageProvider: (Int) -> UIImage?
  private let onClosed: (Int, CameraGalleryCatalogIdentity) -> Void
  private var currentIndex: Int
  private var pageController: UIPageViewController!
  private var previewObserverID: UUID?
  private var hasReportedClose = false
  private let pageControllers = NSHashTable<NativeGalleryHDFullScreenPageController>.weakObjects()

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
    label.textColor = UIColor.white.withAlphaComponent(0.72)
    label.textAlignment = .center
    return label
  }()

  private let closeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
      ),
      for: .normal
    )
    button.accessibilityLabel = "关闭"
    return button
  }()

  init(
    context: NativeGalleryHDFullScreenContext,
    runtime: CameraSessionRuntime,
    cachedThumbnailImageProvider: @escaping (Int) -> UIImage?,
    onClosed: @escaping (Int, CameraGalleryCatalogIdentity) -> Void
  ) {
    self.context = context
    self.runtime = runtime
    self.cachedThumbnailImageProvider = cachedThumbnailImageProvider
    self.onClosed = onClosed
    self.currentIndex = context.orderedItems.firstIndex(where: {
      $0.handle == context.initialHandle
    }) ?? 0
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    setupPageController()
    setupChrome()
    refreshChrome()
    previewObserverID = runtime.observeGalleryPreview { [weak self] publication in
      guard let self else { return }
      switch publication {
      case .state(let identity, _):
        guard identity == self.context.catalogIdentity else { return }
      case .preview(let mediaIdentity, _):
        guard mediaIdentity.catalog == self.context.catalogIdentity else { return }
      }
      self.refreshCurrentPageFromCache()
    }
    focusPipelineOnCurrentHandle()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
      reportClosedIfNeeded()
    }
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    let currentPage = pageController.viewControllers?.first as? NativeGalleryHDFullScreenPageController
    for page in pageControllers.allObjects {
      if page === currentPage {
        page.releaseNativeDecodeForMemoryWarning()
      } else {
        page.releaseFitDecodeForMemoryWarning()
      }
    }
  }

  deinit {
    let observerID = previewObserverID
    let runtime = runtime
    Task { @MainActor in
      if let observerID {
        runtime.removeObserver(observerID)
      }
    }
  }

  private var currentHandle: Int {
    guard context.orderedItems.indices.contains(currentIndex) else {
      return context.initialHandle
    }
    return context.orderedItems[currentIndex].handle
  }

  private func setupPageController() {
    pageController = UIPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: [UIPageViewController.OptionsKey.interPageSpacing: 20]
    )
    pageController.dataSource = self
    pageController.delegate = self
    addChild(pageController)
    view.addSubview(pageController.view)
    pageController.view.translatesAutoresizingMaskIntoConstraints = false
    pageController.didMove(toParent: self)

    if context.orderedItems.indices.contains(currentIndex) {
      let page = makePage(index: currentIndex)
      page.setDisplayedPage(true)
      pageController.setViewControllers([page], direction: .forward, animated: false)
    }

    NSLayoutConstraint.activate([
      pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
      pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupChrome() {
    let topBar = NativeGradientChromeView(direction: .topToBottom)
    topBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(topBar)
    topBar.addSubview(closeButton)
    topBar.addSubview(titleLabel)
    topBar.addSubview(subtitleLabel)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
      closeButton.widthAnchor.constraint(equalToConstant: 36),
      closeButton.heightAnchor.constraint(equalToConstant: 36),
      titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -2),
      subtitleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      subtitleLabel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
    ])
  }

  private func makePage(index: Int) -> NativeGalleryHDFullScreenPageController {
    let item = context.orderedItems[index]
    let page = NativeGalleryHDFullScreenPageController(
      item: item,
      index: index,
      cachedThumbnailImage: cachedThumbnailImageProvider(item.handle),
      cachedPreviewProvider: { [weak self] handle in
        guard let self,
              self.runtime.galleryCatalogIdentity == self.context.catalogIdentity else { return nil }
        return self.runtime.cachedGalleryHDPreview(for: handle)
      }
    )
    pageControllers.add(page)
    return page
  }

  private func refreshCurrentPageFromCache() {
    guard runtime.galleryCatalogIdentity == context.catalogIdentity else { return }
    (pageController.viewControllers?.first as? NativeGalleryHDFullScreenPageController)?
      .refreshFromCache()
  }

  private func focusPipelineOnCurrentHandle() {
    guard runtime.galleryCatalogIdentity == context.catalogIdentity else { return }
    CameraVendorFileLogger.log(
      "[OBS] HD_FULLSCREEN_PAGE_SETTLED handle=0x\(String(format: "%08X", currentHandle))"
    )
    runtime.focusGalleryHDFullScreen(handle: currentHandle)
  }

  private func refreshChrome() {
    guard context.orderedItems.indices.contains(currentIndex) else { return }
    let item = context.orderedItems[currentIndex]
    titleLabel.text = item.filename
    subtitleLabel.text = "\(currentIndex + 1) / \(context.orderedItems.count)"
  }

  private func reportClosedIfNeeded() {
    guard !hasReportedClose else { return }
    hasReportedClose = true
    let catalogMatch = runtime.galleryCatalogIdentity == context.catalogIdentity
    CameraVendorFileLogger.log(
      "[OBS] HD_FULLSCREEN_CLOSE_RETURN handle=0x\(String(format: "%08X", currentHandle)) " +
      "catalogMatch=\(catalogMatch)"
    )
    onClosed(currentHandle, context.catalogIdentity)
  }

  @objc private func closeTapped() {
    if let navigationController, navigationController.viewControllers.first !== self {
      navigationController.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativeGalleryHDFullScreenPageController else { return nil }
    let index = page.index - 1
    guard context.orderedItems.indices.contains(index) else { return nil }
    return makePage(index: index)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativeGalleryHDFullScreenPageController else { return nil }
    let index = page.index + 1
    guard context.orderedItems.indices.contains(index) else { return nil }
    return makePage(index: index)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard let page = pageController.viewControllers?.first as? NativeGalleryHDFullScreenPageController else {
      return
    }
    previousViewControllers.forEach {
      guard $0 !== page else { return }
      ($0 as? NativeGalleryHDFullScreenPageController)?.setDisplayedPage(false)
    }
    page.setDisplayedPage(true)
    currentIndex = page.index
    refreshChrome()
    focusPipelineOnCurrentHandle()
  }
}

@MainActor
final class NativeGalleryHDFullScreenPageController: UIViewController, UIScrollViewDelegate {
  let item: CameraVendorGalleryItem
  let index: Int
  private let cachedThumbnailImage: UIImage?
  private let cachedPreviewProvider: (Int) -> NativeGalleryCachedPreview?
  private var decodeTask: Task<Void, Never>?
  private var isDisplayedPage = false
  private var requestedTarget: NativeGalleryHDDecodeTarget?
  private var renderedTarget: NativeGalleryHDDecodeTarget?
  private var allowsNativeDecode = true

  private let scrollView: UIScrollView = {
    let view = UIScrollView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.minimumZoomScale = 1
    view.maximumZoomScale = 4
    view.showsHorizontalScrollIndicator = false
    view.showsVerticalScrollIndicator = false
    return view
  }()

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    return view
  }()

  private let spinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .large)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = .white
    view.hidesWhenStopped = true
    return view
  }()

  init(
    item: CameraVendorGalleryItem,
    index: Int,
    cachedThumbnailImage: UIImage?,
    cachedPreviewProvider: @escaping (Int) -> NativeGalleryCachedPreview?
  ) {
    self.item = item
    self.index = index
    self.cachedThumbnailImage = cachedThumbnailImage
    self.cachedPreviewProvider = cachedPreviewProvider
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.addSubview(scrollView)
    scrollView.addSubview(imageView)
    view.addSubview(spinner)
    scrollView.delegate = self

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    showThumbnailFirst()
    refreshFromCache()
  }

  deinit {
    decodeTask?.cancel()
  }

  func setDisplayedPage(_ displayed: Bool) {
    isDisplayedPage = displayed
    allowsNativeDecode = true
    decodeTask?.cancel()
    decodeTask = nil
    requestedTarget = nil
    if isViewLoaded {
      refreshFromCache()
    }
  }

  func refreshFromCache() {
    guard isViewLoaded, let preview = cachedPreviewProvider(item.handle) else {
      if isDisplayedPage { spinner.startAnimating() }
      return
    }
    guard let target = NativeGalleryHDFullScreenDecodePolicy.nextTarget(
      isDisplayedPage: isDisplayedPage,
      renderedTarget: renderedTarget,
      viewport: view.bounds.size,
      displayScale: view.window?.screen.scale ?? UIScreen.main.scale,
      allowsNativeDecode: allowsNativeDecode
    ) else {
      spinner.stopAnimating()
      return
    }
    guard requestedTarget != target else { return }
    requestedTarget = target
    decodeTask?.cancel()
    decodeTask = Task { @MainActor [weak self] in
      let image = await NativeGalleryHDTargetDecoder.decodedImage(
        from: preview.data,
        objectOrientation: preview.objectOrientation ?? self?.item.orientation,
        target: target,
        diagnosticHandle: self?.item.handle ?? 0
      )
      guard let self,
            !Task.isCancelled,
            self.requestedTarget == target,
            let image else { return }
      self.decodeTask = nil
      self.requestedTarget = nil
      self.renderedTarget = target
      self.imageView.image = image
      self.spinner.stopAnimating()
      self.refreshFromCache()
    }
  }

  func releaseNativeDecodeForMemoryWarning() {
    guard isDisplayedPage else { return }
    allowsNativeDecode = false
    decodeTask?.cancel()
    decodeTask = nil
    requestedTarget = nil
    renderedTarget = nil
    showThumbnailFirst()
    refreshFromCache()
  }

  func releaseFitDecodeForMemoryWarning() {
    guard !isDisplayedPage else { return }
    decodeTask?.cancel()
    decodeTask = nil
    requestedTarget = nil
    renderedTarget = nil
    showThumbnailFirst()
  }

  private func showThumbnailFirst() {
    if let data = item.thumbnailData,
       let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: data,
        objectOrientation: item.orientation,
        diagnosticHandle: item.handle
       ) {
      imageView.image = image
    } else if let cachedThumbnailImage {
      imageView.image = cachedThumbnailImage
    }
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }
}
