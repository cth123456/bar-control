# Bar Control 0.15.0（原生 Swift 版）

这是一个独立的 macOS 菜单栏 App，不调用、不启动、也不依赖 BetterTouchTool。

主层默认布局：

- 动态随航、`AI coding`、系统监控、本地语音助手
- 随航空闲时保持紧凑深灰色；操作时在当前层展开，变蓝并显示四帧转动进度；成功变绿、失败变红后再缩回
- `AI coding` 保持紧凑蓝色胶囊，图标颜色表示 Codex 状态
- 本地模型空闲时只显示语音图标；运行时固定为紧凑 82pt，用“说话、识别、本地、云端、准备、播放”短词配合颜色与图标换帧，RunCat 不会再被自动展开遮挡
- 整机监控在主层只显示一个 RunCat 风格动画，不再显示 `M70 / G53` 一类缩写；动画速度由整机实时功率驱动，颜色随功率从绿色、青色变为橙色、红色

菜单栏“更多操作 → Touch Bar 动图”可以即时切换跑猫、咖啡、跑狗、水滴、引擎、麻薯、牛顿摆和史莱姆；选择会保存到下次启动，不再需要单独安装 RunCat。

菜单栏“更多操作 → Touch Bar 保持最亮”默认开启。App 使用系统 `DFRBrightness` 的真实调光档位 1，仅在 Touch Bar 已点亮时校正亮度，不会在屏幕休眠后反复唤醒面板。关闭开关后，App 停止干预，亮度重新交由系统后续的空闲调光流程管理。

主层、AI coding 详情层和整机详情层都从系统关闭按钮后方开始向左排列，不再把整块容器设置为会被 AppKit 强制居中的 principal item。组件内部顺序仍按“自定义 Touch Bar 组件…”保存的设置排列。

点击跑猫会进入真正的 Touch Bar 整机详情层，而不是打开菜单栏菜单。详情层依次显示完整中文名称：整机功率、内存占用、GPU 占用、电池温度、电池状态和端口功率；端口功率同时显示实时输入与 USB-C 输出，最左侧返回按钮回到主层。

菜单栏展开后是参考用户提供的 AIdente 截图重做的完整能源流面板。面板本身不绘制任何整块背景、渐变、环境光或信息外框，直接透出与其他菜单项相同的 macOS 原生菜单材质；只有节点和流线保留必要的局部低透明度底色。顶部重复的摘要卡和电量条已移除，面板更紧凑。虚线沿实际供电方向移动：输入为充电器到 Mac、输出为 Mac 到外设，电池支路按充放电角色反向；没有外接输出时不会显示虚假支路、空节点或 USB-C 占位。

电池信息始终明确显示百分比和实时方向：`充电 +x.x W`、`放电 −x.x W` 或 `保持 0.0 W`。仅靠电池供电时，电池本身直接作为能源流源节点，不再重复画第二个电池节点。

App 每秒读取 `AppleSmartBattery.PowerTelemetryData` 的实时输入和整机负载，并读取 `PowerOutDetails` 的逐端口 USB-C 输出。能识别的 iPad、iPhone、AirPods 等显示设备名；充电线未提供 USB 设备身份时仍显示 `USB-C 设备 · 端口 N`、方向和功率。35W/67W/85W 等值只标作 USB-PD 协商上限，不冒充实时功率。菜单打开时立即采样，刷新计时器使用通用运行循环模式，在 macOS 菜单跟踪期间仍持续更新。

GPU 显示为 IORegistry 每秒采集的瞬时占用，综合设备、渲染器和平铺器三个利用率字段；完全空闲时显示 0% 属于正常实时值。

菜单栏的“自定义 Touch Bar 组件…”可以对四个主层模块分别：

- 显示或隐藏
- 用滑杆调节宽度
- 用上下箭头改变排列位置
- 一键恢复默认布局

点击 `AI coding` 进入二级层：

- 最左侧返回按钮
- 自动读取 CC Switch 的 Claude、Codex、Gemini、Grok、OpenCode、Hermes 使用数据；当前供应商为自定义 API 时显示费用、请求数和预算进度
- 当前供应商为官方账号登录时，忽略残留的历史 API 日志，显示 QuotaStrip 风格的 5h / 7d 订阅额度条
- 只显示正在运行的 Codex 任务，最多五项；空闲时不显示说明文字；点击可打开对应任务

App 同时保留两个唤回入口：Touch Bar 的 Control Strip 图标和始终显示 `AI` 文字的 macOS 菜单栏入口。即使关闭了展开层，也可以重新显示，不会依赖二级菜单里的按钮自救。

首次启动后，App 会通过 macOS 原生登录项注册开机自启动；不使用额外 LaunchAgent，也不会启动 BetterTouchTool。

八套共 50 帧动画素材来自 [RunCat Neo](https://github.com/runcat-dev/RunCatNeo)，按 Apache License 2.0 使用；完整许可与改动说明随 App 打包在 `Contents/Resources/ThirdParty`。

逐端口 USB-C 遥测实现参考了开源项目 [WhatPort](https://github.com/darrylmorley/whatport) 与 [macpow](https://github.com/k06a/macpow) 对 macOS IOKit/USB-PD 字段的公开验证，代码在本项目中独立实现，没有引入它们作为运行时依赖。

本地模型通过 `~/Library/Application Support/LocalSiriLLM/touchbar-state.tsv` 向原生 App 发布阶段，不再调用或启动 BetterTouchTool。活动期间再次点击同一模块会取消准备、录音、识别、推理、朗读和播放。

## 构建与安装

双击 `install.command`，或运行：

```sh
./install.command
```

## Touch Bar 亮度

macOS 没有公开的 Touch Bar 面板亮度 API，但系统私有 `DFRBrightnessClient` 在当前机型上提供真实的 OLED 调光档位。App 默认把已点亮的 Touch Bar 保持在最亮档 1；每 5 秒仅在档位被系统改低时校正一次，不会在 Touch Bar 已关闭或整机休眠时唤醒它。可在“更多操作 → Touch Bar 保持最亮”随时关闭。

## CC Switch

App 以只读方式访问 `~/.cc-switch/cc-switch.db`，不会读取或修改供应商密钥。自定义 API 供应商显示费用卡；官方账号登录显示 Codex 订阅额度，历史 API 日志不会覆盖当前模式。点击费用卡或菜单栏的“打开 CC Switch”可进入 CC Switch。只有在当前 API 供应商设置日预算或月预算后，费用卡才显示百分比进度。
