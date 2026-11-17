# 贡献指南

感谢你想帮忙。这个项目很小，规则也就几条。

## 报 Issue 前

先跑两个命令，把输出一起贴上来（**贴之前把里面的用户名/路径打码**）：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\HuaweiMouseTray.ps1 -Once

powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\HuaweiMouseTray.ps1 -TraceFile .\trace.log
```

`trace.log` 里记了 DPI 推导、图标加载、换色、每次 GoPlay 判定及原因，绝大多数问题看它就能定位。

请一并说明：Windows 版本、鼠标型号、是否插线、GoPlay 版本、缩放比例。

## 提 PR 前

- **兼容性红线**：必须能在 **Windows PowerShell 5.1** 上跑通。不要引入 PowerShell 7 语法
  （`??`、`?.`、`-Parallel`、三元运算符）、不要引入第三方模块。
- **编码**：`.ps1` / `.vbs` 用 **UTF-8 with BOM + CRLF**。没有 BOM 时 PowerShell 5.1 会按
  GBK 解码，中文注释和提示会变乱码。`.py` / `.md` / `.json` 用 UTF-8（无 BOM）+ LF。
- **零外部依赖**：主程序只用 .NET Framework / Win32 / `System.Windows.Forms` 里的东西，
  不下载、不联网、不写注册表（除非是用户明确点了「开机自启」）。
- **回调要过 `Invoke-Guarded`**：托盘/菜单回调里抛异常会变成一个看不懂的错误框，
  统一走 `Invoke-Guarded` 落 trace。
- **常驻开销**：全脚本只有一条 1 秒节拍。别再加定时器、别在节拍里做全量设备枚举
  （缓存 `MainWnd` 句柄、复用 BLE 实例的做法要保留）。
- **单实例**：不要绕过互斥体 `Local\HuaweiNearLinkBatteryTray`。
- **隐私**：不要把本机的 `settings.json`、`*.log`、蓝牙地址、用户名写进代码或文档；
  设备地址一律从参数/环境变量读。

## 提交信息

一句话说清「改了什么、为什么」，中文英文都行：

```
修复 150% 缩放下勾选框偏移
tray: 图标缓存按 DPI 变化失效时重建
```

## 新增设备支持

目前只针对 `CD28S-63`。如果你的鼠标型号不同但走的也是同一条路（BLE GATT 0x180F 电池 +
GoPlay `NeoUsb.log`），改这两个地方就够了：

- `Get-GoPlayLogBattery` 里的日志正则与 `power state` 语义；
- `Find-NearLinkInstance` 里的设备匹配规则。

`tools/probe/` 下有一堆当时摸协议用的脚本（HID 暴力枚举、GATT 直读等），可以拿来验证新设备。
