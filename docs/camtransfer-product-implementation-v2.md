# CamTransfer 当前实现总览（V2 · 产品级）

> 这份文档记录 2026-05-05 这一轮迭代后**已经走通且稳定**的所有技术点。后续任何改动都要先对照本文，不要碰已经验证过的链路。`docs/cameraVendor-camera-flow-and-product-notes.md` 是更早期的协议级笔记，本文是它之上的产品/UX 增量。

---

## 一、产品形态

### 首页（NativeConnectViewController）

| 状态 | 内容 |
|---|---|
| **未配对** | 顶部 `CAMTRANSFER` 金色品牌头 + `Camera roll, refined.` 大字 + 副字；中央留白；右下角 ⊕ 黑色浮动按钮（FAB）打开扫描页 |
| **已配对** | 顶部同上 + 配对卡片（金色 `PAIRED CAMERA` 小标 + 大字相机名 + 序列号 + 圆形 XT 徽章 + 分隔线 + 黑色 `连接这台相机` 主按钮）；右下角同样有 ⊕ FAB 用于添加另一台相机 |
| 配对卡片左滑 | 显出右侧红色 `删除` 按钮，需要二次确认弹窗 |

### 连接新设备（NativeScanViewController）

- 半屏 sheet，左上 X 关闭
- `CAMTRANSFER` 金色头 + `Pair a camera.` 大字
- 实时扫描结果以**白色卡片**展示：左侧型号徽章（CAM/PRO...）、中部相机名 + 信号 + UUID 前 8 位、右侧 chevron
- 点击卡片：那张卡片右侧出现转圈 + 整页底部状态条显示当前 BLE/握手进度
- 底部小字链接：`已连接相机 Wi-Fi，直接传图`

### 连接进行中（NativeConnectingOverlay）

跟 demo 04 一致的全屏 overlay：
- 卡片中央 86×86 圆环，金色进度旋转
- 大字"正在连接 DEVICE-A"
- 当前步骤文字（实时跟着 BLE/PTP 阶段变化，已经映射好"正在打开 PTP 会话"等用户语言）
- 底部"取消"链接 → 立即清理状态返回首页

### Wi-Fi 引导（NativeWifiPromptOverlay）

进图库时如果没在相机网，立刻弹出全屏卡片：
- 头部金色 `CAMERA WI-FI`
- 大字 `需要连接相机 Wi-Fi`
- 中央米色圆角图标块带 wifi 图标
- 相机 SSID chip（如 `CAMERA-DEVICE-A-003B`，当 BLE 没读到时回退提示）
- 黑色主按钮 `↗ 去连接 Wi-Fi`
- 灰色次按钮 `我已连接，重试`

按钮内部尝试 `App-Prefs:root=WIFI` 系列旧 deep link；失败时降级到 `openSettingsURLString` 并弹 toast 提示用户手动后退到 Wi-Fi 列表（iOS 11+ 系统限制，第三方 app 没法直接跳 Wi-Fi 设置页）。

### 图库（NativeGalleryViewController）

布局自上而下：
1. 金色品牌 `DEVICE-A GALLERY`（大字标题已经按用户要求移除）
2. 状态行：金色小转圈 + 文字（加载时显示当前进度词；加载完显示 `12 张照片 · 已选 0`）
3. 三行筛选 chip：
   - `[全部] [今天] [选择日期]`
   - `[全部] [JPG] [HEIF] [RAW] [视频]`
   - `[原图] [压缩 ~3M]` ← 切换会保存到 UserDefaults，下次连接生效
4. 缩略图网格（默认 3 列，可两指捏合在 2-5 列之间切换；UserDefaults 持久化）
5. 选中后底部浮起白色胶囊条 `已选 X 张  [↓ 下载原图]`
6. 右上导航栏：`[√ 全选] [tray.full 下载列表]`

首次进入会有右侧飘入的小提示药丸 `双指捏合调整每行张数`，用户首次捏合后自动消失；同时还会做一次"列数演示"动效（自动切一次再切回来）让用户直观看到捏合效果。

### 选择日期（NativeDateRangePickerController）

- 半屏 sheet，跟首页风格一致
- 头部金色 `CAPTURE DATE` + 大字 `筛选拍摄日期`
- 两个白色卡片：开始 / 结束，内嵌 compact `UIDatePicker`
- 黑色主按钮 `应用筛选` + 灰色 `取消`
- 选完后 chip 显示成 `10月8日` 或 `10月8日 – 10月12日`

### 预览（NativePhotoPreviewViewController）

苹果原生相册风格：
- `UIPageViewController` 横向翻页，inter-page 间距 24
- 每页 zoomable `UIScrollView`，min 1x / max 4x，双击在 1x ↔ 2.5x 之间切换
- **下滑关闭**：单指下拉时照片跟着缩放 + 背景渐隐，过阈值松手即关闭，不过阈值则弹簧回弹
- 单击屏幕：顶/底栏淡入淡出（同步隐藏 status bar 和 home indicator）
- 顶部/底部使用**黑色渐变蒙层**（`NativeGradientChromeView`）替代毛玻璃，跟黑色背景融为一体不割裂
- 顶栏：左 X 关闭、中间文件名 + 第几张/共几张 + 格式 + 大小
- 底栏：左 选中圈、右 白色 `下载原图` 胶囊（按下载状态自动切 `下载中…` / `已下载` / `重试下载`）
- 退出时还原 navigation bar（之前 bug：退预览后图库的 nav bar 也跟着不见了）

### 下载列表（NativeDownloadListViewController）

- 头部 `DOWNLOADS` 金标 + 大字 `下载中心` + 副字
- 4 列网格，比图库更密
- 排序：`已保存` → `下载中` → `排队中` → `失败`，已下载的永远排最上
- `idle/failed` 项目轻微变暗（opacity 0.58），清晰区分
- 底部居中状态字：`HEIF · 8.4 MB · 2/5` 或 `已保存 X/Y`
- 空状态显示居中插画 + `还没有下载任务` 引导文字
- 已下载持久化到 UserDefaults（按相机序列号分桶），重新进图库自动恢复 saved 标记

---

## 二、视觉系统（NativeLuxuryTheme）

| 角色 | 值 |
|---|---|
| `background` | `#F8F7F4` 暖灰白 |
| `cardBackground` | 纯白 |
| `ink` | `#171717` |
| `secondaryInk` | `#6E6B63` |
| `hairline` | 黑 10% |
| `accent` | `#9F8357`（金棕色） |

主要构件：
- 卡片：`applyCardStyle` — 28pt 圆角 + 1px hairline + 软投影
- 主按钮：`stylePrimaryButton` — 黑底白字胶囊 + 阴影
- 次按钮：`styleSecondaryButton` — 白底ink文字胶囊 + 描边
- 浮动 pill：`applyFloatingPillStyle` — 奶米色背景 + 大圆角 + 阴影（用于底部下载条）
- Brand label：`makeBrandLabel(text, size)` — 金色全大写 + 0.22em letter spacing
- Title label：`makeTitleLabel(text, size)` — heavy weight + -0.05em kern + 0.96 line height
- Divider：1px `hairline` 横线
- ChipBarControl：横滚胶囊条，active = ink 实心 + 金色 1.4px 描边 + 阴影；inactive = 纯白 + 0.08 描边；点击有 0.93 缩放回弹

字号节奏：品牌 9-11pt heavy / 标题 30pt heavy / copy 13pt regular / 状态 11-12pt semibold。

---

## 三、连接流程（已稳定）

完整链路：

```
点击"连接这台相机" / 在扫描页选中相机
  ↓
service.resetForNewConnectionAttempt()        ← 关键：清残留
  ↓
service.approveNextRememberedCameraConnection()
  ↓
service.connectLastPairedCameraIfAvailable()  / service.connect(to:)
  ↓
BLE 扫描 + 连接 + 服务发现
  ↓
BLE 写入 ReferenceApp 激活四步序列：
  CAEDB497 = 0x00     (ImageTransferSetting)
  98934B2C = 0x01     (ImageTransferSettingEx)
  82A9F452 = 0x00/01  (ImageResizeSetting，由"压缩下载" chip 决定)
  600655E6 = 0x0300   (FunctionLaunchRequest)
  ↓
等待 AP_STATE_READY ... Launched(0x8001)
  ↓
（如果之前已经在相机 Wi-Fi）didCompleteHandshake → 直接 push gallery
（否则）Wi-Fi prompt overlay → 用户去系统设置接 → 自动检测 IP 192.168.0.x → 进图库
  ↓
PTP/IP 握手：
  - 等 3 秒让相机 PTP 服务就绪（这个值不能再砍，砍了之后大量 thumbnail 超时）
  - INIT_COMMAND_REQUEST + ACK
  - openSession
  - waitForCameraAccess（CameraState 0xDF00 轮询，0.5s 间隔最多 20s）
  - 读取图库（D621 + 隐藏 handle 探测，详见 V1 文档）
```

### 连接残留状态修复（关键）

`CameraVendorBluetoothService.resetForNewConnectionAttempt()` 必须在每次"连接这台相机"前调用。它清扫的状态包括：

```
selectedPeripheral, autoReconnectTargetPeripheralID, isRunningTransferActivation,
awaitingPairingReadyRediscovery, awaitingTransferActivationStateChange,
awaitingBluetoothDisconnectForWifiHandoff, isDelayingGalleryForBleStateSampling,
pendingHandshakeSummary, pendingPostHandshakeProbeReads, pendingTransferActivationStrategies,
pendingTransferActivationWrites, currentTransferActivationStrategy,
didCompletePairingCallback, didCompleteHandshakeCallback,
hasCompletedPairing, hasUserInitiatedTransfer, handshakeMode, handshakeCoordinator
```

**没有这一步**就会出现"失败一次后，再点连接没反应，必须杀进程"。三处会调用：
1. `connectRememberedCameraTapped`（用户点连接前）
2. 连接 overlay 的 cancel 按钮
3. 主 VC 的 `viewWillAppear`（且当前是导航栈根，即从图库返回首页）

---

## 四、下载流程（已稳定）

### 串行实现

```swift
while let handle = galleryState.nextQueuedDownloadHandle() {
  markDownloadStarted
  let data = try await galleryService.downloadOriginal(for: handle)
  try await CameraVendorPhotoLibrarySaver.save(data: data, filename: filename)
  markDownloadFinished
  CameraVendorDownloadHistoryStore.markSaved(handle:, for:)  // UserDefaults 持久化
}
```

**为什么不是并行**：DEVICE-A 固件在两条 PTP 会话同时拉数据时会主动断开（保护行为）。我们留了 `CameraVendorPtpDownloadWorker` / `CameraVendorParallelDownloadFactory` 协议，未来其它 CameraVendor 机型如果支持可以直接启用，但 DEVICE-A 现在不能开。

### 已落地的 4 处真提速

| 改动 | 估算 | 说明 |
|---|---|---|
| TCP `SO_RCVBUF`/`SO_SNDBUF` 默认 256KB → 2MB | 5-10% | 突发数据时 TCP 不阻塞相机端发送 |
| `CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize` 1MB → 4MB | 5-15% | 30MB RAW 从 30 次 round-trip 降到 8 次 |
| `readObjectByPartialObjects` `received.reserveCapacity(expectedSize)` | CPU 节省 | 避免 `Data.append` 反复 realloc |
| `CameraVendorPhotoLibrarySaver.save(data:)` 改用 `addResource(with:data:)` | 每张省 ~150-300ms | 跳过临时文件写入/读取/删除 |

合计大文件批量下载快 **15-25%**。

### 压缩下载

- BLE 阶段写 `82A9F452 = 0x01`（默认 `0x00`）
- 相机端自动转出 ~3M JPG，画质保留
- UI：图库筛选区第三行 `[原图] [压缩 ~3M]` chip
- 切换立刻保存 UserDefaults，弹 toast `下次连接生效`
- 实测：50MB RAW → ~3MB JPG，速度提升 **~10x**

### 下载历史持久化

`CameraVendorDownloadHistoryStore`：按相机 `summary.serialNumber`（fallback 到 `deviceName`）分桶存 saved handle Set 到 UserDefaults。

进图库 `loadGallery` 成功后：

```swift
restoreSavedDownloadStates()  // 把已保存的 handle 在 galleryState 里 markDownloadFinished
```

下载列表（tray 按钮）随时点都能进，空时显示空状态引导。

---

## 五、缩略图渲染

`CameraVendorGalleryThumbnailRenderer.decoded(data:)` 现在做两件事：

1. `UIImage(data:)` 直接解码（HEIF/RAW 走 `CGImageSourceCreateThumbnailAtIndex` 兜底）
2. **裁掉相机烤进缩略图的黑边**：扫描首尾行像素，纯黑（threshold ≤ 16）行就 crop 掉。3:2 photo 包成 4:3 留下的上下黑条由此被清理，cell 用 `scaleAspectFill` 直接铺满。

---

## 六、UI 多余/危险部分清单（不要再加回来）

- ❌ 不要在图库右上加"刷新"按钮（点击后会触发并发的 `fetchGallery`，破坏现有 PTP session）
- ❌ 不要在配对卡片上加"WiFi已连接，直接传图"按钮（已经是右上角浮动 + scan 页里做了，重复就乱）
- ❌ 不要把"添加新设备"放回左上 nav bar，FAB 在右下角更符合 iOS 直觉
- ❌ 不要在缩略图 cell 已下载状态上还显示选择圈（用户明确不要）
- ❌ 不要把 ptpStartupDelaySeconds 砍到 < 3s（会造成 thumbnail 大批量 `等待相机返回数据超时`）
- ❌ 不要把 CameraState 轮询间隔改得太密集
- ❌ 不要并发跑两条 PTP session 同时拉数据（DEVICE-A 会自我保护断开）

---

## 七、文件结构索引

```
ios/Runner/
├── CameraVendorBluetoothService.swift   ← BLE + PTP 协议层 + service factory
├── NativeConnectViewController.swift  ← 全部 UI（分扇区由 MARK / 大类区分）
└── RunnerApp.swift              ← SwiftUI App + UIKit nav 包装

docs/
├── cameraVendor-camera-flow-and-product-notes.md  ← V1 协议笔记（最早的握手/HEIF 探测）
└── camtransfer-product-implementation-v2.md  ← 本文（产品级总览）
```

`NativeConnectViewController.swift` 里主要类（按出现顺序）：

- `NativeLuxuryTheme` — 设计系统
- `NativeChipBarControl` — 横滚胶囊筛选条
- `NativeConnectViewController` — 首页
- `NativeConnectingOverlay` — 连接中卡片（demo 04）
- `NativeWifiPromptOverlay` — Wi-Fi 引导卡片（demo 03）
- `NativeDateRangePickerController` — 日期范围选择 sheet
- `NativeScanViewController` — 扫描相机 sheet
- `NativeTransferReadyViewController` — 传输就绪页（已经被自动跳过）
- `NativeGalleryViewController` — 图库
- `NativeGradientChromeView` — 预览页顶/底渐变蒙层
- `NativePhotoPreviewViewController` + `NativePhotoPreviewPageController` — 预览
- `NativeDownloadListViewController` — 下载中心
- `NativeGalleryGridCell` — 网格 cell
- `CameraVendorPhotoLibrarySaver` — 系统相册写入
- `CameraVendorDownloadHistoryStore` — 下载历史 UserDefaults

---

## 八、当前已知限制

| 限制 | 原因 | 是否可破 |
|---|---|---|
| 同时只能下一张原图 | DEVICE-A PTP 不允许 2 个会话同时拉 | 相机硬件 / 固件限制 |
| 无法跳转到系统 Wi-Fi 列表 | iOS 11+ 屏蔽了第三方 app deep link | 系统限制 |
| 直连 AP 上限 ~30 Mbps | 相机自带 AP 仅 2.4 GHz | 需要做"通过家用路由器"模式 |
| 不支持视频原图下载稳定性 | 之前的 `CameraVendorPhotoLibrarySaver.save(file:)` 路径未充分测试 | 后续需要专门验证一遍 |

---

## 九、下次迭代候选

按 ROI 高到低：

1. **"通过家用路由器"模式** — 5 GHz 大带宽，速度从 ~30 Mbps 飙到 ~200 Mbps，能让原图下载体感跟读卡器靠近；需要专门的连接流程改造
2. **GetObjectInfo 批量** — 当前每个 handle 一次 PTP 命令；如果能用 D621/D622 一次返回多个，缩略图加载会快几秒
3. **视频下载稳定性** — 当前主要测试都是 photo 路径
4. **多机器型号兼容** — 现在所有 BLE/PTP 都基于 DEVICE-A 验证，DEVICE-B / DEVICE-C 等需要再过一遍流程
