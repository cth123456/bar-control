# Bar Control Remote

这是 Bar Control 0.17.0 的 iPhone 远程 Codex 客户端。它支持语音或文字下达指令、继续最近会话、停止当前任务、切换 CC Switch 供应商与模型、处理一次性确认，并按真实事件顺序显示 Codex 的每个回复和工具输出片段。

手机会记住当前选择的 thread。点选另一个账号或模型时，命令会连同该 thread ID 一起发送；Mac 完成 CC Switch 切换后原地恢复同一会话，而不是清空选择或创建新会话。电脑重启后，Bar Control 登录项会重新校准 `config.toml` 的兼容 provider、当前账号默认模型和最近远程会话。

## 数据路径

```text
iPhone 语音/文字
  → 你的 iCloud 私有 CloudKit 数据库
  → Mac Bar Control
  → 本地 Qwen 指令分类
  → Codex app-server
  → 逐片段事件原路返回 iPhone
```

Codex 和供应商凭据始终留在 Mac。客户端不开放公网端口、不使用 Tailscale，也不会创建第二套 VPN 配置。CloudKit 记录位于用户私有数据库，不是公共数据库。

## 构建

工程由 `project.yml` 生成：

```sh
xcodegen generate
DEVELOPER_DIR=/Users/mac/Downloads/Xcode-beta.app/Contents/Developer \
  xcodebuild -project BarControlRemote.xcodeproj \
  -scheme BarControlRemote \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

需要在 Xcode → Settings → Accounts 中登录团队 `G4Q5WT6422`，并让自动签名为下面两个 Bundle ID 创建含 CloudKit 权限的描述文件：

- iPhone：`com.cth123456.BarControlRemote`
- Mac：`local.codex.CodexTouchBarNative`

共享容器为 `iCloud.com.cth123456.BarControlRemote`。Xcode 登录有效后，运行：

```sh
./prepare-cloudkit-signing.command
../BarControl/install.command
```

第一个脚本只生成并保存 Mac CloudKit 描述文件，不安装临时占位 App。第二个脚本安装正式 Bar Control。iPhone 可直接从 Xcode 安装；当前没有自动上传 TestFlight，避免未经确认创建外部分发。

## 已验证边界

- Mac 单元测试与 iPhone 真机 Debug 构建均可编译。
- iOS 模拟器无 CloudKit 权限时会显示明确状态，不会崩溃。
- Codex app-server 实测返回三个独立增量 `REMOTE`、`_STREAM`、`_OK`，客户端事件模型会逐条保留。
- 2026-08-26 已验证：Mac 重启 Bar Control 后，同一个旧 DeepSeek thread ID 可在 OpenAI 模型下用轻量恢复模式重新挂接，未创建新 thread。
- iPhone 新包已安装到 Jet-Black；设备当时处于锁定状态，手机界面点击账号并完成一次真实来回切换仍需解锁后验收。
