# HEIF/RAW 筛选问题排查记录 (2026-06-21)

## 2026-06-24 最终结论

问题已经解决。正式方案不是 hidden gap 猜 handle，也不是标准 PTP 全卡枚举，而是利用相机在不同 `D604` 格式 mask 下返回的 `D621 SpecifiedObjectHandles` 差异:

```text
D604=JPG  -> D621 count 1138
D604=MOV  -> D621 count 14
D604=MP4  -> D621 count 0
D604=31   -> D621 count 1152, 后续 ObjectInfo 解析为 JPG=1138, Video=14
D604=HEIF -> D621 count 1268
D604=RAW  -> D621 count 1268
```

关键点:

1. `D604=31` 在当前 Android X-T5 实机上不是完整时间线，只暴露 `JPG + MOV`。
2. `D604=HEIF` 或 `D604=RAW` 后重新读取 `9053/D620/D621`，相机会返回更大的 1268 handle 列表。
3. 这个 1268 列表不是我们猜出来的，而是相机自己返回的完整 specified list。
4. 初始占位符使用这个扩展列表后，RAW/HEIF 一开始就存在，缩略图可以直接按首屏队列加载。
5. 后续 hidden metadata probe 只剩兜底，实测扩展 D621 成功后 `selected=0`。

最终验证日志:

```text
FormatSpecifiedHandles HEIF promotedToInitial count=1268 previous=1152
Fast gallery placeholders count=1268 dateGroups=19 datedPlaceholders=1268
Thumbnail context primed handle=1268 format=0x3812
Thumbnail context primed handle=1267 format=0xb103
full-object-info-final total=1268 formats={HEIF=37, RAW=79, JPG=1138, Video=14}
Gallery hidden metadata selected=0
```

实现规则:

1. 进入图库后仍先读取基线 `D604=31` 的 `9053/D620/D621`。
2. 再设置 `D604=HEIF` 或 `D604=RAW` 并读取同一组 `9053/D620/D621`。
3. 如果格式特定 pass 返回的 handle 数更多，并且日期分组总数等于 handle 数，则把它提升为初始占位符列表。
4. 发布占位符时保留相机返回顺序，不要按 handle 数字倒序排。
5. 完整 `ObjectInfo` 后台补齐，合并时保留已加载缩略图。
6. hidden gap probe 保留为诊断兜底，不能作为主发现路径。

顺序规则很重要。扩展 `D621` 的最新段可能是:

```text
1267,1268,1265,1266,1263,1264,1261,1262,1259,1260,1257,1258...
```

这代表相机自己的时间线顺序。按 handle 倒序会变成 `1268,1267,1266,1265...`，会打乱 RAW/HEIF/JPG 在同一拍摄组里的位置。

## 复盘: 为什么这个问题解决了这么久

### 1. 错把 `D604=31` 当成“全格式”

最早的直觉是 `31 = JPG|HEIF|MOV|MP4|RAW`，因此它应该返回全部格式。这个假设在协议常量上看起来合理，但实机日志反复证明它在当前 Android 会话里只返回 `JPG + MOV`。

真正的突破是停止从常量含义推断相机行为，改成逐个 mask 对比 `9053/D620/D621` 的真实返回。

### 2. 被 hidden gap probe 的“能用”误导

gap probe 确实能找到 RAW/HEIF，所以它一度让问题看起来已经解决。但它解决的是“最终能看到”，不是“原厂一样一开始就有占位符”。这导致我们在一段时间里优化后补逻辑，而不是继续追初始 handle 来源。

后来的验证标准改成:

```text
Fast gallery placeholders 必须已经包含 RAW/HEIF 对应 handle
full-object-info-final 之前不应再靠 hidden metadata found 补 RAW/HEIF
```

这个标准才把方向拉回到初始 `D621`。

### 3. 过度相信 iPhone 抓包的命令序列对 Android 完全等价

iPhone 抓包显示官方 App 没有明显调用 `9051 SetSearchModeAll`，但 iPhone 能拿到全格式。我们一度推断差异来自连接前状态、系统差异或原厂 native SDK 的隐藏行为。

这些方向不是错的，但不够闭环。Android 实机上真正有用的证据来自同一连接内逐个设置 `D604` 后马上读 `9053/D620/D621`。这比跨设备对比更直接。

### 4. 抓包和反编译没有直接给出最终答案

VPN 抓包会影响官方 App 传图，标准 PTP 枚举又在 vendor Wi-Fi 会话里返回 `0x2005`。反编译能确认 `D604`、`SetSearchModeAll`、`GetSpecifiedObjectHandles` 等概念存在，但无法直接说明当前机型在每个 mask 下的返回行为。

最终答案来自“反编译给方向，实机日志做判定”: 反编译确认格式 mask 值，实机枚举 mask 证明哪个请求能让相机吐出完整列表。

### 5. 之前的日志粒度不够面向“列表来源”

早期更多看最终文件数、RAW 是否出现、缩略图是否能加载。后来加了这些关键日志后，问题才变清楚:

```text
SpecifiedObjectHandles count
FormatSpecifiedHandles <format> groups/count/first/last
Fast gallery placeholders count
full-object-info-final formats
Gallery hidden metadata selected
```

这些日志能直接回答三个问题:

1. 初始占位符来自哪个 handle 列表。
2. RAW/HEIF 是初始列表已有，还是后面补出来。
3. hidden probe 是否还在承担主发现职责。

### 以后遇到类似问题的规则

1. 不要只看最终 UI 是否出现，要看“出现的阶段”: 初始占位符、缩略图、完整 metadata、hidden probe。
2. 不要用协议常量含义代替相机行为，必须逐个请求实测返回。
3. 对相机返回的列表顺序保持敬畏，除非有证据证明 handle 倒序等价于时间顺序。
4. 临时兜底能解决可见性，但不能替代原厂行为复刻。
5. 每个协议假设都要有一条能反证的日志，比如 count、format distribution、hidden selected count。

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

## 旧实现方案（已降级为兜底）

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

## 历史优化方向（已被 2026-06-24 方案取代）

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
