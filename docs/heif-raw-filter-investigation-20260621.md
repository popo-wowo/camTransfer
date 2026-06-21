# HEIF/RAW 筛选问题排查记录 (2026-06-21)

## 问题描述

1. HEIF 格式的照片筛选不出来
2. RAW 和视频要等所有数据加载完才能筛选（应该一开始就能筛选）

## 根因分析

### 相机行为

- 相机 `D621 SpecifiedObjectHandles` **默认只返回 JPEG handles**（1145 个）
- HEIF/RAW 文件的 handle 在 JPEG handles 的**间隙**中（不在 max handle 之后）
  - 例：handle 1246(JPEG) → 1245(HEIF) → 1244(HEIF) → ... → 1236(HEIF) → 1235(JPEG)
  - RAW 在更老的区间：奇数 handle（85, 87, 89...127）
- `9053 GetSpecifiedObjectCountGroupByDate` 也只返回 JPEG 的日期分组
- `0x1004 GetStorageIDs` 返回 `0x2005 OPERATION_NOT_SUPPORTED`（标准 PTP 枚举不可用）

### 原厂 app 的做法

**iPhone 抓包确认（iphone-xapp-20260621-full.pcap）：**
- iPhone 官方 app **没有**调用 `0x9051 SetSearchModeAll`
- iPhone 的 9053 返回了**包含 20260621（33 张）**的日期分组
- 命令序列和我们**完全相同**：INIT → OPEN_SESSION → D212 → DF01=20 → DF28=3 → D244×2 → 9054 → 9055 → 9050 → D22B → 9053 → D212 → D620 → D621

**结论：相机在 iPhone 连接时返回全格式 handles，在我们连接时只返回 JPEG。区别不在命令序列，而在相机的内部状态。**

**推测：** 相机的 SearchMode 状态在连接间被持久化。iPhone 之前通过官方 Fujifilm XApp 的 native SDK（`ControlFFIR.so`）调用了 `SetSearchModeAll`（序列化格式为私有二进制），相机永久记住了"返回全格式"的状态。

### Android 官方 app

- 反编译确认 `ControlFFIR.java` 暴露了 `Java_SDK_SetSearchModeAll` JNI 方法
- native SDK 的序列化格式无法通过二进制修改 `GetSearchModeAll` blob 来模拟
- 我们尝试了多种 payload 格式发送 `0x9051`，相机返回 OK 但**实际不生效**：
  - 空 payload `[00000000]` → 无效
  - iOS 格式 `[count=1, len=8, D604, 0x1F]` → 无效
  - 修改 GetSearchModeAll blob 的 D604 字段 → 无效（相机读回后值未改变）
  - 修改 GetSearchModeDescAll blob → 相机卡死

### iOS 代码的 Policy 设置

```swift
shouldSetStillImageObjectFormatSearchMode = false  // 不设置格式筛选
shouldResetSearchModeBeforeFormatSearch = false
shouldResetSearchModeDuringColdStart = false
```

iOS 版本也**不调用 SetSearchModeAll**——它依赖相机已经处于正确状态。

## 当前实现方案（临时方案）

### 方法：Hidden Gap Probe + Forward Probe

在缩略图加载开始后，独立协程中探测 HEIF/RAW handles：

1. `recentGapCandidates`：从最大 handle 向前扫描相邻 JPEG handles 间的间隙（gap ≤ 20，最多 60 个候选）
2. `forwardProbeCandidates`：探测 max handle 之后 20 个位置
3. 对每个候选 handle 调用 `GetObjectInfo`，如果返回 HEIF/RAW/Video 格式则合并到列表
4. 合并后按日期+handle 排序

### 性能

- Probe 约 60-80 个候选 × ~150ms = **~10 秒**
- 和缩略图通过 PTP commandMutex 交替执行（不阻塞缩略图）
- HEIF/RAW 发现后立即合并到列表，按日期排序插入正确位置

### 已知限制

- HEIF/RAW **不是进入相册就显示**，需要等 probe 逐个探测（~10 秒后出现）
- 旧的 RAW（handle < 最近 60 个 gap 候选）需要等 full metadata 加载完才发现
- 日期分组和数量不包含 HEIF/RAW（9053 只返回 JPEG 的）
- 总数量和相机显示的不一致

## 未来优化方向

### 方案 A：抓取 Android 官方 app 的 PTP 流量

- 需要绕过 PCAPdroid VPN 干扰的问题（或用 root 设备直接 tcpdump）
- 获取 native SDK 发送的真实 `SetSearchModeAll` payload
- 照抄 payload 格式一次性解决问题

### 方案 B：让官方 app 先设置一次

- 验证假设：用 Android 官方 XApp 连接相机一次（让 native SDK 设置 SearchMode）
- 然后我们的 app 连接时是否能拿到全格式 handles
- 如果可以：首次使用时引导用户先用官方 app 连接一次

### 方案 C：逆向 native SDK 的序列化格式

- 分析 `libControlFFIR.so` 中 `Java_SDK_SetSearchModeAll` 的实现
- 找到正确的 PTP payload 序列化格式
- 在我们的 app 中重现

### 方案 D：优化 Probe 速度

- 减少不必要的候选（分析 handle 分配模式）
- 利用 ObjectInfo 中的 association/parent 信息推断相邻 handles
- 缩短 probe 延迟

## 改动的文件清单

| 文件 | 改动 |
|------|------|
| `CameraVendorSearchMode.kt` (新增) | ALL_FORMATS, VIDEO_FORMATS 常量 |
| `CameraVendorHiddenObjectProbePolicy.kt` | recentGapCandidates (gap≤20, 最多60个), forwardProbeCandidates |
| `CameraVendorGalleryDiscoveryPolicy.kt` | shouldProbeStandardWhenNoExtendedStill, MAX_STANDARD_OBJECT_INFO_PROBE_COUNT |
| `CameraVendorPtpDataParser.kt` | findObjectFormatValueOffset, searchModeAllWithObjectFormat |
| `PtpCommands.kt` | hiddenStillObjectInfos 支持视频; standardObjectInfosCapped |
| `PtpConnection.kt` | gallery mode init 加 D226=0; resetSearchModeAll（无效但保留） |
| `CameraFileSource.kt` | resolveForwardFiles, hiddenProbeCandidates 接口 |
| `PtpCameraGallerySource.kt` | 实现 resolveForwardFiles, hiddenProbeCandidates; resolveAdditionalFiles 支持视频 |
| `GalleryFilesController.kt` | scheduleForwardProbe (独立协程 gap+forward probe); publishFullObjectInfoBatch 排序 |
| `GalleryHeader.kt` | 新增"断开"按钮 |
| `BrowseScreen.kt` | GalleryHeader 传 onDisconnect |

## 抓包文件

- `/Users/g01d-01-1224/Documents/camtransfer/.analysis/packet-captures/iphone-xapp-20260621-raw-test.pcap` — iPhone 已建立连接的部分流量
- `/Users/g01d-01-1224/Documents/camtransfer/.analysis/packet-captures/iphone-xapp-20260621-full.pcap` — iPhone 完整连接流程（包含 INIT）

## 关键日志证据

```
# 相机返回的 SearchModeAll 状态（D604 未激活）：
GetSearchModeAll current bytes=48 hex=050000000900000001d60100000900000002d60100000800000003d600000800000004d600000a00000005d600000000

# SET 后读回完全没变（相机忽略了我们的 payload）：
GetSearchModeAll AFTER SET bytes=48 hex=050000000900000001d60100000900000002d60100000800000003d600000800000004d600000a00000005d600000000

# iPhone 的 9053 包含 20260621:33张，我们的 9053 最新只到 20260619
SpecifiedObjectCountsByDate summary=20260619:2, 20260617:1, ...（没有 20260621）
```
