# iOS `.ipa` 打包与签名（CI + 本机 Windows）

先给结论：

- **官方 `build-ios.yml` 原来不产 `.ipa`**，它产的是**未签名 `.app` 的 zip**（artifact 名 `crossdesk-ios-arm64-unsigned-<version>`，内部 `Payload` 都没有，就是 `CrossDeskMobile.app` + dSYM）。
- 我已在工作流里补了两步：**产未签名 `.ipa`**；如果配置了证书 Secrets，**再产一个已签名 `.ipa`**。（`build-ios.yml` 现在 25 个 step，YAML 已用 PyYAML 解析校验通过。）
- 你手上有 p12 + mobileprovision 的话，**在你这台 Windows 上就能直接签出可安装的 ipa**，不需要 Mac、不需要连 Apple 服务器。

## 一、GitHub Actions：产 `.ipa`

### 1. 加 Secrets（仓库 Settings → Secrets and variables → Actions）

| Secret | 内容 | 生成命令（Windows PowerShell） |
| --- | --- | --- |
| `IOS_CERT_P12_BASE64` | 证书 `.p12` 的 base64 | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12")) > cert.b64` |
| `IOS_CERT_PASSWORD` | p12 密码（明文） | — |
| `IOS_PROVISION_BASE64` | `.mobileprovision` 的 base64 | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("app.mobileprovision")) > prov.b64` |

> 三个都配了才会走签名步骤；只配前两个或都不配时，只产未签名 ipa。

### 2. 触发

```bash
gh workflow run build-ios.yml --repo <你的fork>/crossdesk
gh run watch
gh run download -n crossdesk-ios-arm64-unsigned-<version>   # 未签名（含 .app.zip 与 .ipa）
gh run download -n crossdesk-ios-arm64-signed-<version>     # 签名版 .ipa（配了证书才有）
```

### 3. 工作流新增的两步做了什么

- **Package unsigned IPA**：把 `CrossDeskMobile.app` 放进 `Payload/`，`zip -qry` 成 `CrossDesk-iOS-<ver>-unsigned.ipa`；
- **Sign IPA with the supplied certificate**：把 p12 导入临时 keychain → `security find-identity` 取签名身份 →
  写入 `embedded.mobileprovision` → 从 profile 提取 `Entitlements` → 先签 `Frameworks/*.framework`、再签主 App →
  重新打成 `CrossDesk-iOS-<ver>-signed.ipa`。

## 二、本机 Windows 签名（已装好工具，可离线）

工具：`dist/tools/zsign/zsign.exe`（zsign v1.1.3 官方 Windows 版，已下载并实测通过）：

```powershell
cd C:\Users\Mayn\Documents\deepseek-harness\default-workspace

# 用你的证书 + 描述文件签名（把路径换成你的）
dist\tools\zsign\zsign.exe `
  -k "D:\certs\apple-dist.p12" -p "你的p12密码" `
  -m "D:\certs\CrossDesk.mobileprovision" `
  -o "dist\CrossDesk-iOS-signed.ipa" `
  "dist\CrossDesk-iOS-1.7.6-unsigned.ipa"
```

常用附加参数（`zsign` 自带）：

| 参数 | 用途 |
| --- | --- |
| `-b com.example.crossdesk` | 改 bundle id（必须与 profile 的 App ID 匹配） |
| `-n "CrossDesk 照片版"` | 改显示名 |
| `-r 1.7.6-photo` | 改版本号 |
| `-e entitlements.plist` | 指定 entitlements（profile 里的不够用时） |
| `-l libxxx.dylib` | 注入 dylib（可多次，用于 Frida 之类调试） |
| `-z 9` | 最高压缩 |
| `-C` | 检查证书有效期与 OCSP 吊销状态 |

本机实测（adhoc，仅验证工具链路，不需要证书）：

```
>>> SignFile: CrossDeskMobile            → Realloc CodeSignature space... Success!
>>> SignFolder: Frameworks\OpenSSL.framework (OpenSSL) → Success!
>>> Signed OK! (0.095s)  →  Archive OK! (26.11 MB)  →  Done. (0.409s)
```

## 三、装机前置条件（容易踩）

1. **profile 里必须有目标 iPhone 的 UDID**（Ad Hoc / Development 类型）；企业证书（In-House）不需要 UDID，但要有企业账号。
2. **bundle id 必须和 profile 的 App ID 一致**：官方包是 `com.chunkdash.crossdesk`，你的 profile 若不是这个，用 `zsign -b` 改成你的（同时 CI 侧也可改工程里的 PRODUCT_BUNDLE_IDENTIFIER）。
3. 免费 Apple ID 的 7 天 profile 也能签，用 Sideloadly 生成更省事（它自动做 1、2 两步）。
4. iOS 16+ 设备需在「设置 → 隐私与安全性 → 开发者模式」打开并重启。

## 四、现状与边界

- 我给的 `dist/CrossDesk-iOS-1.7.6-unsigned.ipa` 是**官方 1.7.6 二进制**（无相册/UU 光标），签名能装、能远控，但功能就是官方版。
- 要「带相册的 iOS 版」必须先有**新的 iOS 二进制**：在 `apps/ios` 补 SwiftUI 代码 → 走上面这条 CI 出包 → 再用你的证书签。`SKIP: 本机直接编译 iOS 二进制 — 无 macOS/Xcode`
