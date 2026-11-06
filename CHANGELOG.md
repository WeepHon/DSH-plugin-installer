# 更新日志

## 1.0.0

首个公开版本。

### 安装

- 图形界面（WPF）+ 命令行双入口，不打开 DSH 也能装插件
- 走官方 CLI 通道 `dsh plugin add`，自动维护 `dependencies`、`dsh.profile.bundles`、`node_modules`
- 官方 CLI 不可用时自动退到备用安装模式（自己改 profile + Junction）
- 插件自动发现：`plugins\`、桌面、下载目录，也支持选文件夹或压缩包
- 安装前把插件复制到 `~/.dsh/local-plugins/`，源文件夹可删
- 改动前自动备份 profile 配置文件，支持一键卸载
- 可选顺便打开插件功能开关（写入带标记的 `cordis.patch.yml` 条目）
- 支持 desktop / web 两个配置，支持版本不兼容豁免（`compatibility.json`）

### 进阶

- 解除插件版本限制：自适应定位判定函数并插入放行语句，先在沙盒做行为自检再替换，还原为字节级精确删除
- 官方更新后自动修复补丁（可关）
- 应急开关：改用目录加载（绕开 asar 校验）、降低检测强度（改 fuse 字节），均可一键还原
- 补丁点配置化（`core/unlock-targets.json`），官方函数改名或换文件时靠内容搜索重新定位

### 打包

- 单文件 `DSH插件安装器.exe`（约 350 KB），由 .NET Framework 自带 `csc.exe` 编译，无需联网与额外依赖
- 解压落点自动退让：`LocalAppData` → `TEMP` → 程序旁边；支持 `DSH_INSTALLER_HOME` 指定
