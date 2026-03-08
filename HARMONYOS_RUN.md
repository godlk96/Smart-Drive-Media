# HarmonyOS6 运行与真机联调指南

## 1. 环境要求

- DevEco Studio 6.x（推荐 6.0.2 稳定版）
- HarmonyOS SDK（推荐安装 5.0.0(12) 及以上稳定版本）
- Node.js 20+
- 已开启开发者模式的 HarmonyOS 设备（USB 调试可用）

### 1.1 官网优先原则

- DevEco Studio 版本以华为开发者联盟下载中心“最新稳定版”为准
- 本文档当前按 6.0.2 编写；若官网已发布更新稳定版，优先采用官网版本并沿用本文流程
- 本项目工程基线使用 `compatibleSdkVersion: "5.0.0(12)"`，后续仅在确认兼容后再升级

## 2. 安装与 SDK 配置（新手路径）

- 打开华为开发者联盟下载中心，下载 DevEco Studio 6.x 稳定版安装包（推荐 6.0.2）
- 完成 IDE 安装并首次启动
- 进入 `Settings`，安装 HarmonyOS SDK（确保包含 5.0.0(12)）
- 进入 SDK 管理页确认 5.0.0(12) 状态为可用

## 3. 工程打开与基础校验

- 在 DevEco Studio 中打开仓库根目录 `c:\Users\gzr\Desktop\code`
- 同步 `oh-package.json5` 依赖并等待索引完成
- 确认 API 版本配置：
  - 根配置 `build-profile.json5` 使用 `compatibleSdkVersion: "5.0.0(12)"`
  - 根配置 `build-profile.json5` 使用 `targetSdkVersion: "6.0.2(22)"`
  - 运行模块为 `entry`
  - `entry/build-profile.json5` 使用 `stageMode`
  - `entry/src/main/module.json5` 的 `mainElement` 为 `EntryAbility`
  - `entry/src/main/resources/base/profile/main_pages.json` 包含 `pages/Index`、`pages/Editor`

## 4. 真机签名准备清单

### 4.1 本地签名材料

在 `AppScope/` 下准备以下文件（仅本地保存，不入库）：

- `debug.p12`
- `debug.mobileprovision`
- `debug.cer`

若已在 DevEco 的 Signing Configs 勾选 Automatically generate signature，证书通常先生成在用户目录（如 `C:\Users\<用户名>\.ohos\config\...`）。可按以下方式落到项目目录：

- 在 Signing Configs 页面记录当前 `Store file`、`Profile file`、`Certpath file` 三个源路径
- 复制到项目 `AppScope/` 并重命名为 `debug.p12`、`debug.mobileprovision`、`debug.cer`
- 确保 `build-profile.json5` 的 `storeFile`、`profile`、`certpath` 指向 `AppScope/` 下对应文件

### 4.2 签名配置

- 复制 `build-profile.template.json5` 为本地可用配置
- 将签名材料路径与密码改为你自己的本地值
- 确保 `signingConfig` 与 `products.default` 绑定关系正确

### 4.3 安全约束

- 不要提交任何证书材料、密码、私钥文件
- 默认通过 `.gitignore` 忽略 `AppScope/*.p12`、`AppScope/*.cer`、`AppScope/*.mobileprovision`

## 5. 首次真机运行步骤

- 连接设备并在手机端开启开发者模式与 USB 调试
- 在 DevEco 设备列表选择目标设备
- 选择 `entry` 模块执行 Run
- 首次安装后进入首页，点击“授权读取”
- 在系统权限弹窗中授予媒体读取权限
- 回到应用确认行程库状态刷新

## 6. 主流程联调 Checklist

- [ ] 启动应用进入首页
- [ ] 首次权限申请可见，拒绝后提示文案正确
- [ ] 授权后可展示行程卡片或空状态
- [ ] 点击任一卡片进入剪辑页
- [ ] 拖动进度滑杆，时间文本随之更新
- [ ] 切换隐私开关后状态保持一致
- [ ] 点击“导出”后状态文本切换为处理中

## 7. 当前权限基线

当前实现与模块声明统一使用以下权限：

- `ohos.permission.READ_MEDIA`
- `ohos.permission.READ_IMAGEVIDEO`

## 8. 关键入口文件

- 应用入口：`entry/src/main/ets/entryability/EntryAbility.ets`
- 首页：`entry/src/main/ets/pages/Index.ets`
- 剪辑页：`entry/src/main/ets/pages/Editor.ets`
- ArkTS UI 侧桥接：`entry/src/main/ets/bridge/CoreBridge.ets`
- JS 桥接入口：`entry/src/main/js/harmonyBridge.mjs`
- 核心桥接实现：`src/harmony/coreBridge.js`

## 9. 常见问题排查

### 安装失败（签名相关）

- 检查 `build-profile.json5` 中证书路径是否存在
- 检查 `storePassword`、`keyAlias`、`keyPassword` 是否匹配
- 检查 `.p12`、`.cer`、`.mobileprovision` 是否同一签名体系

### 启动后一直空列表

- 确认已授予 `READ_MEDIA` 与 `READ_IMAGEVIDEO`
- 确认测试文件命名符合 `DVR_LoopRecording_...` 规则
- 确认文件路径可被当前扫描源访问

### 权限提示异常

- 清理应用数据后重试授权流程
- 在系统设置中移除权限并重新进入应用触发申请

### 真机功能异常时抓日志

- 已在 `EntryAbility`、`Index`、`Editor`、`CoreBridge` 增加关键链路日志，日志内容改为中文，便于筛选
- 在 DevEco 运行应用后，打开 Log 面板并过滤 `智驾影音|首页|扫描|剪辑页|剪辑诊断|导出|应用`
- 复现一次问题流程（首页授权 -> 去剪辑 -> 切换隐私/拖动进度/点击导出）
- 导出或复制对应日志片段用于定位
- 若 DevEco Run 面板仅显示安装流程，可用设备日志命令抓取：`hdc shell hilog | findstr 智驾影音`

### IDE 或 SDK 版本不匹配

- 若本地 DevEco 版本低于 6.x，优先升级到官网最新稳定版
- 若缺失 5.0.0(12) SDK，进入 SDK 管理页补装后重启 IDE
- 若 IDE 版本更新但项目可正常编译，保持当前 `compatibleSdkVersion` 基线继续开发

### Sync failed：hvigor 与 ohpm 的 ModelVersion 不一致

- 若提示“ModelVersion for hvigor is not specified / differ from ohpm”，检查 `hvigor/hvigor-config.json5`
- 确保存在 `"modelVersion"`，并与根 `oh-package.json5` 的 `"modelVersion"` 一致
- 当前项目基线为 `5.0.0`，即两个文件都应为 `5.0.0`
- 修改后执行一次 `Sync Project`，若仍失败可使用 IDE 的 `Migrate Assistant`

### ohpm 仓库 404（`@ohos/hvigor` / `@ohos/hvigor-ohos-plugin`）

- 若日志显示从 `https://ohpm.openharmony.cn/ohpm/` 拉取 `@ohos/hvigor*` 返回 404，请切换仓库到 `https://repo.harmonyos.com/ohpm/`
- 本项目已提供根目录 `.ohpmrc`，默认使用 `https://repo.harmonyos.com/ohpm/`
- 切换后重新执行 Sync 或重新打开项目触发依赖安装
- 若仍提示 `@ohos/hvigor*` 404，检查根 `oh-package.json5`，移除 `devDependencies` 里的 `@ohos/hvigor` 与 `@ohos/hvigor-ohos-plugin`（由 DevEco 内置 hvigor 处理）

### Sync failed：Invalid value of compileSdkVersion/compatibleSdkVersion/targetSdkVersion

- 检查 `build-profile.json5` 的 `products` 配置，确保 `compatibleSdkVersion` 为有效版本字符串（当前基线 `5.0.0(12)`）
- `targetSdkVersion` 建议配置为 `6.0.2(22)`，并与当前 IDE 可用 SDK 保持一致
- 不要将 `targetSdkVersion` 写成空字符串（`""`）

### Configure targetSdkVersion 弹窗处理

- 若弹窗提示“this project has no targetSdkVersion”，可选择 Auto-set 到 `6.0.2(22)`
- 或手动在 `build-profile.json5` 的 `products.default` 下配置 `targetSdkVersion: "6.0.2(22)"`

## 10. 版本漂移说明

- 文档内的“推荐版本”会随官网稳定版演进而更新
- 当官网版本与本文存在差异时：先遵循官网安装路径，再按本文的工程校验项执行

## 11. 已知限制

- 当前仓库提供 Stage 壳工程与桥接骨架，视频渲染和系统媒体 API 的深度集成仍需下一轮真机联调完善。
- 当前导出触发为状态链路验证，尚未接入完整系统级导出落盘与分享链路。
