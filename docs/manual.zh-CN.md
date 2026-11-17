# HUAWEI 星闪鼠标 · 任务栏电量托盘 — 说明书

任务栏通知区放一个星闪鼠标图标：悬停看电量/充电状态，左键打开 HUAWEI GoPlay，
右键管图标样式、GoPlay 关闭策略和开机自启。

- 目标设备：`HUAWEI Mouse CD28S-63`（蓝牙 LE / USB 双模）
- 运行环境：Windows 11 + Windows PowerShell 5.1（不需要 .NET SDK、不需要装 Python）
- 常驻资源：1 个 powershell 进程，1 条 1 秒节拍

---

## 1. 启动 / 自启 / 重启

| 想干什么 | 怎么做 |
| --- | --- |
| 启动 | 双击桌面上的 `HuaweiMouseTray`（快捷方式带 `-Restart`） |
| 静默启动（不闪黑框） | `wscript.exe //nologo start-hidden.vbs` |
| 重启（图标不见了） | 同上；`-Restart` 会先结束旧实例再起新的 |
| 退出 | 右键图标 → **退出** |
| 开机自启 | 右键菜单勾「开机自动启动」，写 `Startup\HuaweiMouseTray.lnk` |

> 图标被折叠进 `^` 溢出区时：打开 `^` 把图标拖到任务栏，Windows 会记住（`IsPromoted=1`）。

---

## 2. 菜单

```
HUAWEI Mouse CD28S-63   电量 95% 充电中     ← 状态行（不可点）
───────────────────────────────
打开 HUAWEI GoPlay
立即退出 HUAWEI GoPlay
立即刷新
───────────────────────────────
个性化 ▸
   ├ 按电量变色                    ☑ 开 = ≥60 绿 / 36–59 黄 / ≤35 红
   │                                 ☐ 关 = 跟随系统（浅色→黑标，深色→反白）
   ├ 图标粗细：细 ▸
   │    ├ 细
   │    └ 粗
   ├ 设置鼠标名称…
   └ 关闭 GoPlay 时 ▸
        ├ 最小化到托盘（留在后台）
        └ 直接退出（不留后台进程）
───────────────────────────────
开机自动启动
退出
```

菜单深浅色跟随系统、强调色取自「设置 → 个性化 → 颜色」，勾选框自绘，按 DPI 原生像素渲染。

---

## 3. 设置（`settings.json`）

改完立即写回；也可以只用右键菜单操作。手动编辑时**存成 UTF-8**。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `goPlayClose` | `"exit"` | `exit` = GoPlay 点 X 后结束进程；`minimize` = 留在后台 |
| `levelColor` | `true` | 按键值三档变色 |
| `thinIcon` | `true` | `true` 细图标 / `false` 粗图标 |
| `displayName` | `""` | 自定义名称，空则用设备名 |
| `goPlayCloseMinAlive` | `5.0` | 判定「用户关掉了」所需的进程存活秒数 |
| `goPlayCloseMinVisible` | `0.5` | 判定所需的窗口连续可见秒数 |
| `killGoPlayOnExit` | `false` | 退出托盘时是否把 GoPlay 一起结束 |

示例：

```json
{
  "displayName": "",
  "goPlayClose": "exit",
  "levelColor": true,
  "thinIcon": true,
  "goPlayCloseMinVisible": 0.5,
  "goPlayCloseMinAlive": 5,
  "killGoPlayOnExit": false
}
```

---

## 4. 电量与充电状态从哪来

**首选：GoPlay 的 USB 日志** `%LOCALAPPDATA%\HUAWEI GoPlay\NeoUsb.log`

GoPlay 在后台轮询时写两种行：

```
PowerValue=100 and n_nIsPowering=1
get power value 100 power state 1
```

`power state` 的语义（按历史日志统计得出）：

| state | 含义 | 托盘显示 |
| --- | --- | --- |
| 0 | 没插线，电池供电 | `电量 90%` |
| 1 | **插着线在充电** | `电量 90% 充电中` |
| 2 | 插着线且已充满（历史记录里永远出现在 100%） | `电量 100% 已充满` |

日志超过 **24 小时**没更新就视为失效，退回蓝牙兜底。

**兜底：Windows 缓存的 BLE 电池属性**（`CfgMgr32` 的 `CM_Get_DevNode_PropertyW`，单次约 0.15 ms）。
此时提示里会多一个「（缓存）」，而且**没有充电状态**——蓝牙属性里只有电量。

> 想让充电标记一直准，GoPlay 得在后台跑着；彻底退出 GoPlay 后只能看电量。

---

## 5. 单实例规则（tray 至多 1 个、GoPlay 至多 1 个）

**托盘**

- 互斥体 `Local\HuaweiNearLinkBatteryTray`：抢不到锁的实例直接退出，只提示「托盘已经在运行了」。
- 拿到锁之后，再扫一遍 `powershell.exe` 里命令行带本脚本路径的进程，**把残留实例清掉**
  （排除自己和父进程）。这样历史遗留的「僵尸托盘」不会把新实例挡在门外。

**GoPlay：平时不该在场，点了才出现**

核心规则一句话：**任何时刻只有托盘在场；GoPlay 只在你点击之后存在，关掉就必须彻底消失。**

- 窗口从可见变隐藏（点 X）→ 满足第 6 节的门槛就结束进程；
- **节拍每 5 秒去重**：发现多个 `HUAWEI GoPlay` 只留一个，优先留**有可见主窗口**的，
  都没有窗口时留**启动最早**的，其余强制结束；
- **启动 GoPlay 前先去重**，再决定「唤回已有窗口」还是「新起一个」；
- **托盘启动时清残留**：自己起来的时候，若发现 GoPlay 在后台憋着（没有可见主窗口），直接结束；
- **从没露过脸的算残留**：GoPlay 若始终没显示过窗口、又已存活 ≥ 15 秒，按残留清掉
  （只在 `goPlayClose = "exit"` 时生效；设成 `minimize` 就关掉这条）；
- **退出托盘时**：`killGoPlayOnExit=true` 全结束；`false` 则只做一次去重（至多留 1 个）。

---

## 6. GoPlay 关闭判定是怎么做的

GoPlay 点 X 只是把主窗口（窗口类 `MainWnd`）隐藏，进程还在。托盘靠 1 秒节拍检测：

1. 缓存 `MainWnd` 句柄，稳态下每秒只做 `IsWindow` + `IsWindowVisible` 两次 API 调用；
2. 窗口从「可见」变「隐藏」时开始判定：
   - **进程存活 ≥ `goPlayCloseMinAlive`**（用进程真实 `StartTime` 计算，不受探测延迟影响）
   - **窗口连续可见 ≥ `goPlayCloseMinVisible`**
   - 且 `goPlayClose = "exit"`
3. 三条都满足才结束进程；否则写 `启动阶段 / 显示时间过短，忽略`。

> 为什么要有这道闸门：GoPlay **自己启动时会先亮一下窗口再隐藏**，与「用户点 X」外观相同。
> 用「存活时长」把启动瞬间排除掉。

---

## 7. 退出行为

右键 → 退出 会依次：停节拍 → 按配置处理 GoPlay → 隐藏并释放图标 → 释放互斥体 →
`Application.Exit()`。每一步都独立 try/catch，最后一步在 `finally` 里，
**任何一步抛异常都不会拦住退出**（早期版本这里会留下「进程活着但图标没了、锁还被占着」的假死状态）。

所有菜单/托盘回调都经过 `Invoke-Guarded`，异常一律写进 trace，不会弹一个看不懂的错误框。

---

## 8. 排错

**打开日志**（排查任何问题第一步）：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\HuaweiMouseTray.ps1 -TraceFile .\trace.log
```

记录内容：DPI 推导出的图标尺寸、加载了哪些图标、每次换色、每次 GoPlay 判定及原因、
每次菜单操作、退出全过程。

**自检（不建托盘，只读一次状态）：**

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\HuaweiMouseTray.ps1 -Once
```

```json
{"Connected":true,"Name":"HUAWEI Mouse CD28S-63","Level":100,"Charging":true,"Full":false,
 "GoPlayRunning":false,"GoPlayVisible":false,"GoPlayCloseMode":"exit",
 "LevelColor":true,"ThinIcon":true,"Icon":"...\\icons\\thin\\tray.ico","IconExists":true,"Autostart":true}
```

**现象对照表**

| 现象 | 先看什么 |
| --- | --- |
| 电量不动 | GoPlay 是否在跑（只有它在轮询才写 `NeoUsb.log`）；鼠标静止时上报也慢 |
| 没有「充电中」 | 是否插着线；`NeoUsb.log` 最后一条 `power state` 是几；GoPlay 是否被彻底退出 |
| 点 X 后 GoPlay 还在 | `trace.log` 搜 `GoPlay 窗口隐藏`，被忽略会写明原因（存活/可见时长不够） |
| 图标不在任务栏 | 溢出区 `^` 里找；或双击快捷方式走 `-Restart` |
| 提示「托盘已经在运行了」 | 双击快捷方式（带 `-Restart`），会先清理旧实例 |
| 菜单/勾选点了没反应 | `trace.log` 搜 `handler[`，异常都记在那儿 |
| 改了 150% 缩放后模糊 | `dpi-aware.ps1` 是进程级设置，重启托盘生效 |

---

## 9. 已知限制

1. **启动后 5 秒内关掉 GoPlay** 会被当成「启动闪烁」忽略——两者在 API 层面无法区分。
   想更激进就把 `goPlayCloseMinAlive` 调小（比如 2）。
2. **退出托盘后没人看门**：GoPlay 点 X 就真留在后台。要避免把 `killGoPlayOnExit` 设为 `true`。
3. 充电状态依赖 GoPlay 的日志；纯蓝牙模式下只能给出电量。
4. `trace.log` / `start.log` 会一直追加，偶尔删一下即可（不影响功能）。

---

## 10. 文件清单

| 文件 | 用途 |
| --- | --- |
| `HuaweiMouseTray.ps1` | 主程序：托盘、电量、单实例、GoPlay 策略、菜单 |
| `start-hidden.vbs` | 静默启动器（不闪控制台），透传参数 |
| `HuaweiMouseTray.exe` | 带内嵌图标的启动器（快捷方式指向它才有图标）；由 `tools\build_exe3.ps1` 生成，Release 里附带 |
| `dpi-aware.ps1` | 声明进程 DPI 感知，150% 下按原生像素渲染 |
| `menu-theme.ps1` | 菜单深浅色/强调色、自绘勾选框 |
| `settings.json` | 运行设置（见第 3 节）；仓库内提交的是 `settings.example.json`，首次运行可复制一份 |
| `icons/app.ico` | 应用图标（exe / 快捷方式，10 个尺寸） |
| `icons/thin/`、`icons/bold/` | 两套粗细，各含 `tray.ico` + `tray-green/yellow/red/white/black.ico` |
| `tools/` | 图标生成、exe 编译、HID/GATT 协议探测脚本；`tools\legacy\` 为已弃用的旧版 |

## 11. 重新生成资源

```powershell
# 托盘图标 + 应用图标（需要 Python + Pillow）
python tools\make_tray_icons_v3.py

# 重新编译 exe（内嵌 icons\app.ico）
powershell -File tools\build_exe3.ps1
```

`make_tray_icons_v3.py` 生成 `icons\thin|bold\tray*.ico`（每个 9 个尺寸）和 `icons\app.ico`。
轮廓数据直接从 `tools\mark-leaves.json` 读，**不需要原品牌 PDF**；要用别的 PDF 现场解析时，
设环境变量 `TRAY_PDF` 指向它即可。

> 重新生成的结果依赖 Pillow / numpy 的版本，换环境可能出现 1px 级差异；
> 仓库里提交的是作者本机验证过的成品，除非确实要改图标，否则不用重跑。

- **单色控制**：RGB 恒为同一个纯色，只有 alpha 变化；不把白底哑光烘进 RGB，
  黑底上就不会出现白边/灰边（对比图见根目录 `images/preview-before-after.png`）。
- 轮廓不再是"两片合一"的位图，而是从 `7.pdf` 里把两个 D 各自的矢量路径分开取出
  （存在 `tools\mark-leaves.json`），渲染时按 `GAP` 决定两片关系：
  **`GAP = 0`（当前）两片取并集，交叉处是实心的，即品牌原样**；
  把 `GAP` 改成 `0.014` 之类，两片会各退让一条发丝缝（`images/preview-crossing.png` 里那种切开的做法），
  改完重跑脚本即可来回切换。
- 小尺寸（16 / 20 / 24px，也就是托盘实际用到的三档）单独调了对比度曲线、亚像素对齐、
  占位和笔画粗细；32px 以上走平滑抗锯齿。
- 可调参数都在脚本顶部：`FILL`（占位）、`WEIGHT_THIN` / `WEIGHT_BOLD`（粗细）、
  `GAP`（两片之间的缝宽，0 = 连着）、`COLORS`（含 `tray-black` 的纯黑档）。
- `tools\legacy\` 里的 `make_tray_icons.py` / `make_tray_icons_v2.py` / `make_icon_levels.py` /
  `make_icon_v3.py` 已弃用，仅作历史参考：前者会把白底哑光或灰度糊边带进图标，
  v2 的两片在交叉处还是连着的。

icons\ 下的图标已随仓库提交；重新生成只需跑上面的脚本。
