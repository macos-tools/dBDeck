# dBDeck（音量岛）

[English](README.md)

dBDeck 是一款轻量的 macOS 菜单栏分应用音量控制工具，支持 macOS 14.2 及以上版本。

## 功能

- 在不改变系统音量的情况下，将每个应用的音量调节至 0%–200%。
- 按恰当顺序排列应用，让你快速找到想要调节的项目。
- 精心优化的能耗，大多数情况下不会带来额外的能耗开销。

## 隐私与权限

dBDeck 不会录制、存储或传输音频，也没有联网功能。音频处理只在本机进行。

应用会在 `UserDefaults` 中保存以下本地数据：

- 应用标识号、显示名称和上次记录的应用路径。
- 累计播放秒数和最近一次播放日期。
- 每个应用的音量和静音状态。
- 被隐藏的长期未使用记录，以及上次整理列表的时间。

## 环境要求

- macOS 14.2 或更高版本。

## 安装与首次启动

每个 GitHub Release 都会提供 `dBDeck-<版本号>.dmg` 和对应的 SHA-256 校验文件。

1. 从 Release 页面下载这两个文件。
2. 打开 DMG，将 dBDeck 拖入“应用程序”文件夹。
3. 启动 dBDeck。它的图标会出现在菜单栏中，而不是 Dock 中。
4. macOS 请求“系统音频录制”权限时请允许，以便 dBDeck 调节各个应用的音量；如果系统提示，请重新启动 dBDeck。

安装第一个版本前，可以在终端中校验下载文件：

```sh
cd ~/Downloads
shasum -a 256 -c dBDeck-0.1.0.dmg.sha256
```

### 打开当前未经公证的版本

当前版本没有使用 Developer ID 签名，也没有经过 Apple 公证。请只在从本仓库下载并核对校验值后覆盖 macOS 的安全限制，不要全局关闭“门禁”。

使用图形界面：

1. 先尝试打开一次 dBDeck，然后关闭 macOS 的警告。
2. 打开“系统设置 → 隐私与安全性”，向下滚动到“安全性”。
3. 点按“仍要打开”，完成身份验证，然后确认“打开”。macOS 只会为这个 App 保存例外。

也可以先将 dBDeck 复制到“应用程序”，然后在终端中只移除这个 App 的隔离标记并启动它：

```sh
xattr -dr com.apple.quarantine "/Applications/dBDeck.app"
open "/Applications/dBDeck.app"
```

## 构建与运行

从源代码构建需要 Xcode 16 或兼容的 Swift 6 工具链。

```sh
./script/build_and_run.sh
```

脚本会构建 `dist/dBDeck.app`，为本地开发添加临时签名，然后启动应用；发布 DMG 请使用下方的打包脚本。

可选模式：

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

使用以下命令生成同时支持 Apple 芯片和 Intel Mac 的发布 DMG 与校验文件：

```sh
./script/package_dmg.sh 0.1.0
```

产物会写入 `dist/dBDeck-0.1.0.dmg` 和 `dist/dBDeck-0.1.0.dmg.sha256`。

## 当前范围

当前版本跟随系统默认输出设备。暂不包含分应用输出设备、自动 Duck、Profiles、EQ、全局快捷键、CLI、Shortcuts 和 Raycast 集成。

## 参与贡献

欢迎提交问题报告和范围明确的 Pull Request。提交代码改动前，请先运行 `./script/test.sh`。

## 许可证

dBDeck 采用 [GNU 通用公共许可证第 3 版，仅限该版本](LICENSE)（`GPL-3.0-only`）。
