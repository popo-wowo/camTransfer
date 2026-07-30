# iOS Gallery 最终 UI 与查询优化设计

**状态：** 用户已批准实施。

## 目标

在不改变现有终态所有权的前提下，消除三类剩余问题：同一相机会话内兼容 Catalog 查询重复访问 PTP、Gallery VC 的 presentation/sections 手工同步风险、高清模式存在两个可操作日期入口。

## 设计选择

### 1. QueryEngine 复用 membership，不复用 Gallery presentation

`CameraCatalogQueryEngine` 在当前 `sessionEpoch` 内缓存按格式查询计划得到的不可变 membership items。日期和下载范围继续在每次 resolve 时根据最新规则与已下载 handles 本地投影。

- 缓存键只包含格式 membership 计划：全部格式或具体格式集合。
- 缓存命中发生在 `CameraCatalogAccessGate.acquire` 之前，因此不等待 PTP access gate。
- 首次 miss 后取得 gate；取得后再次检查缓存，避免并发相同查询重复访问相机。
- `invalidate()` 清空缓存；新连接、换相机和 session 重建天然创建新 QueryEngine。
- 不读取或安装 `NativeGalleryViewController` 的 presentation，不让快速下载污染相册筛选状态。

### 2. VC 使用原子 GalleryRenderState

新增不可变 `NativeGalleryRenderState`：

- `presentation`：Runtime 发布的最新不可变 Catalog 展示快照；
- `sections`：由 presentation 派生的 UICollectionView 日期投影。

完整 Catalog 更新原子替换 presentation 与 sections。增量内容更新在不改变 section 身份/顺序时，按 handle 替换 section item 内容；结构变化才重新分组。相同 presentation 的 Runtime 发布只刷新下载/状态 UI，不执行 `reloadData()`。

`selectedHandles` 继续属于 VC，因为它是页面瞬时交互状态，不是 Catalog membership。

### 3. 高清模式只有一个日期选择入口

缩略图模式允许展开筛选面板。高清模式保留顶部 HD 日期按钮，筛选面板不可展开。Gallery 筛选日期仍作为进入高清模式时的初始日期来源，HD 日期切换继续只生成单日期固定快照，不修改持久化筛选。

## 不做的事情

- 不直接复用快速下载结果作为 Gallery Catalog。
- 不把 UIKit sections 或 selection 放进 Runtime。
- 不增加第二个 Catalog owner、第二条 PTP lane 或新的 pending flag。
- 不改变快速下载完成路由、下载队列和相机连接生命周期。

## 验收

1. 相同格式 membership 的连续 resolve 只访问相机一次，后续日期/下载范围变化使用缓存重新投影。
2. 不同格式 membership 计划不会错误复用。
3. 增量 thumbnail/details 内容写入后，sections 中同 handle 的 item 同步更新；只有结构变化才重新分组。
4. 相同 Catalog presentation 的 Runtime 状态发布不触发完整 Gallery reload。
5. 高清模式筛选面板不可展开，HD 日期按钮仍可选择当前高清 session 日期。
6. 现有快速下载隔离、Gallery ownership、筛选持久化、缩略图和 HD pipeline 测试保持通过。
