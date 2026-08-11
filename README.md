# QuickClipboard iOS Jailbreak Tweak

跨平台剪贴板增强工具的 iOS 越狱插件版本，目标环境为 **Dopamine 2.0 / iOS 15+**。

## 功能

- **全类型剪贴板记录**：文本、图片、URL、文件
- **智能去重**：基于 SHA-256 校验，2 秒窗口内重复内容不重复记录
- **SQLite 持久化**：本地数据库，支持收藏、删除、按时间排序
- **WebDAV 全同步**：手动/自动推送、拉取、轮询拉取，支持云端 AES 加密
- **局域网 HTTP 直连同步**：端口 35691，配对码机制，事件触发同步
- **GitHub 构建发布**：在设置页登录 GitHub，自动创建 `Quick` 仓库并上传 deb

## 项目结构

用户登录后可自动关联 GitHub 账号，创建名为 Quick 的仓库，并完成 deb 包构建

## 构建要求

**必须在 macOS 上执行**：

1. 安装 [Theos](https://theos.dev/docs/installation)
2. 安装 Xcode + Xcode Command Line Tools + iOS SDK
3. 可选：`brew install jq`（用于 GitHub 脚本）

```bash
# 设置环境变量
export THEOS=$HOME/theos
export PATH=$THEOS/bin:$PATH

# 进入工程目录
cd QuickClipboardTweak

# 普通构建
make package FINALPACKAGE=1

# 或一键构建+发布（需要 GitHub Token）
export GITHUB_TOKEN=ghp_xxx
export GITHUB_USERNAME=yourname
./scripts/build-and-publish.sh
```

## GitHub Token 权限

在 GitHub Settings -> Developer settings -> Personal access tokens -> Tokens (classic) 创建，勾选：

- `repo`（创建仓库、上传文件）
- `delete_repo`（可选，用于测试时删除仓库）

## 安装到设备

```bash
# 通过 scp 传到已越狱设备
scp packages/com.mosheng.quickclipboard_*.deb root@<device-ip>:/tmp/

# 在设备上安装
ssh root@<device-ip> "dpkg -i /tmp/com.mosheng.quickclipboard_*.deb && killall -9 SpringBoard"
```

## 已知限制与注意事项

1. **编译必须在 macOS + Theos 环境**，当前 Windows 工作区无法直接生成 deb。
2. **局域网服务**在 SpringBoard 启动时启动，需要设备越狱且插件注入成功。
3. **WebDAV 加密**使用简单 AES-256-CBC + PKCS7，生产环境建议加入 PBKDF2 派生密钥。
4. **GitHub 自动构建**的 UI 触发仅保存配置；真正的构建/发布脚本需在 macOS 上执行，或配置 CI runner。
5. 设置面板中的图标 `icon.png` 需要自行放入 `quickclipboardprefs/Resources/`。

## 许可证

参考 QuickClipboard 开源项目实现，本项目源码仅供学习与个人使用。
