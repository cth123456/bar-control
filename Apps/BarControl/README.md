# Bar Control 0.17.0（原生 Swift 版）

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

面板采用约 2:1 的竖构图：左侧电源卡，中部电池与 Mac，右侧最多三个第三层功耗端点；每根流量柱从入口到出口保持等宽，并与两侧模块连接边一致。多支路公共根部的上下边覆盖整机卡片的完整连接高度，但卡片本身保留完整圆角，并与流量柱留 17 设计像素的短间距，避免两者误连成一个模块。功率和同层数量共同决定柱宽，但第三层模块的连接边不低于 96 设计像素，第二、第三层图标都使用 64 设计像素下限，不会被压成细线或小点。多个第三层模块围绕整机节点均匀排开，模块间距上限为 64 设计像素，兼顾分组感和紧凑度。

第三层只显示整机的同级硬件功耗去向：实测外接设备、CPU、GPU，以及用“整机功耗－外接设备－CPU－GPU”得到的 `其他硬件`。进程通过 CPU、GPU 等硬件产生功耗，因此不再与 GPU 并列；已有进程采样保留给未来可能增加的第四层明细。每个端点都同时显示彩色原生图标和高对比度名称（如 `CPU`、`GPU`、`其他硬件`、`显示器`、`外接设备`），不再依赖颜色或小图形猜测类型。本机硬件没有提供的 CPU/GPU 通道会隐藏，不用整机总功率猜测或补值。第一层的放电电池卡片使用 132 设计像素的正常尺寸下限，电池图标使用 72 设计像素下限，不再随低功率压缩成小标签。

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
- 只显示当前、已管理或本月有用量的客户端；每个平台只显示一次真实软件图标，后面的账户/供应商按 CC Switch 名称排列
- Codex 可同时显示 CC Switch 管理的 ChatGPT 账号和 API 供应商；余额与单位沿用 CC Switch 的用量查询口径
- 点击账户进入三级详情层，显示真实近 7 日用量折线、缓存命中率、请求成功率、近期模型和请求数；不足两个不同样本时显示“等待变化”，不绘制误导性的水平直线
- 只显示正在运行的 Codex 任务，最多五项；空闲时不显示说明文字；点击可打开对应任务

App 同时保留两个唤回入口：Touch Bar 的 Control Strip 图标和始终显示 `AI` 文字的 macOS 菜单栏入口。即使关闭了展开层，也可以重新显示，不会依赖二级菜单里的按钮自救。

首次启动后，App 会通过 macOS 原生登录项注册开机自启动；不使用额外 LaunchAgent，也不会启动 BetterTouchTool。

八套共 50 帧动画素材来自 [RunCat Neo](https://github.com/runcat-dev/RunCatNeo)，按 Apache License 2.0 使用；完整许可与改动说明随 App 打包在 `Contents/Resources/ThirdParty`。

逐端口 USB-C 遥测实现参考了开源项目 [WhatPort](https://github.com/darrylmorley/whatport) 与 [macpow](https://github.com/k06a/macpow) 对 macOS IOKit/USB-PD 字段的公开验证，代码在本项目中独立实现，没有引入它们作为运行时依赖。

本地模型通过 `~/Library/Application Support/LocalSiriLLM/touchbar-state.tsv` 向原生 App 发布阶段，不再调用或启动 BetterTouchTool。活动期间再次点击同一模块会取消准备、录音、识别、推理、朗读和播放。

## 远程 Codex

菜单栏新增“远程 Codex 控制台…”。Mac 端通过本机 `codex app-server --stdio` 建立或继续会话，并把用户输入、计划、回复增量、命令输出、工具调用、文件变更、确认请求和完成状态逐条写入追加式事件日志。不是等整段回复结束后再显示，因此手机端能看到每个实际输出片段。

自然语言指令先由本机 Ollama 的 `local-siri-qwen:latest` 分类。普通编程要求交给 Codex；停止、查看供应商和切换供应商等控制意图在本机解析。供应商列表只读自 CC Switch；切换操作通过 CC Switch 可见界面的“启用”按钮完成，切换前备份现有配置，随后重启并探测 Codex app-server。首次真正切换时，macOS 会要求为 Bar Control 开启辅助功能权限。

账号或模型切换不会再创建新会话。Mac 会在 `config.toml` 中同时保留 `custom` 与 `cc-switch-official` 兼容入口，把 CC Switch 当前供应商的真实配置复制为两个逻辑别名；旧 DeepSeek 会话和新 OpenAI 会话因此都能找到自己的 provider。切换后，Bar Control 使用桌面 App 自带的同版本 Codex CLI，以轻量 `thread/resume` 方式重新挂接同一个 thread，并把当前模型覆盖到下一轮。Mac 登录后也会自动校准 provider、模型和最近使用的远程会话。

iPhone 客户端源码位于相邻目录 `../BarControlRemote`。Mac 与 iPhone 只通过同一 Apple ID 的 CloudKit 私有数据库交换命令和事件；手机不保存 Codex、CC Switch 或模型账号凭据，也不占用 VPN。CloudKit 不可用或当前签名不含权限时，Mac 端自动降级为仅本机控制台，不会影响 Touch Bar 主功能。

该方案没有自建服务器月租、第三方中转订阅或额外模型 API 费用；仍会使用你原有的 Codex 额度。开发安装需要有效的 Apple Developer 签名和同一 iCloud 账号。Xcode 账号恢复后，在 `../BarControlRemote` 运行 `./prepare-cloudkit-signing.command` 生成 Mac CloudKit 描述文件，再运行本目录的 `./install.command`。

## 构建与安装

双击 `install.command`，或运行：

```sh
./install.command
```

## Mac 供电策略（已接入系统充电控制）

菜单栏能源流面板底部的“Mac 供电”分段按钮是三态策略：优先充电 / 负载均衡 / 优先放电，默认负载均衡，选择会保存。

真实控制走 macOS 26+ 的私有 PowerUI **Manual Charge Limit（MCL）**：

- 优先充电 → 上限 100%，Mac 正常充满；
- 负载均衡 → 上限 80%，电量 ≥80% 时立即停止充电；Mac 电量 <20% 时自动放回 100%；
- 优先放电 → 同上限 80%，并在安装辅助组件后进一步通过 SMC `CHIE` 键断开充电器，让外接设备优先取电；Mac 电量 <20%、切回其他策略或退出 App 时自动恢复。

读取随时可用；“已接入/上限xx%”会显示在“Mac 供电”标签上。

**系统硬限制（实测）**：本机（MacBookPro17,1，macOS 27 固件 20457.x）已移除可写的充电 SMC 键（`CH0B/CH0C/CHTE` 不存在，`bfF0/bfD0/bfE0` 被系统 entitlement 锁死，root 也无效），开源方案（AlDente 旧版、battery.sh、batt）的写键路径全部失效。MCL 是唯一可用通道，且**低于 80% 的上限会被系统拒绝**（`PowerUISmartChargingErrorDomain Code=4`），所以 Mac 电量 <80% 时无法真正“停止充电”，此时策略只表现为“不外送给外接设备充电”。

### 可选：优先放电辅助组件

“优先放电”若要真正断开充电器，需要一次管理员授权安装特权组件。**直接在面板里选择「优先放电」就会自动弹出安装授权**（可取消）；也可以在菜单栏 → Touch Bar 设置 → “安装放电辅助组件（优先放电）…”手动触发。命令行等价方式：

```sh
./install-power-helper.command    # 需输入一次密码；可重复运行
./uninstall-power-helper.command  # 恢复充电器并删除特权文件
```

安装脚本只做三件事：把 `barcontrol-power-helper` 复制到 `/Library/PrivilegedHelperTools/`（root:wheel，755）、写入 `/etc/sudoers.d/barcontrol-power-helper`（只放行 `discharge on/off`、`status`、`probe` 四条固定命令）、做一次写回探测。App 通过 `sudo -n` 调用，绝不弹密码；未安装时界面显示“未安装放电组件”，其他策略不受影响。

注意：CHIE 写入在部分新固件上可能被拒绝（安装脚本的 `probe` 会直接告诉你结果）。若被拒绝，“优先放电”退回到系统 80% 上限行为，不会产生副作用。

## Touch Bar 亮度

macOS 没有公开的 Touch Bar 面板亮度 API，但系统私有 `DFRBrightnessClient` 在当前机型上提供真实的 OLED 调光档位。App 默认把已点亮的 Touch Bar 保持在最亮档 1；每 5 秒仅在档位被系统改低时校正一次，不会在 Touch Bar 已关闭或整机休眠时唤醒它。可在“更多操作 → Touch Bar 保持最亮”随时关闭。

## Codex++ 与供应商用量

供应商后端由 `~/Library/Application Support/BarControl/backend-mode.json` 统一管理，Bar Control 与 PhoneCodex 共用。`auto` 会优先使用 CC Switch 的 `~/.cc-switch`，找不到时回退到原 Codex++ 私有库；也可选择 `ccswitch`、`codexpp`，或填写自定义数据库与 settings 路径。双击 `configure-provider-backend.command` 即可选择，配置示例见 `backend-mode.example.json`。

余额检测只向供应商配置中的同源 HTTPS 端点发起请求，不输出或刷新密钥。仓库不再保存 Apple Team、CloudKit 容器或个人中继地址；旧 CloudKit 客户端作为可选后备，仅在本机 `.signing/` 提供描述文件、entitlements 与 `build.env` 时启用。
