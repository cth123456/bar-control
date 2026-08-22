# 随航管家

Bar Control 的可选伴侣 App，用一个按钮连接或断开 iPad 随航，并把连接阶段写回 Touch Bar。

## 配置

先安装 [BetterDisplay](https://github.com/waydabber/BetterDisplay)，再把下面的设备名替换成系统“显示器”菜单中出现的 iPad 名称：

```sh
defaults write local.codex.SidecarPilot TargetDevice "我的 iPad"
```

临时测试其他设备时，也可以使用环境变量：

```sh
SIDECAR_PILOT_DEVICE="我的 iPad" open -n "dist/随航管家.app"
```

## 工作方式

1. 使用 BetterDisplay CLI 直接连接；
2. 失败后断开并重连；
3. 最后通过系统“显示器”界面选择目标 iPad。

每一步都会同时检查 BetterDisplay 状态与 `system_profiler` 的真实 `Sidecar Display`。App 不会重启 Universal Control、蓝牙或 Wi-Fi 服务，也不会删除配对和 Apple Account 数据。

## 构建

```sh
./Scripts/build.sh
```

默认使用临时签名。需要开发者签名时传入 `SIGN_IDENTITY`。
