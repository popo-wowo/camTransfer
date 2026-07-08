# iOS Gallery Catalog Thumbnail Details Design

更新日期: 2026-07-08

## 目标

把 iOS 无线图库读取从当前的“占位列表 + 缩略图顺手带一点信息 + 后台慢补全”的混合模型，重构为明确分层的 `Catalog / Thumbnail / Details / Repository` 设计。

重构完成后：

- UI 不再直接消费半真半假的 `CameraVendorGalleryItem` 中间态。
- 缩略图加载成功不再暗示目录元数据更“真”。
- `filename / format / captureDate / size` 的目录真相只由目录层维护。
- Fujifilm legacy 路径需要的 `D621`、hidden still probe、dual-slot probe、forward probe 等 workaround 保留在 adapter/source 内部，不再泄漏成 UI 语义。

本设计只讨论无线图库数据模型和读取边界；不改变连接主链路、不改变有线导入、不强制视觉 redesign。

## 为什么当前设计不漂亮

当前实现可以工作，但它把三个本应分开的概念揉在了一起：

1. 目录真相
   - 哪些 handle 存在
   - 文件名是什么
   - 原文件格式是什么
   - 时间、大小、排序依据是什么
2. 缩略图读取
   - 当前可见窗口要显示的图片 bytes
   - 解码、裁黑边、旋转、缓存
3. 详情补全
   - hidden still 恢复
   - orientation
   - 更完整的 metadata

结果是：

- `loadGalleryItems()` 一次调用里既发布占位，又附带 `formatHints`，又启动后台补全。
- `fetchThumbnailWithInfo()` 形式上可能返回 `item`，但它不总是可靠目录元数据。
- UI 为了显示 badge，只能在 `formatLabel`、文件名扩展名、`formatHints` 之间猜哪个更可信。
- `GalleryItem` 同时表示“目录 entry”“缩略图缓存容器”“详情补全结果”，语义不单一。

这不是错误实现，而是 runtime workaround：为了让 legacy 相机上的首屏进入和首屏缩略图体验可用，把不完整目录提前暴露给 UI，再靠后续路径慢慢修正。

## 设计原则

### 1. 单一职责

- 目录层只负责“目录真相”。
- 缩略图层只负责图片显示数据。
- 详情层只负责额外 metadata。
- UI 只消费结构化状态，不判断协议细节。

### 2. 单一真相来源

- `filename / format / captureDate / size / sortKey` 只能由 `CatalogSource` 和 `Repository` 维护。
- `ThumbnailSource` 不能回写目录真相。
- `DetailsSource` 只能补充字段，不能重排目录或重定义缩略图缓存行为。

### 3. 中间态必须可解释

UI 不能看到“像目录但又不完全是目录”的隐式状态。目录字段必须属于以下两种之一：

- `confirmed`
- `unknown`

禁止再用 `formatHints` 这种“提示值”伪装成目录已知字段。

### 4. Workaround 留在 adapter 内部

legacy 路径的脏活允许存在，但只能存在于 source 内部：

- `D621` 句柄与 format mask
- hidden still 恢复
- forward probe
- standard object info fallback
- dual-slot probe

UI、ViewModel、Repository 不得直接知道这些策略存在。

## 方案比较

### 方案 A：整理现有混合模型

做法：

- 保留 `CameraVendorGalleryItem` 单模型
- 保留占位先发、缩略图回填、后台 metadata 补全
- 只把 merge 规则和 UI 判定规则整理干净

优点：

- 改动小
- 上线风险最低

缺点：

- 根问题没解决
- UI 仍然暴露于半真半假的中间态
- 后续性能与正确性优化仍然互相缠绕

### 方案 B：拆成 Catalog / Thumbnail / Details / Repository

做法：

- 引入 `CatalogSource`
- 引入 `ThumbnailSource`
- 引入 `DetailsSource`
- 引入唯一状态 owner：`GalleryRepository`
- UI 只消费 `GalleryEntryViewState`

优点：

- 语义清楚
- 迁移可控
- 不要求先消灭 legacy workaround
- 后续性能优化和协议修补可以独立进行

缺点：

- 需要新建一层 repository 和 view state
- 初期会有适配成本

### 方案 C：强制完整 summary 后再进入图库

做法：

- 目录第一页的 `filename / format / captureDate / size` 不完整就不允许进入图库

优点：

- UI 最干净
- 目录状态最简单

缺点：

- legacy 相机上首屏进入风险最大
- 当前仓库不适合一步到位

### 推荐

选择方案 B。

原因：

- 它能把“接口合同”和“runtime workaround”拆开。
- 它允许首屏体验保持接近当前实现。
- 它给未来清理 legacy 路径留下正确的边界。

## 目标架构

### CameraService

职责：

- 作为无线图库外部 facade。
- 持有连接后创建的 gallery 访问能力。
- 暴露给 UI / ViewModel 的只有稳定的 gallery API。

禁止：

- 不直接决定 UI 状态。
- 不直接暴露 `D621`、`GetThumb`、`GetObjectInfo` 等协议细节。

### CatalogSource

职责：

- 提供“目录 summary”。
- 输入 gallery session 和 adapter 能力。
- 输出 `GalleryEntrySummaryPage`。

返回字段：

- `handle`
- `filename`
- `format`
- `captureDate`
- `size`
- `sortKey`
- `summaryCompleteness`

规则：

- 字段要么是 confirmed，要么是 unknown。
- 不允许把 `formatHints` 塞进 `format`。
- 不允许缩略图路径回填 `filename` 或 `format`。

### ThumbnailSource

职责：

- 只读取和缓存缩略图 bytes。
- 支持 visible-first request window。
- 支持暂停、取消、重排。

返回字段：

- `handle`
- `thumbnailData`
- `thumbnailState`
- `decodeDiagnostics`

规则：

- 成功返回 thumbnail 不代表 summary 更完整。
- 不返回 `formatHints`。
- 不返回用于覆盖目录真相的 metadata。

### DetailsSource

职责：

- 在首屏之后补充“非首屏必须”的 metadata。
- 包括 orientation、hidden still 恢复、补充 format 确认、额外 capture info。

返回字段：

- `handle`
- `orientation`
- `refinedFormat`
- `additionalCaptureMetadata`
- `detailsCompleteness`

规则：

- 只能补充，不能重排目录。
- 只能通过 repository 合并进最终 view state。

### GalleryRepository

职责：

- 作为图库数据唯一 owner。
- 合并 `CatalogSource`、`ThumbnailSource`、`DetailsSource`。
- 输出稳定的 `GalleryEntryViewState` 列表和分页/刷新状态。

规则：

- 目录真相以 `CatalogSource` 为准。
- `ThumbnailSource` 只影响图片显示状态。
- `DetailsSource` 只补充 details 字段。
- 任一 source 失败都不能把其它 source 的 confirmed 字段降级成 hint。

### GalleryViewModel

职责：

- 订阅 `GalleryRepository` 输出。
- 维护筛选、排序、选择、下载入口等纯 UI 逻辑。
- 决定何时请求更多目录、何时刷新当前 viewport 缩略图、何时触发 details 补全。

禁止：

- 不直接调用 PTP 操作。
- 不知道 `D621`、hidden still、dual-slot probe。

## 数据模型

### GalleryEntrySummary

```swift
struct GalleryEntrySummary {
  let handle: Int
  let filename: ConfirmedValue<String>
  let format: ConfirmedValue<GalleryFormat>
  let captureDate: ConfirmedValue<Date>
  let size: ConfirmedValue<Int64>
  let sortKey: GallerySortKey
}
```

含义：

- 这是目录层真相的最小集合。
- `ConfirmedValue` 只能是 `.confirmed(value)` 或 `.unknown`。

### GalleryEntryThumbnail

```swift
struct GalleryEntryThumbnail {
  let handle: Int
  let state: ThumbnailLoadState
  let imageData: Data?
}
```

含义：

- 这不是目录。
- 它只表达图片显示状态。

### GalleryEntryDetails

```swift
struct GalleryEntryDetails {
  let handle: Int
  let orientation: ConfirmedValue<Int>
  let refinedFormat: ConfirmedValue<GalleryFormat>
  let notes: [GalleryDetailNote]
}
```

含义：

- 用于补充 summary 未覆盖的信息。
- `refinedFormat` 只能在 confirmed 时覆盖 unknown summary format，不能把 confirmed summary 改回 hint。

### GalleryEntryViewState

```swift
struct GalleryEntryViewState {
  let summary: GalleryEntrySummary
  let thumbnail: GalleryEntryThumbnail
  let details: GalleryEntryDetails
}
```

UI 规则：

- 格式 badge：
  - 优先 `summary.format`
  - 再看稳定 `summary.filename`
  - 不再暴露 `formatHints`
- 如果 `format` 仍 unknown，就明确显示为空，不显示类似 `HEIF/RAW` 的猜测 badge。

## 加载时间线

### 进入图库

1. `CatalogSource.loadFirstPage()`
2. Repository 发布第一页 `GalleryEntrySummary`
3. UI 立即进入图库并渲染列表骨架
4. `ThumbnailSource.loadVisible(handles:)`
5. `DetailsSource.refreshVisibleAndNearVisible(handles:)`

### 首屏目标

- 首屏可以快速进入。
- 首屏图片可以继续优先加载。
- 但首屏目录字段必须有清晰状态：
  - confirmed
  - unknown

### 不再允许的行为

- 缩略图成功后顺手修正目录 format
- 用 hint 驱动排序
- 用 hint 决定筛选结果
- 因 details 补全而重排当前已发布目录顺序

## 为什么它更漂亮

### 1. 上层合同清楚

当前实现把“目录 entry”和“缩略图缓存容器”揉进一个模型里。  
新方案里，消费者一眼能看出：

- 这是不是目录真相
- 这是不是仅用于显示的图片状态
- 这是不是补充信息

### 2. UI 不再猜

当前 UI 要在 `formatLabel`、文件名扩展名、`formatHints` 间推断可信度。  
新方案里，UI 只消费明确状态，不再自己做推理器。

### 3. Workaround 不再污染业务模型

现在 workaround 的存在直接塑造了 `CameraVendorGalleryItem` 的语义。  
新方案允许 workaround 继续存在，但只在 source 内部存在。

### 4. 性能优化目标更明确

以后如果慢，可以明确归因到：

- `CatalogSource` 太慢
- `ThumbnailSource` 太慢
- `DetailsSource` 太慢

而不是像现在一样，“全都像是 gallery 逻辑慢”。

### 5. 后续协议收口更便宜

如果后续能让 legacy 相机更早产出真文件名 / 真格式，只替换 `CatalogSource` 即可。  
UI、Repository、Thumbnail path 都不必跟着重写。

## 首屏体验策略

本设计不要求首屏等待完整 details。

推荐采取 `B-fast` 变体：

- 首屏快速进入
- 首屏 summary 允许部分字段 unknown
- 首屏缩略图继续 visible-first 优先
- details 在后台补充

不推荐 `B-strict`：

- 强制完整第一页 summary 后再进图库
- 这会把 legacy 读取成本重新推回首屏入口

## 迁移策略

### 阶段 1：引入新模型，不动底层协议

- 新增 `GalleryEntrySummary / Thumbnail / Details / ViewState`
- 新增 `GalleryRepository`
- 现有 UI 先通过 adapter 转成新 view state

### 阶段 2：剥离 Thumbnail path

- 让 `fetchThumbnailWithInfo()` 只承担 thumbnail 读取
- 删除 thumbnail 路径对目录真相的顺手修补语义

### 阶段 3：建立 CatalogSource

- 把现有 `loadGalleryItems()` 的目录能力收进 `CatalogSource`
- 对外只暴露 summary 语义
- 内部仍可复用当前 placeholder-first 机制，但不再泄漏 hint 作为目录 confirmed 字段

### 阶段 4：建立 DetailsSource

- 把 hidden still、forward probe、逐个 `objectInfo(handle:)` 收口到 `DetailsSource`
- 只通过 repository 合并 details

### 阶段 5：UI 只读 Repository

- `GalleryViewModel` 只消费 `GalleryEntryViewState`
- 删除 `formatHints` 驱动 UI 的现有路径

## 验收标准

满足以下条件，才算设计落地成功：

1. UI 模型中不再存在“用 hint 冒充 confirmed 目录字段”的行为。
2. `ThumbnailSource` 无法直接修改目录 `filename / format / captureDate / size`。
3. `CatalogSource` 可以被独立测试，不依赖 thumbnail 结果。
4. `DetailsSource` 的失败不会破坏已发布 summary。
5. UI 可以仅根据 `GalleryEntryViewState` 决定 badge、subtitle、selection、filter，不需要知道 `D621` 或 legacy probe。
6. 首屏进入速度不因要求 full details 而明显倒退。

## 最终判断

当前方案的价值，是让 legacy 相机上的图库先跑起来。  
新方案的价值，是把“为了跑起来而存在的 workaround”关进边界，让上层重新拥有干净合同。

这就是它更漂亮的原因：

- 不是 workaround 更少了
- 而是 workaround 不再定义系统的公共语义
