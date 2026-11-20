# 照片传输与相册（Photo Gallery）

面向"网易 UU 远程平替"目标新增的照片收发能力。本篇只描述**已经落地**的实现：
文件传输双栏窗口本身保持不变，新增一个照片相册窗口，照片本体复用既有的
可靠文件通道，缩略图与相册列表走控制通道的 JSON RPC。

相册窗口有两种模式，**控制端与被控端都会改到**：

| 角色 | 入口 | 行为 |
| --- | --- | --- |
| 控制端（远控窗口） | 会话工具栏倒数第二个「图片」按钮 | 列远端照片、缩略图、多选下载到本机、把本机照片上推、发剪贴板图片 |
| 被控端（主窗口） | 右上角菜单 →「照片相册」 | 本地相册：本机磁盘扫描 + 本机缩略图，把照片推给当前选中会话的控制端 |

### iOS 控制端与 .ipa

`.ipa` 只能由 Apple 工具链产出，Windows 上没有 `xcodebuild`，因此本机不产出
`.ipa`。仓库里已有两条现成通道：

1. 本地 macOS：`scripts/ios/build-ipa.sh`（Debug/Release 均可，产出**未签名**
   `apps/ios/build/CrossDeskMobile-unsigned.ipa`，再用 Sideloadly / AltStore /
   Xcode 免费签名装到设备）。
2. CI：`.github/workflows/build-ios.yml`（`macos-26` runner，`workflow_dispatch`
   可手动触发，产物为 `crossdesk-ios-arm64-unsigned-<version>`）。

注意：**iOS 控制端目前没有相册 UI**。相册窗口这次只做在桌面（Windows/macOS/Linux）
控制端与被控端上；iOS 端要出现相册，需要在 `apps/ios/CrossDeskMobile/`
里补 SwiftUI 视图 + `CrossDeskRTCBridge` 的 `gallery` / `thumb` 调用
（协议侧已经就绪，`libs/controller` 提供 `Gallery()` / `Thumbnail()`），
而编译验证必须在 macOS 或 CI 上做。

构建目标新增 `crossdesk_photo`（静态库，`libs/controller/src/photo_library.cpp`），
被 `crossdesk_file_browser`、桌面 GUI 与 `crossdesk_photo_test` 复用；stb 以
`STB_IMAGE_STATIC` 编译，归档不导出任何第三方符号。

## 0. 本轮修复的缺陷

| # | 缺陷 | 修复 |
| --- | --- | --- |
| 1 | 缩略图请求失败后被标记"已请求"，占位永远不消失 | 失败时复位 `requested`，单张最多重试 3 次（`kMaxThumbAttempts`），仍失败则保留占位 |
| 2 | 每个 UI tick 只请求 1 张缩略图，首屏很慢 | 每 tick 最多 3 张并发在途（`kThumbsPerTick`） |
| 3 | 下载/发送完成后相册不刷新 | `refresh_at_` 1 秒后自动重载当前目录 |
| 4 | 相册只能看照片根，无法下钻/回退 | 新增「上级目录」「照片根目录」与当前路径显示 |
| 5 | 被控端没有任何相册入口 | 主窗口菜单新增「照片相册」，本地模式浏览本机照片并可推给当前会话 |
| 6 | 旧代码先以 index 0 传一次缩略图（错行） | `ApplyThumbnail` 只用命中行自身的下标 |
| 7 | 本机模式缺目录切换与缩略图游标复位 | `Load()` 重置游标、`HarvestLocalScan()` 重建相册与路径 |
| 8 | 新字符串没有翻译 | `localization/catalog.json` 增加「照片相册 / 本机相册」并重新生成 10 语言资源 |
| 9 | 相册事件会与双栏文件窗口抢同一个事件队列 | `FileBrowser::Event::channel` 分流，相册事件只在相册窗口消费 |
| 10 | 产物不可直接分发 | 新增 `dist/CrossDesk-1.7.6-photo-win-x64/`（含运行必需 DLL/虚拟显示器驱动）与 zip |

## 1. 为什么这样设计（对照 UU 远程的实现）

对 `UU远程 4.42.0.2770`（`D:\UU远程\GameViewer`，`GameViewer.exe` /
`GameViewerServer.exe`）做了静态分析，其文件传输形态是：

| 层 | UU 远程的实现（证据） |
| --- | --- |
| 控制面 | protobuf RPC：`rpc_file_transfer.proto` 定义 `FileTransferFtpRequest` / `FileTransferFtpResponse`，由 `host::business::file_transfer::FileTransferModule::sendRpcRequest/sendRpcResponse` 收发（`.rdata` 符号 + 源路径 `source/src/server_core/business/file_transfer/file_transfer_module.cpp`） |
| 数据面 | 独立 FTP 式块传输：`file_transfer_ftp.cpp`、`shared/business/file_transfer/ftp_helper.cpp`，特性开关 `ff_file_transfer_ftp` / `ff_file_transfer_ftp2` |
| 任务模型 | `FileTransferTaskManager` + `FileSenderTask` / `FileReceivingTask`，`readNextBlock()` / `sendNextBlock()` 分块推进，`getKnownFolders()` 枚举盘符与已知目录 |
| 断点续传 | 临时文件 + 元数据：`file_transfer_temp_lookup`（失败原因 `metadata_missing`）、`file_transfer_temp_clear`；UI 文案"文件信息变更，无法断点续传" |
| 限速 | `shared::file_transfer::ByteTokenBucket`；UI 文案"全速文件传输属于会员专属权益" |
| 接收归类 | 默认保存目录按类型区分（`picture` / `Pictures` 字面量紧邻 `file_transfer` 模块的字符串段） |
| UI 能力 | 双栏"发送路径/接收路径 + 传输列表"、暂停/全部开始/全部暂停/全部取消/清除完结任务、覆盖冲突 `%1 已存在，是否替换？`＋"保留两者/应用到全部文件"、被控端拖拽悬浮窗、剪贴板互传、移动端"传输文件存储路径" |

结论：UU 的"照片传输"并不是独立协议，而是**在文件传输任务上叠加按类型的落盘归类、缩略图预览和移动端相册入口**。CrossDesk 已有的
`file_transfer::Session`（64 KiB 块、1 MiB 窗口、ACK 驱动、`file`/`file_feedback`
两条可靠 DataChannel）已覆盖其数据面，缺的是**预览与归类**这两层。

因此本次实现**完全不改线格式**（`FileChunkHeader` 仍为 31 字节、`FileTransferAck`
仍为 28 字节、`kFileChunkSize` 仍为 64 KiB、iOS 手写解析不受影响），只增加：

1. 控制通道新操作 `gallery`（相册分页列表）与 `thumb`（缩略图）；
2. 被控端照片缩略图生成（stb，静态链接，不新增第三方依赖）；
3. 接收端照片归类到 `<接收目录>/Photos/<YYYY-MM>/`；
4. 相册窗口与远端分辨率无关的缩略图缓存。

## 2. 协议（复用控制通道 `control_data`，JSON 版本仍为 `version: 1`）

`type: "file_browser"` 信封保持不变，新增两个 `op`：

### 2.1 `op: "gallery"`（分页，与 `op: "list"` 同一套游标机制）

```json
{"type":"file_browser","version":1,"op":"gallery","id":7,
 "path":"@photos","recursive":1,"pagination":1}
```

- `path`：`@photos`（被控端 Pictures，缺省回落到主目录）、`@home`、`@desktop`，或任意绝对目录。
- 返回与 `list` 同构：`{ok, path, parent, entries[], offset, total, truncated, next}`，
  `entries[]` 每项为
  `{name, path, directory:false, size, modified:"YYYY-MM-DD", modified_ms, album:"<文件夹>/<YYYY-MM>", extension, width:0, height:0}`。
- 只枚举常规文件、跳过符号链接与隐藏目录、深度 ≤6、条目 ≤4096（超出置 `truncated`），
  按修改时间倒序；`op:"list_cancel"` 同样可释放相册快照。

### 2.2 `op: "thumb"`（单次、非分页）

```json
{"type":"file_browser","version":1,"op":"thumb","id":8,"path":"C:\\Users\\me\\Pictures\\a.jpg","edge":192}
```

- 返回 `{ok:true, kind:"thumb", path, data:<base64 JPEG>, width, height, source_width, source_height}`。
- 编码预算 34000 字节（base64 后 ≈45 KB，低于控制通道 60000 字节上限）；
  超限时依次用较小边长（192/144/96/48）与较低质量（78/55）重试。
- 被控端有 256 条 LRU 缓存，键为 `path|mtime_ms|edge`，滚动相册不会重复解码。

## 3. 代码位置

| 文件 | 作用 |
| --- | --- |
| `libs/controller/include/photo_library.h`、`src/photo_library.cpp` | 相册扫描、扩展名判定、缩略图生成（stb 静态）、base64、接收归类（构建目标 `crossdesk_photo`） |
| `libs/controller/include/file_browser.h`、`src/file_browser.cpp` | `Gallery()` / `Thumbnail()` 客户端 API；`gallery` / `thumb` 服务端实现；事件按 `channel` 分流（相册事件不打扰双栏窗口） |
| `libs/wire/include/remote_action.h`、`src/remote_action.cpp` | 能力位 `supports_photo_gallery`（旧端缺字段即 false） |
| `apps/desktop/src/gui/features/photo/photo_gallery_window.{h,cpp}` | 相册窗口（双模式）：缩略图批量请求与重试、相册筛选、目录上下导航、多选下载、批量发送、剪贴板图片、本机模式推送 |
| `apps/desktop/src/gui/ui/photo_gallery.slint` | 相册界面（`crossdesk_ui.slint` 导出 `PhotoGalleryWindow` / `PhotoTile`） |
| `apps/desktop/src/gui/features/file_transfer/file_transfer_manager.{h,cpp}` | `OpenGallery` / `GallerySupported` / `PhotoSaveDirectory`；接收完成后的照片归类 |
| `apps/desktop/src/gui/runtime/peer_data_callbacks.cpp` | 依据 `host_info` 协商 `supports_photo_gallery` |
| `apps/desktop/src/gui/application/gui_application.{h,cpp}` | 窗口生命周期、会话工具栏入口、主窗口「照片相册」入口、多选图片选择器、"打开相册目录" |
| `apps/desktop/src/gui/ui/stream_window.slint` | 会话工具栏新增照片按钮与 `photo-gallery` 回调 |
| `apps/desktop/src/gui/ui/main_window.slint` | 主窗口菜单新增「照片相册」项与 `open-photo-album` 回调 |
| `apps/desktop/src/gui/ui/ui_localization.h`、`localization/catalog.json` | 两款新文案的 10 语言词条 |
| `apps/desktop/src/config_center/config_center.{h,cpp}` | `photo_group_by_date`（默认 `true`） |
| `libs/controller/tests/photo_library_test.cpp` | 相册/缩略图/归类回归测试（`crossdesk_photo_test`） |

## 4. 使用

### 4.1 控制端（看/取远端照片）

1. 建立远控会话 → 会话工具栏倒数第二个「图片」按钮。
2. 左侧按"相册"（文件夹 + 年月）筛选；上方「上级目录」「照片根目录」切换位置。
3. 勾选照片 → **保存到本机**：`file_browser` 的 `op:"copy"` 下行，落盘到
   `<接收目录>/Photos`（接收目录 = 设置里的"文件接收保存路径"，空则桌面），完成 1 秒后自动刷新。
4. **发送照片**：原生多选对话框（jpg/jpeg/png/webp/gif/bmp/heic/tif/tiff）→ 上行为
   被控端当前相册目录。
5. **发送剪贴板图片**：Windows 下读取 `CF_DIB` → PNG → 走同一上行通道。
6. 双击某张 = 立即下载这一张。

### 4.2 被控端（把本机照片推给控制端）

1. 主窗口右上角菜单 →「照片相册」。
2. 同一套界面，但数据来自本机磁盘扫描、缩略图本地解码（不走网络）。
3. 选中后用「发送照片」/「发送剪贴板图片」，文件通过既有可靠文件流推给
   **当前选中的会话**；接收端仍会自动归入 `Photos/<YYYY-MM>/`。
4. 未选中任何会话时，发送按钮保持不可用（状态栏给出提示）。

### 4.3 落盘规则

普通文件往来若落在接收目录根下且是图片，会被自动归入 `Photos/<YYYY-MM>/`
（`photo_group_by_date=false` 可关闭，写在 `config.ini` 的 `[Settings]`）。

## 5. 与 UU 远程的剩余差距

| 能力 | UU 远程 | 本次 CrossDesk |
| --- | --- | --- |
| 照片相册预览 | 靠文件列表 + 系统预览 | ✅ 原生缩略图网格列表、相册筛选 |
| 接收按类型归类 | ✅ | ✅ `Photos/<YYYY-MM>`（可关） |
| 剪贴板图片互传 | ✅ | ✅ Windows（其它平台回退提示） |
| 多选批量 | ✅ | ✅ 相册多选、系统对话框多选 |
| 暂停 / 全部暂停 | ✅ | ❌ 引擎无暂停态（需 `Session` 增加挂起语义） |
| 断点续传 | ✅（temp + metadata） | ❌ 见 `docs/` 报告：需新增临时文件与元数据校验 |
| 全速/限速（会员） | ✅ `ByteTokenBucket` | ❌ 应用层未限速 |
| 覆盖冲突策略 | ✅ 替换/保留两者/应用到全部 | ❌ 现有实现自动改名 |
| 手机相册 | ✅ MediaStore + 多选 | ❌ Android 仍单文件 SAF、iOS 单 URL |

## 6. 构建、目标与分发

```bash
xmake f -c -p windows -a x64 -m release --USE_CUDA=false -y
xmake b crossdesk_photo                                        # 新目标：相册库
xmake r crossdesk_photo_test                                   # 相册/缩略图/归类回归
xmake r crossdesk_wire_test                                    # 能力位 JSON 回归
xmake b crossdesk_ui                                           # Slint 界面
xmake b crossdesk                                              # 完整客户端
```

构建目标拓扑（`xmake.lua`）：

```
crossdesk_photo (static, C++20)         <- photo_library.cpp + stb(static)
  └─ crossdesk_file_browser (static)    <- file_browser.cpp（gallery / thumb RPC）
       └─ gui / crossdesk_ui            <- 相册窗口、工具栏与主窗口入口
  └─ crossdesk_photo_test (binary)      <- 回归测试
```

可直接分发目录（本轮生成）：`dist/CrossDesk-1.7.6-photo-win-x64/`，包含
`crossdesk.exe`、`slint_cpp.dll`、`wgc_plugin.dll`、`crossdesk_privacy_window.dll`、
`crossdesk_privacy_cursor_helper.exe`、`crossdesk_session_helper.exe`、
`crossdesk_service.exe`、`crossdesk_updater.exe`、`usbmmidd_v2/`（虚拟显示器驱动）
以及两个启动脚本；等价的压缩包为 `dist/CrossDesk-1.7.6-photo-win-x64.zip`（28 MB）。

Windows 构建需要 MSVC 2022 Build Tools 与 LLVM 的 `clang-cl`（`PATH` 内含
`C:\Program Files\LLVM\bin`），因为 `libyuv` 的包配置固定使用 `clang-cl`。
可与已安装版本并存的启动方式：设置 `CROSSDESK_INSTANCE_NAME` /
`CROSSDESK_PROFILE_NAME`（见仓库外 `run-crossdesk-dev.cmd`）。
