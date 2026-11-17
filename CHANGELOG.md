# 更新记录

## 1.0.0 — 2026-11-17

首次开源发布。

- 任务栏托盘：悬停看电量/充电状态，左键拉起 HUAWEI GoPlay，右键菜单管理全部设置
- 电量双源：后台 GoPlay 的 `NeoUsb.log` 优先，过期（24h）后退回 Windows 缓存的 BLE 电池属性
- 图标三档变色 / 跟随系统深浅色；细、粗两套图标，按 DPI 原生像素渲染
- GoPlay 单实例、关闭判定闸门（存活时长 + 连续可见时长）、启动残留清理
- 托盘自身单实例互斥体 + 残留实例清扫
- 开机自启、自定义显示名、`-Once` 自检、`-TraceFile` 全链路追踪

开源整理时的改动：

- 去掉所有本机硬编码路径：GoPlay 目录改为注册表探测 + `settings.json` 的 `goPlayPath`
  + 环境变量 `HUAWEIMOUSETRAY_GOPLAY`；`NeoUsb.log` 改用 `%LOCALAPPDATA%`
- 探测脚本 `read_gatt.ps1` 不再内置蓝牙地址，改为必填参数
- `thinIcon` 默认值修正为 `true`（与说明书、`settings.example.json` 一致）
- 提交 `settings.example.json` 代替个人 `settings.json`；日志、exe、`__pycache__` 不再入库
- 旧的图标生成脚本移入 `tools/legacy/`
