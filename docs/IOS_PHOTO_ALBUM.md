# iOS 控制端照片相册（源码已落地，待 CI 编译）

给 iOS 控制端补上照片相册。协议与桌面端完全一致，**不需要改任何 C++ 线格式**：

| 操作 | 报文 |
| --- | --- |
| 相册列表 | `{"type":"file_browser","version":1,"op":"gallery","id":N,"path":"@photos","recursive":1,"pagination":1}`（分页用 `cursor`） |
| 缩略图 | `{"type":"file_browser","version":1,"op":"thumb","id":N,"path":"<绝对路径>","edge":192}` → 回包 `data` 是 base64 JPEG |
| 下载原图 | `{"type":"file_browser","version":1,"op":"copy","id":N,"paths":[...],"destination":"Received","transfer_id":"<uuid>"}`；主机随后发 `op:"prepare"`（我们回 `{"op":"reply","id":..,"ok":true}`），原图走既有文件通道落到 `Documents/Received` |

## 改动清单

| 文件 | 内容 |
| --- | --- |
| `Bridge/CrossDeskRTCBridge.h` | 新增 `-sendPhotoMessage:`（`NS_SWIFT_NAME(sendPhotoMessage(_:))`）与 delegate `rtcBridge:didReceivePhotoMessage:` |
| `Bridge/CrossDeskRTCBridge.mm` | ① `handleData` 的 `kControlStream` 分支在交给 `RemoteAction::from_json` **之前**拦截含 `"file_browser"` 的 JSON，原样转给 Swift（否则会被数字 type 解析器丢弃并 `return`）；② `sendPhotoMessage:` 在 `_rtcQueue` 上通过 `MiniRtcSendReliableDataFrame(..., kControlStream)` 发送，上限 60 KB |
| `PhotoGallery.swift`（新增） | `PhotoGalleryStore`（分页请求/缩略图/选择/下载状态机，含 `op:"prepare"` 应答）与 `PhotoGalleryView`（相册胶囊筛选 + `LazyVGrid` 缩略图网格 + 底部工具栏） |
| `RemoteSessionModel.swift` | 持有 `photoGallery`，init 里接上 `sendMessage`；delegate 转发 `didReceivePhotoMessage`；`didReceiveFileAtURL` 里通知相册计数 |
| `RemoteSessionView.swift` | 左下角「照片」胶囊按钮 + `.sheet` 呈现相册 |
| `CrossDeskMobile.xcodeproj/project.pbxproj` | 登记 `PhotoGallery.swift`（PBXFileReference + PBXBuildFile + group children + Sources 阶段） |

## 已做的静态校验（Windows 上能做的部分）

```
project.pbxproj: 花括号 146/146 平衡，圆括号平衡，PhotoGallery 相关条目 6 处，新增两个 ID 各出现 2 次（引用+构建各一次）
Swift 文件:      PhotoGallery.swift 88/88、RemoteSessionModel.swift 363/363、RemoteSessionView.swift 365/365 花括号平衡
编码:            全部 touched 文件通过 UTF-8 解码校验
编译:            SKIP —— 需要 macOS/Xcode（本机无 Apple 工具链）
```

已修掉两个自查出的编译级问题：

1. `PhotoGalleryStore` 原本标了 `@MainActor`，而 `RemoteSessionModel` 不是 main-actor 隔离的，作为存储属性初始化会报错 → 去掉标注（所有变更本来就发生在主队列：桥接用 `DispatchMain`，UI 在 SwiftUI 中）。
2. 捕获列表用了 `[weak bridge]`（属性不能这样捕获）→ 改为 `[weak self]` + `self?.bridge.sendPhotoMessage(data)`。

## 出包

```bash
# 你的 fork，先在 Settings → Secrets 配三个（见 docs/IPA_SIGNING.md）
gh workflow run build-ios.yml
gh run download -n crossdesk-ios-arm64-signed-<version>   # 带相册的签名 ipa
```

产物里 `.ipa` 由 CI 打包（我已加 `Package unsigned IPA` 与签名两步），再用 Sideloadly 装到 iPhone。

## 未覆盖

- `SKIP: 本机编译/验证 iOS 代码 — 无 macOS/Xcode，Swift 只能静态自查（括号平衡、符号与选择器一致性、属性可见性），最终以 CI 编译结果为准`
- `SKIP: 保存到系统相册（Photos）— 未加 NSPhotoLibraryAddUsageDescription，当前保存到 Documents/Received，可在「文件」App 里看到；要写相册就加 Info.plist 权限键并调用 PHPhotoLibrary`
- `SKIP: 手机端"从相册挑图发给远端" — 需要接上传链路（UIImage → 临时文件 → sendFileAtURL），相册模块暂只做浏览与下载`
