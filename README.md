# NAS 助手

SwiftUI iOS app for managing a Synology DSM NAS.

面向群晖 DSM 的 iPhone / iPad 管理应用，使用 SwiftUI 编写。源码里包含设备连接、文件、照片、Video Station、Audio Station、Docker、Synology Drive、Cloud Sync、下载、SSH/SFTP、资源监控、套件、日志、虚拟机，以及 Emby、Jellyfin、Immich、Navidrome。列出这些模块只说明源码中有对应界面，不表示每项都已在真机验收。

## 技术栈

- SwiftUI，iOS deployment target 17.0
- DSM Web API 客户端在 `Packages/DSMKit`
- SSH 依赖 Citadel 0.11.1 与 SwiftTerm 1.20.0
- 工程由 `project.yml`（XcodeGen）生成

## GitHub Actions

Linux 上的 DSMKit 测试在每次推送到默认分支时运行。

未签名 IPA 不会在每次推送时构建。在 Actions 里手动运行 **DSM-Tools iOS unsigned IPA**，或推送 `ipa-build-*` 标签。Linux 测试失败时不会启动 macOS 构建。成功后在该次运行的 Artifacts 下载 `NASHelper-unsigned`，其中包含 IPA、`SHA256SUMS.txt` 和 `BUILD_INFO.txt`。IPA 产物保留 3 天，失败日志保留 7 天。

## 在 Mac 上本地编译

需要已安装的 Xcode 和 XcodeGen（`brew install xcodegen`）。

```bash
./scripts/build.sh simulator
./scripts/build.sh
```

第一条在模拟器中运行。第二条生成 `build/NASHelper-unsigned.ipa`。

## 未签名 IPA

这个 IPA 没有 Apple 签名，也没有在本仓库的自动化流程里安装到真机。安装前需要使用你自己的合法签名流程。不要把工作流成功理解成真机测试已经通过。

## 验收状态

- Linux DSMKit 测试：以本仓库 Actions 里 **DSMKit tests** 对当前提交的结果为准。
- GitHub 托管 macOS Runner 上的未签名 IPA：以 **DSM-Tools iOS unsigned IPA** 对当前提交的结果为准。工作流成功只表示编译出了未签名 IPA。
- DS1621+ 真机：`NOT VERIFIED`。

## 仓库

https://github.com/xlpppp/DSM-Tools-Public

## 许可证

本仓库目前没有许可证文件。仓库设为 Public 只表示源码可以被看到，不授予复制、修改或再发布的权利。
