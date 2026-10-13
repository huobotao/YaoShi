# 药时 · YaoShi

记录服药时间、感受、进食和睡眠，让这一轮发生的事情更容易回看。欢迎通过 Issue 提建议，或提交 Pull Request 一起改进。项目采用 [MIT 许可证](LICENSE)。

## 功能

- 曲线按住、左右滑动选择时间点，查看时间和模型数值；支持双指缩放与时间平移。
- 以本轮第一条服药记录为起点，跨天查看实际记录的进食、入睡和醒来；可补填、修改时间。
- iPhone / iPad 共用代码；iPad 提供宽屏布局。Mac 版使用 Mac Catalyst 构建。
- 小组件、实时活动、Apple Watch 与独立的只读伴侣 App 源码一并保留。
- “我的 → 关于”显示版本号与源码提交，便于核对设备；统一版本配置在 `version.json`。

曲线是通用模型估算，不是实测血药浓度，不用于决定剂量或再次服药。没有进食或睡眠记录不代表没有发生。记录分轮也不代表药效持续时间。

<details>
<summary>iPhone 曲线预览（合成测试数据）</summary>

<img src="docs/images/iphone-chart.png" width="320" alt="药时曲线查数值及缩放界面；合成测试数据" />

</details>

## 开发与构建

需要 macOS、Xcode、Command Line Tools、Python 3 与对应 SDK。当前通过 shell 脚本直接调用 Apple 工具链，没有 Xcode 工程或第三方包依赖。共享代码位于 `Shared/PartnerSync`。

```sh
bash tests/run_sync_tests.sh
python3 -m unittest discover -s tests -p 'test_*.py'
YAOSHI_SIM_DIR=/tmp/yaoshi-review bash build_sim.sh
```

模拟器构建不需要开发者签名。构建脚本仅生成 App；可用 `xcrun simctl install booted /tmp/yaoshi-review/药时.app` 安装到已启动的 iPhone 或 iPad 模拟器。

真机构建需要 Apple Development 签名身份和允许对应 Bundle ID、Keychain 组的 provisioning profile。签名证书和描述文件须在本机配置，不存入仓库：

```sh
export YAOSHI_SIGNING_IDENTITY='本机的 Apple Development 签名身份或证书 SHA-1'
export YAOSHI_BUILD_DIR="$(mktemp -d /tmp/yaoshi-device.XXXXXX)"
bash build.sh
bash build_widget.sh
# 可选：bash build_watch.sh
```

本项目保留原有 Bundle ID 与 Apple Team ID，保证现有安装的升级和钥匙串访问连续性；这些是公开标识，不是密钥。其他开发者要在自己的 Apple Developer 团队下运行真机版，需同时配置构建脚本、源码中的 Bundle ID / Keychain 组与描述文件。不要直接替换已有用户安装使用的标识。

Mac 本机版（macOS 14+，Apple Silicon 默认构建）：

```sh
YAOSHI_MAC_BUILD_DIR="$(mktemp -d /tmp/yaoshi-mac.XXXXXX)" bash build_mac.sh
```

默认使用本机临时签名和独立沙盒，仅记录本机数据。iPhone ↔ Mac 共享钥匙串需要匹配的 Mac provisioning profile 与签名身份；当前不宣称跨平台同步已验证。可通过 `YAOSHI_MAC_PROFILE`、`YAOSHI_MAC_SIGNING_IDENTITY` 指定自己的有效配置。

平台验收状态随版本发布说明维护。编译通过不等于已经验证真机触摸、同步、推送或跨设备行为。伴侣 App 的服务端不在此仓库内，不能只靠编译客户端启用远程共享。

## 两台 Mac 与多台设备

1. 两台电脑 clone 同一个 GitHub 仓库，开始前先 `git pull --ff-only`。
2. 每次修改使用独立分支，保留本地未提交改动，不用复制文件夹互相覆盖。
3. 测试、审阅后合并到 `main`，统一修改 `version.json` 并创建版本标签。
4. 各设备安装同一个标签提交的构建，在“关于”核对 App 版本和代码版本。
5. 标记“本地修改”的构建不作为同步基准。Git 同步源码，不会自动更新设备上的 App 或同步健康记录。

公开仓库从完成隐私清理的版本开始；早期本地开发历史未公开。

## 隐私与贡献

公开仓库只保存代码、应用图标与合成测试数据。不要上传设备备份、健康记录、真实笔记、邀请链接、访问令牌、签名文件或包含这些内容的截图。更新 App 前请独立备份设备数据。

参与方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。优先欢迎图表手势、无障碍、iPad / Mac 适配、离线记录可靠性与同步冲突处理方面的贡献。图标随本项目发布；系统框架、SF Symbols 等 Apple 资源仍适用其各自条款。
