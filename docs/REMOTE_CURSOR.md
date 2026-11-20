# 远端鼠标：UU 风格控制端光标

控制端在远控窗口里显示的鼠标指针，按 UU远程 的做法实现：**由控制端自己绘制光标、
隐藏系统指针**，因此指针不会落后于视频帧，跨 Windows/macOS/Linux 被控端外观一致。

## 1. UU远程 的做法（证据）

对 `D:\UU远程\GameViewer\bin\GameViewer.exe` 的静态分析（字符串，地址为文件偏移）：

| 证据 | 位置 | 说明 |
| --- | --- | --- |
| `:/control/viewing_cursor_normal.svg` | `0x046259b8` | 控制端"正常/箭头"光标，矢量资源 |
| `:/control/viewing_cursor_hand.svg` | `0x04625a38` | 手型（可点击/链接） |
| `:/control/viewing_cursor_grab.svg` | `0x04625ab8` | 抓取（拖拽） |
| `:/control/viewing_cursor_disabled.svg` | `0x04625b38` | 禁止（不可放置） |
| `:/control/viewing_cursor_pen.svg` | `0x04625bb8` | 画笔/文本类 |
| `使用主控端鼠标` / `使用被控端鼠标` | `0x0466ece0` / `0x0466ec58` | 两种模式：控制端自绘 vs 被控端光标 |
| `有更好的兼容性，但鼠标显示受网络延迟影响。` | `0x0466ec88` | 即"用被控端光标"的代价 |
| `被控端无法提供鼠标光标，已切换到主控鼠标` | `0x0466fa38` | 智能鼠标的自动回退 |
| `鼠标模式` / `智能鼠标` / `游戏鼠标` / `仿真鼠标` | `0x0466eb98` 附近 | 三种鼠标模式 |
| `已启用「使用被控端鼠标」模式`、`快捷键 "%1" 可解锁鼠标` | `0x0466d148`、`0x0466f9a8` | 模式切换提示与解锁快捷键 |

也就是说 UU 的控制端有一整套**自绘光标资源（5 个形状）+ 模式切换**，默认走"主控端鼠标"。
CrossDesk 原来只用系统光标形状（`remote_cursor.slint` 的 `RemoteCursor.shape()` 映射到
`MouseCursor` 枚举），所以看起来跟 UU 不一样。

## 2. 本次实现

| 文件 | 作用 |
| --- | --- |
| `apps/desktop/src/gui/ui/cursors/uu_*.png` | 14 个自绘光标位图（64×64，白色实体 + 深色描边 + 柔光投影），由 `make_uu_cursors.py` 以 4× 超采样生成后降采样 |
| `apps/desktop/src/gui/ui/uu_cursor.slint` | `UuCursorStyle`（开关、尺寸、热区换算）+ `UuCursor`（按 `RemoteCursorShape` 选图） |
| `apps/desktop/src/gui/ui/stream_window.slint` | 远控视口里绘制光标 overlay：`MouseCursor.none` 隐藏系统指针，`Image` 跟随真实指针位置并按热区偏移 |
| `apps/desktop/src/config_center/config_center.*` | 新配置项 `remote_cursor_style`（`0` = UU 自绘，默认；`1` = 系统光标） |
| `apps/desktop/src/gui/application/gui_application.cpp` | 创建远控窗口时把配置写进 `UuCursorStyle.enabled` |

形状映射（`RemoteCursorShape` → 位图）：`default→arrow`、`pointer→hand`、`text→text`、
`help→help`、`wait/progress→wait`、`crosshair→crosshair`、`copy/alias→copy`、`move→move`、
`not_allowed/no_drop→disabled`、`grab/grabbing→grab`、`col/ew → resize_ew`、
`row/ns → resize_ns`、`ne/nw/se/sw → resize_diag`。热区（hotspot）按 64×64 源图定义后
按 `size/64` 缩放，箭头 tip 落在指针真实位置。

## 3. 切换与调参

```ini
; %LOCALAPPDATA%\CrossDesk\cache\config.ini  [Settings]
remote_cursor_style = 0    ; 0 = UU 风格自绘（默认），1 = 系统光标
```

光标尺寸在 `uu_cursor.slint` 的 `UuCursorStyle.size`（默认 `26px`），需要更大就改这里。

## 4. 验证

```bash
xmake b crossdesk_ui     # Slint 编译（含新 overlay 与图片资源）
xmake b crossdesk        # 完整客户端
```
进远控会话后：鼠标在画面内为自绘白色箭头/手型/文本条等，移出画面即消失；把
`remote_cursor_style` 改成 `1` 重启后回到系统光标（原行为）。

## 5. 鼠标模式（UU 的"智能 / 游戏 / 仿真"三选一，已实现）

设置页「鼠标模式」下拉，等价 UU 的三种模式，立即生效并写入 `config.ini`：

| 模式 | 行为 | 关键实现 |
| --- | --- | --- |
| 智能鼠标（默认，0） | 控制端自绘光标；被控端把光标隐藏时（打字、系统隐藏、无鼠标设备）**保持最后形状**继续显示定位符，不再闪回系统箭头 | `CursorPresentation::Resolve` 的 `system_hidden_ && locator_allowed_` 分支已对所有被控平台生效（原来只对 macOS） |
| 游戏鼠标（1） | 只发**像素增量**，指针被 `ClipCursor` 限制在远控视图内，靠近边缘自动回中，可无缝转圈；`Esc` 在本地解锁（不转发给被控端）；速度档 0.5×~3× | 新增 `MouseFlag::relative_move`；控制端 `SendGameMouseMove` + `platform/common/gui/game_mouse.*`；被控端 `mouse_controller.cpp` 用 `MOUSEEVENTF_MOVE` 注入相对位移 |
| 仿真鼠标（2） | 回到系统光标 + 绝对坐标（兼容老被控端/异常环境） | 关闭 `UuCursorStyle.enabled`，走原有绝对路径 |

相关配置项（`config.ini` 的 `[Settings]`）：

```ini
remote_cursor_style = 0    ; 0 = UU 风格自绘光标，1 = 系统光标
remote_mouse_mode   = 0    ; 0 = 智能，1 = 游戏，2 = 仿真
game_mouse_speed    = 10   ; 游戏鼠标速度，单位 0.1×（5..30，默认 1.0×）
```

界面位置：主窗口 → 右上角菜单 → 设置 → 「鼠标模式」分组（模式下拉 + 游戏速度下拉，
非游戏模式下速度项置灰）；远控窗口底部在游戏模式激活时显示"按 Esc 退出游戏鼠标"提示条。

## 6. 兼容性说明

`relative_move` 是新增的 `MouseFlag` 枚举值（= 9），JSON 结构不变，老被控端读到未知
flag 会走 `default` 分支忽略该事件，因此**混合版本只会退化为不移动**，不会误操作；
两端都升级后游戏鼠标才生效。`wire_test` 里已断言 `move=0 / wheel_horizontal=8 /
relative_move=9` 与相对位移的 JSON 往返，防止枚举顺序被意外改动。

## 7. 本轮验证

```bash
xmake b crossdesk_ui        # 设置页新分组 + 游戏模式提示条 + 自绘光标 overlay
xmake b crossdesk           # 完整客户端 build ok
xmake r crossdesk_wire_test # 鼠标/光标 wire 值 + 相对位移往返（EXIT=0）
xmake r crossdesk_photo_test# 相册回归未受影响
```
部署：`%LOCALAPPDATA%\Programs\CrossDeskPhoto\crossdesk.exe`（已重启，PID 见运行状态），
分发包 `dist/CrossDesk-1.7.6-photo-win-x64.zip` 已同步。

## 8. 仍未覆盖（平台差异）

- `SKIP: macOS/Linux 被控端的相对位移注入 — 需要各自的 CGEvent/XTEST 分支，当前只有 Windows 分支实现（其它平台收到 relative_move 会被忽略，自动落回绝对坐标）`
- `SKIP: 游戏鼠标在被控端为 Wayland 会话时的边缘回中 — 依赖 X11 才能 SetCursorPos 级控制`
