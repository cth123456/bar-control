# Bar Control 0.40.6（原生 Swift 版）

这是一个独立的 macOS 菜单栏 App，不调用、不启动、也不依赖 BetterTouchTool。下载 Release 中的 `BarControl-版本号.zip` 后解压并将 App 移到“应用程序”即可。Touch Bar、AI coding、能源流、电源策略、系统监控、Touch Bar 亮度和菜单栏工具均包含在主 App 中，不需要按模块分别下载。

主层默认布局：

- 动态随航、`AI coding`、系统监控
- 展开菜单不再放“关于”入口（设置窗口侧栏仍保留）；“是否在此应用让位”以小字号次级样式、26pt 紧凑行高与主模块分隔，避免和模块列表混在一起
- 设置窗口侧栏采用固定图标槽：每个图标等比缩放到 14pt 字形后再居中放进 18×18 槽位，标题文字固定从同一 x 起点开始，避免窄图标显小或宽图标把文字挤开
- 随航空闲时保持紧凑深灰色；操作时在当前层展开，变蓝并显示四帧转动进度；成功变绿、失败变红，结果页至少完整展示 2.5 秒后再缩回双向默认态
- `AI coding` 保持紧凑蓝色胶囊，图标颜色表示 Codex 状态
- 整机监控在主层只显示一个 RunCat 风格动画，不再显示 `M70 / G53` 一类缩写；动画速度由整机实时功率驱动，颜色随功率从绿色、青色变为橙色、红色

菜单栏“更多操作 → Touch Bar 动图”可以即时切换跑猫、咖啡、跑狗、水滴、引擎、麻薯、牛顿摆和史莱姆；选择会保存到下次启动，不再需要单独安装 RunCat。

菜单栏“Touch Bar 设置 → Touch Bar 自动亮度”默认开启：使用 Mac 键鼠或 Touch Bar 时将实际背光维持在 100%，两边都空闲 15 秒后回落到 80%。只在 Touch Bar 已点亮、未锁屏时校正，每秒检查一次；关闭后停止干预。

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

保存后的六槽布局是唯一权威来源；启动、菜单重建和 Touch Bar 自愈都不会插入模块、补齐空槽或重排。只有主动点「恢复默认布局」或在自定义面板中修改时才会写入新布局。若某模块对应软件暂时不可用，原槽位会被保留，软件恢复后自动回到原位置。

点击 `AI coding` 进入二级层：

- 最左侧返回按钮
- 只显示当前、已管理或本月有用量的客户端；每个平台只显示一次真实软件图标，后面的账户/供应商按 CC Switch 名称排列
- Codex 可同时显示 CC Switch 管理的 ChatGPT 账号和 API 供应商；余额与单位沿用 CC Switch 的用量查询口径
- Magpie 供应商按紧凑双行卡显示配额窗口（如 Codex 的 5h / 7d），包含剩余比例与重置时间；其他账户显示余额。拖动供应商图标可调整顺序，拖动卡片内容可横向浏览。布局参考 [CodexBar](https://github.com/wjx8/CodexBar)（MIT）的 `TouchBarRateLimitsView` / `SegmentedBatteryBar`，只借鉴信息排布，没有复制其代码或素材
- AI coding 主图标在运行时以动态进度环显示活动任务数，刚完成 / 中止时短暂显示结果标记；现有任务快照没有每个任务的完成百分比
- 点击账户进入三级详情层，显示真实近 7 日用量折线、缓存命中率、请求成功率、近期模型和请求数；不足两个不同样本时显示“等待变化”，不绘制误导性的水平直线
- 只显示正在运行的 Codex 任务，最多五项；空闲时不显示说明文字；点击可打开对应任务

App 同时保留两个唤回入口：Touch Bar 的 Control Strip 图标和始终显示 `AI` 文字的 macOS 菜单栏入口。即使关闭了展开层，也可以重新显示，不会依赖二级菜单里的按钮自救。

首次启动后，App 会通过 macOS 原生登录项注册开机自启动；不使用额外 LaunchAgent，也不会启动 BetterTouchTool。

八套共 50 帧动画素材来自 [RunCat Neo](https://github.com/runcat-dev/RunCatNeo)，按 Apache License 2.0 使用；完整许可与改动说明随 App 打包在 `Contents/Resources/ThirdParty`。

逐端口 USB-C 遥测实现参考了开源项目 [WhatPort](https://github.com/darrylmorley/whatport) 与 [macpow](https://github.com/k06a/macpow) 对 macOS IOKit/USB-PD 字段的公开验证，代码在本项目中独立实现，没有引入它们作为运行时依赖。

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

## 接口与线缆详情

菜单栏 → Touch Bar 设置 → **「接口与线缆详情…」** 打开完整规格窗口（数据全部来自本机 IORegistry，无需管理员权限、不联网）。

- **充电器卡片**：名称、厂商、型号、序列号、固件/硬件版本、铭牌功率；PD 档位列表（当前协商档高亮）；实时电压/电流/功率。
- **端口卡片**（每个有连接的 USB-C 口一张）：对端设备 VID/PID；线缆 e-marker 的类型、插头、规范修订、**速率**、**供电能力（V/A/W）**、EPR、厂商/产品 ID、证书 XID；异常项（如厂商 ID 为 0）以提示行标出。
- **结论条**：一句话指出瓶颈在充电器 / 线缆 / 供电正常，并给出建议功率。

能源流面板同时新增两行（仅在有关键信息时出现，因此平时不占高度）：

1. `⚠︎ 瓶颈在充电器：输入 18.5 W < 整机 27.4 W，电池在放电`（仅当充电器功率不足以覆盖整机负载时显示）；
2. `充电器 Apple 20W · 9V/2.22A` + `线缆 240W · ≥40Gbps`。

参考实现：[darrylmorley/whatcable](https://github.com/darrylmorley/whatcable)（MIT；仅借鉴 IOKit 读取路径与 USB-PD 规范位定义，未复制其代码或界面资源）。

**速率措辞是刻意保守的**：USB-PD 3.0/3.1 对 Cable VDO 速率字段的 3/4 编码定义不同（3.0 的 3=20 Gbps，3.1 的 3=40 Gbps、4=80 Gbps），而我们无法从规范修订字段区分两者，因此界面显示 `≥20 Gbps` / `≥40 Gbps`，原始字段值在详情页对应行下方注明。供电能力按规范的 48 V EPR 上限计算（50 V × 5 A 显示 240 W 而非 250 W 的绝缘余量值）。

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

该 helper 已包含在主 App 包内，正常下载和使用不需要单独下载文件。只有用户主动使用“优先放电”并接受管理员授权时才安装到系统；卸载请运行 `./uninstall-power-helper.command`，或在设置中卸载该组件。helper 无独立界面，也不提供额外功能入口。

## Touch Bar 亮度

`getDimmingStep == 0` 只表示未施加额外空闲调暗，不能代表实际背光已达最高。本机实测：旧接口报告 0 档时，CoreBrightness 的 `DisplayBrightness` 为 0，驱动 `CurrentNits` 约 12；将实际亮度临时设置到 1.0 后，回读约 0.991 / 357 nit。

现通过 HID 的 `TouchBarUserDevice` 绑定 Touch Bar display ID，再使用 CoreBrightness 的绝对亮度接口，只操作该显示器。活跃时目标 1.0，Mac 与触控栏都空闲 15 秒后目标 0.8，允许 0.015 的硬件量化误差。写入使用 `Commit = NO`，不改系统自动亮度偏好；熄屏或锁屏时不写入。关闭自动亮度后停止持续校正，由系统恢复控制。日志同时记录 display ID、目标亮度、实际回读和驱动 nit 值。

接口参考开源 [TouchBarFloor](https://github.com/volpierre/TouchBarFloor) 和 [TouchBarController](https://github.com/skimmilk/TouchBarController)，均为 MIT；授权文件保存在 `Resources/TouchBarBrightness-LICENSE.txt` 并随 App 资源分发。私有接口在不支持的系统上会安全返回不可用，保留旧调光兼容路径。

## Touch Bar 常驻与让位

有线 iPad 电量通过已信任的 MobileDevice 会话每 10 秒只读采样，按 USB 序列号匹配，不主动配对或弹出信任提示。「优先充电」或「优先放电」期间，正在受电的 iPad/iPhone 达到阈值（默认 80%）后自动回到「负载均衡」；阈值和开关在「Touch Bar 设置 › 电源」里调整，未知电量、多台设备或断开时不触发。电池域参考 [libimobiledevice 的 ideviceinfo](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/ideviceinfo.c)（仅核对协议字段，未引入依赖或复制实现）。

模块栏默认常驻在触控栏中间，不需要先点固定区图标。Touch Bar 没有跨应用的后备层，也没有“中间是否被占用”的公开查询接口，因此让位由两条可解释的规则决定：

1. **让位应用**：默认名单分两类，都能逐项开关。
   - 系统内置：Safari、邮件、信息、备忘录、照片、预览、QuickTime、音乐、FaceTime、电话、通讯录、日历、地图、提醒事项、查找、终端、计算器、图书、TV、App Store、语音备忘录、活动监视器、自动操作、控制台、音频 MIDI 设置、屏幕共享、Pages/Numbers/Keynote、Xcode、Final Cut、Logic、GarageBand、iMovie。
   - 第三方：Word/Excel/PowerPoint、Photoshop/Illustrator/Premiere Pro/After Effects、Sketch、BBEdit、iTerm2、Pixelmator Pro、Affinity Designer/Photo/Publisher 2、DaVinci Resolve、PCalc、djay。

   收录依据是本机二进制扫描（`NSTouchBar` / `DFRFoundation` / `makeTouchBar` 符号）、Apple 支持文档、iMore 的 Touch Bar 应用清单，以及 Affinity、iTerm2、Blackmagic 的官方说明。名单可在「Touch Bar 设置 › 让位应用」里逐项开关，「添加其他应用…」可以直接选任意 `.app` 读取真实 bundle id，菜单里的「当前应用：在此应用让位」可临时增删。

   **自动识别**（默认开启）：名单之外的应用如果自己占用了触控栏，DFR 会把我们的系统模态窗口压成 0 宽；连续两次检测到这种情况就把它记进「自动识别」列表，下次它到前台直接让位，不需要再人工查它支不支持 Touch Bar。识别结果在「让位应用」窗口里可以单独关掉。系统没有公开接口能查询“某个应用是否使用触控栏”，所以这条规则只在系统真的把触控栏交给该应用时生效；如果某个应用始终抢不过我们的模态栏，仍可用菜单里的「当前应用：在此应用让位」一键加入。
2. **输入焦点**：前台应用的焦点在文本输入框（辅助功能接口读取 `AXTextField`/`AXTextArea` 等）且最近 3 秒内有按键时让出中间区域，停止输入 3 秒后模块栏自动回来。该规则可在设置里关闭；未授予辅助功能权限时自动失效。Electron 类应用（如 Obsidian）不暴露焦点，检测不到。

用户手动收起模块栏后，自愈、唤醒和应用切换都不再自动弹回；点固定区图标或设置里的“显示模块栏”可以恢复，并在本次停留期间保持显示。

## 更新检查与关于

- **检查顺序**：`docs/updates.json`（静态清单）→ GitHub Releases Atom 订阅 → GitHub Releases API → Tags Atom → Tags API。Atom 是公开网页，不需要 token，也没有 API 每小时 60 次的限流，所以正常情况根本不会碰到“限流”。
- **一键更新**：清单里带 `asset_url` + `sha256` 时，弹窗主按钮是「立即更新」：下载 zip → 校验 SHA-256 → 解压 → 校验代码签名 → 等 App 退出后替换 `/Applications/Bar Control.app` → 自动重开。任何一步失败都保留旧版本，并退回浏览器下载。
- **更新弹窗**：显示更新说明，可「立即更新 / 前往下载」「稍后」或「跳过此版本」。同一版本 24 小时内最多弹一次；跳过后该版本不再提示。
- **关于页**：`Touch Bar 设置 › 关于`，显示版本与构建号、上次检查时间、自动检查开关、项目/发布/反馈链接、复制版本信息与 MIT 许可入口。展开菜单里也有「关于 Bar Control」。
- **自动检查**：启动后 12 秒检查一次，之后每小时判断一次；只有距上次成功检查超过 24 小时才真正发请求。开关关闭后不再自动请求。

发版流程（让旧版本能检测到新版本）：

1. 修改 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`；
2. 更新 `docs/updates.json` 的 `latest` 与 `releases`（写清更新说明）；
3. 写 `docs/release-notes/<version>.md`；
4. 先 `DRY_RUN=1 scripts/publish-release.sh` 预览，再执行 `scripts/publish-release.sh`：它会构建、打成 `BarControl-<version>.zip`、把 `asset_url` / `sha256` / `asset_size` 写回清单，然后打 tag、推送并创建带安装包的 Release。

## Codex++ 与供应商用量

供应商后端由 `~/Library/Application Support/BarControl/backend-mode.json` 统一管理，Bar Control 与 PhoneCodex 共用。`auto` 会优先使用 CC Switch 的 `~/.cc-switch`，找不到时回退到原 Codex++ 私有库；也可选择 `ccswitch`、`codexpp`，或填写自定义数据库与 settings 路径。双击 `configure-provider-backend.command` 即可选择，配置示例见 `backend-mode.example.json`。

余额检测只向供应商配置中的同源 HTTPS 端点发起请求，不输出或刷新密钥。仓库不再保存 Apple Team、CloudKit 容器或个人中继地址；旧 CloudKit 客户端作为可选后备，仅在本机 `.signing/` 提供描述文件、entitlements 与 `build.env` 时启用。
