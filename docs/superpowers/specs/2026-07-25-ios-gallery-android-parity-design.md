# iOS 相册与 Android 功能和视觉对齐设计

## 目标

以当前 Android 相册实现为唯一产品和交互基准，对齐 iOS 的相册布局、缩略图浏览、高清预览、筛选排序、普通图与 RAW 入队、下载栏、工具入口和各类加载状态。

iOS 只保留平台必须存在的行为，包括安全区、系统返回手势、系统权限弹窗和 UIKit 生命周期。连接主链路、相机协议与原图下载主链路不在本次重写范围内。

## 结论：主体是前端重构，但不能只改页面

iOS 已经具备大部分底层能力，本次不需要重做相机连接或高清预览协议。可直接复用的能力包括：

- `D226=1 -> ObjectInfo -> GetPartialObject -> D226=0` 高清预览读取。
- 高清预览的内存缓存、会话磁盘缓存和 loaded handle 状态。
- 基础浏览模式切换、高清单列 cell、全屏预览。
- 相册目录、日期分组、筛选排序、缩略图按需读取。
- 普通照片选择、下载队列、下载尺寸和下载状态。

因此主要工作集中在 UIKit 页面结构和 Gallery 内部状态组织。但下列行为差异不能靠换皮解决，必须做小范围行为层修正：

1. 当前高清模式只取消活跃缩略图任务，没有暂停并等待 metadata、目录子任务和缩略图任务全部退出。
2. 当前高清列表直接读取实时 `catalogPresentation.items`，没有为选中日期建立稳定 session 快照。
3. 当前队列采用当前位置后顺序扫描再回头，不是 Android 的可见窗口优先规则。
4. 当前进度使用整个 cache 的 `loadedHandles`，没有限定到当前日期 session。
5. 当前 RAW 按钮只是展示，点击后仍提示“RAW 文件加入功能开发中”。
6. 当前顶部筛选和模式切换占两行，高清模式仍复用多日期 section header，底部栏也没有使用 Android 的高清会话语义。

## 范围

### 本次改造

- Android 式相册顶部导航和同一行工具区。
- Android 式筛选面板、日期与格式选择、排序控件。
- Android 式缩略图网格、日期分组、格式角标和加载占位。
- Android 式缩略图与高清模式切换。
- 单日期高清预览 session、浮动日期和加载进度。
- 高清卡片的等待、加载、失败、成功和下载状态。
- 普通显示图与 RAW sidecar 独立加入、取消加入和统一下载。
- Android 式底部下载栏及当前会话计数。
- 高清模式与目录、metadata、缩略图、下载之间的互斥。
- 会话缓存生命周期和退出清理。

### 不改造

- `Connect -> GalleryReady`。
- BLE 配对、Wi-Fi 切换和 PTP 建连。
- 相机目录协议和 HEIF 目录发现策略。
- 高清预览的 D226 与 GetPartialObject 协议顺序。
- 原图下载状态机和传输热路径。
- 后台下载与 Live Activity 架构。
- USB 相册。

## 目标架构

### 1. UIKit 展示层

`NativeGalleryViewController` 只负责：

- 创建并布局 Android 对齐的 UIKit 组件。
- 将筛选、模式、日期、滚动、加入和下载操作发送给 Gallery Browse Session。
- 根据统一 View State 更新可见控件和 cell。
- 保留 iOS 安全区、返回手势和系统权限行为。

控制器不再直接拥有高清加载 while-loop、实时 handle 队列、loaded/loading/failed 集合和缓存判断。

### 2. Gallery Browse Session

新增 Gallery 内部 session owner，持有一个相册页面的完整浏览状态：

- `mode`: thumbnail 或 highDefinition。
- `filterState`: 日期、格式和排序。
- `activeDate`: 高清模式当前唯一日期。
- `thumbnailPresentation`: 当前缩略图投影。
- `hdSnapshot`: 进入高清模式或切换日期时生成的固定照片快照。
- `hdItems`: 显示图与可选 RAW sidecar 的配对项。
- `visibleHandles`: 当前可见高清卡片。
- `loaded/loading/failed`: 当前高清 session 的状态集合。
- `queuedDisplayHandles/queuedRawHandles`: 普通图和 RAW 的加入状态。

目录 metadata 后续补齐可以更新 repository，但不能改变已经激活的高清 session 数量和顺序。用户切换日期或重新进入高清模式时再生成新快照。

### 3. 高清预览调度

调度顺序与 Android 一致：

1. 当前可见 handles，保持屏幕顺序。
2. 可见窗口之后最多 20 张。
3. 可见窗口之前最多 5 张。
4. 已加载、正在加载和明确不可预览的 handle 不重复入队。

滚动稳定后重新计算窗口并重排 pending 队列。取消、切日期和退出高清模式不能写成失败。

### 4. Gallery 独占门

进入高清模式时：

1. 停止接收新的目录、metadata 和缩略图子任务。
2. 取消并等待当前 metadata、目录和缩略图任务安全退出。
3. 保持相机 session 与 PTP 连接不变。
4. 高清读取通过现有串行相机命令路径执行。

退出高清模式时：

1. 取消并等待当前高清读取停止。
2. 恢复目录增量补齐和可见缩略图调度。
3. 保留本次相册会话已经加载的高清缓存，供再次进入高清模式复用。

开始下载时，现有 Download Session Owner 继续拥有最高优先级。Gallery Browse Session 停止高清读取并让下载独占 PTP。

### 5. RAW sidecar

高清 session item 明确包含：

- `displayItem`: JPG 或 HEIF 显示图。
- `rawSidecar`: 可选 RAW 文件。

两个 handle 分别进入现有下载队列：

- “加入”操作显示图 handle。
- “加入 RAW”操作 RAW handle。
- RAW 强制原图下载，不受当前压缩下载开关影响。
- 没有合法 RAW sidecar 时不显示 RAW 按钮。
- 未加载高清图时两个按钮呈现 Android 的“加载后加入”状态，并不可操作。

## 页面设计

### 顶部区域

第一行：

- 左侧圆形返回按钮。
- 中间 `CAMERA GALLERY` 和当前状态。
- 右侧工具入口；分享、下载中心、下载目录和缓存设置进入工具菜单。

第二行是同一工具行中的三个独立表面：

- 左侧 `[筛选]`。
- 中间 `[缩略 | 高清]` segmented control。
- 右侧 `[工具]`。

高清模式下筛选按钮不可展开，但保留位置和禁用样式，避免切换模式时顶部布局跳动。

### 缩略图模式

- 保留日期 section、最新优先和可见窗口缩略图加载。
- 网格列数、间距、占位、格式角标、选中态和下载态按 Android 当前实现对齐。
- 筛选展开后仍位于工具行下方，不新增独立模式行。
- 底部栏使用缩略图的多选、全选和下载语义。

### 高清模式

- 内容背景为黑色，单列显示自适应宽高比照片。
- 不显示日期 section header。
- 右上角悬浮当前日期和 `loaded / total`。
- 卡片间距、黑色背景、图片适配和按钮位置按 Android 对齐。
- 卡片按钮文案包括：`加载后加入`、`加入`、`已加入`、`重试加入`、`加载后 RAW`、`加入 RAW`、`RAW 已加入`、`重试 RAW`。
- 点击已加载照片进入现有全屏预览。

### 高清模式底部栏

- 当前日期已加入文件数量。
- 当前日期可下载照片总数。
- 原图/压缩切换；RAW 始终按原图。
- 统一“下载”按钮。
- 单卡按钮只加入或取消加入，不立即启动下载。

## 状态与数据流

1. GalleryReady 发布相册 repository presentation。
2. Gallery Browse Session 生成缩略图投影并驱动网格。
3. 用户切换高清模式；若当前为全部日期，自动选择 Android 规则下的默认有效日期，而不是阻止进入。
4. Session 生成单日期固定快照和 display/RAW 配对项。
5. Gallery 独占门暂停并等待 metadata 和 thumbnail work。
6. 可见窗口调度器提交 preview handles。
7. 现有 PTP preview path 返回 bytes 和 orientation。
8. session cache 更新 loaded 状态并发布 View State。
9. 用户分别加入显示图或 RAW；现有下载队列返回 queued/downloading/saved/failed 状态。
10. 用户点击底部下载；Download Session Owner 独占 PTP，高清任务停止。
11. 下载完成或返回浏览后，根据当前模式恢复对应任务。

## 错误与取消

- 切换模式、切日期、滚动重排和下载抢占导致的取消不进入 failed。
- 相机 busy 使用有界重试，不在控制器内永久一秒轮询。
- 图片校验失败显示“预览失败”和重试加入状态，不缓存黑图或不完整数据。
- D226 reset 继续由现有 `defer` 路径保证。
- RAW 配对缺失只隐藏 RAW 操作，不影响显示图预览。
- 当前日期没有可预览照片时显示 Android 对齐的空状态，并允许重新选择日期。

## 代码边界

主要修改：

- `ios/Runner/NativeGalleryViewController.swift`
- `ios/Runner/NativeGalleryHDPreviewCell.swift`
- `ios/Runner/NativeGalleryPolicies.swift`
- `ios/Runner/NativePhotoPreviewViewController.swift`
- `ios/Runner/CameraSessionRuntime.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- `ios/RunnerTests/RunnerTests.swift`

预计新增：

- Gallery Browse Session/View State 文件。
- 高清 session item、可见窗口和 RAW sidecar 配对策略。
- Gallery 独占门策略或 runtime API。

当前 checkout 的 Xcode 工程已经引用 `NativeGalleryHDPreviewCell.swift`，但该文件仍是未跟踪文件。实施时必须把它作为本功能的正式源文件纳入版本控制，不能让工程继续依赖本地未跟踪文件。

## 测试策略

### RED/GREEN 单元测试

- 顶部工具区结构与 Android 对齐策略。
- 全部日期进入高清时选择默认有效日期。
- 单日期快照在 metadata 更新后数量和顺序不漂移。
- 可见窗口优先级：可见、后 20、前 5。
- 切换模式、日期和下载抢占取消不标记失败。
- loaded 状态不受 30 张内存缓存淘汰影响。
- 当前日期进度只统计该 session handles。
- 显示图与 RAW sidecar 配对和独立入队。
- RAW 强制原图下载。
- 高清期间 metadata、thumbnail 不提交新请求。
- 退出高清和下载结束后任务恢复。
- Android 式底部栏的计数和按钮可用状态。

### 构建与回归

- iOS 目标测试和完整 `RunnerTests`。
- `git diff --check`。
- iOS Simulator Debug build。
- 可用物理 iPhone 的 Debug build、安装和启动。

### 真机相机验收

使用同一台相机和同一目录验证：

- 缩略图与高清切换不重连 BLE、Wi-Fi 或 PTP。
- 高清模式只加载当前日期，数量和顺序稳定。
- 快速上下滚动后从当前屏幕优先加载。
- 已加载照片滚出再滚回不重复读取相机。
- 普通图和 RAW 可以分别加入、取消和下载。
- 高清期间没有 metadata、thumbnail 或 download PTP 插队。
- 开始下载后没有新的高清 preview 请求。
- 退出相册后高清会话缓存被清理。
- iOS 与 Android 的顶部、网格、高清列表、状态、按钮和底部栏视觉一致。

## 验收标准

- iOS 相册的主要页面结构和组件样式与已确认的 Android 设计一致。
- Android 已有的相册业务入口在 iOS 不再出现占位或“开发中”提示。
- 高清模式拥有固定单日期 session、正确可见窗口调度和准确进度。
- metadata、thumbnail、高清预览和下载遵守同一个 PTP 独占边界。
- 普通图与 RAW sidecar 独立加入同一下载队列。
- 自动化测试、构建和静态检查通过。
- 真机安装启动与相机交互证据单独记录，不用模拟器结果替代。
