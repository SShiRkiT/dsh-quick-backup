<p align="center">
  <b>简体中文</b> ·
  <a href="./README.en.md">English</a>
</p>

# dsh-quick-backup

面向 **DeepSeek​ Harness（DSH）** 用户环境的本地 Git 增量备份工具，提供 **设置 → 备份** 面板。

> 本 GitHub 仓库只包含**插件和工作流脚本**。
> 你的 DSH profile、会话、凭据、API Key 和备份数据**永远不会**进入这个仓库。
> 备份保存在 `setup.ps1` 创建的**独立本地仓库**中。

## 你将获得

- 在 **DSH 设置 → 备份** 中一键备份
- 本地 Git 历史，日期版本号：`vYYMMDD.E.SSS`
- DSH 启动时自动备份（可选 watcher）
- 查看版本、导出、复制安全的恢复命令
- 缓存感知：单纯重启 DSH 不会产生无意义的版本
- 不联网、没有远程仓库、不上云

## ⚠️ 数据与密钥风险（务必阅读）

> [!WARNING]
> **如果开启“备份凭据与 APIKey”，数据仓库会把 `.credentials.yaml` 和 `APIKey` 以明文保存在本地，而且 Git 历史永不遗忘。**
>
> 默认不备份这两项。若你主动开启，并把备份文件夹进行云同步、网盘同步、网络驱动器同步，或者转发给他人，由此导致的凭据或隐私泄露由**你自行承担**，作者**不承担任何责任**。

## 环境要求

- Windows 10/11
- PowerShell 5.1（系统自带）
- [Git for Windows](https://git-scm.com/download/win)（脚本优先使用 `C:\Program Files\Git\cmd\git.exe`）
- DSH desktop `>= 0.2.1-rc.2`

## 快速开始

### 1. 获取文件

```powershell
git clone https://github.com/SShiRkiT/dsh-quick-backup.git
cd dsh-quick-backup
```

### 2. 创建本地备份仓库

**备份路径默认是空的。** 必须显式传入 `-RepoPath`：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -RepoPath "D:\DSH-Backups" -EnableAutostart
```

`setup.ps1` 会：

- 检测/使用你的 `.dsh` profile（默认 `%USERPROFILE%\.dsh`）
- 在你指定的路径创建备份仓库
- 复制工作流脚本并写入 `backup.config.json`
- 初始化本地 Git，并创建第一个基线版本
- 注册插件发现配置
- 可选安装登录 watcher（`-EnableAutostart`）

常用参数：

```powershell
# 自定义 profile / 安装目录
.\setup.ps1 -RepoPath "D:\DSH-Backups" -DshProfile "$env:USERPROFILE\.dsh"

# DSH 安装在自定义目录
.\setup.ps1 -RepoPath "D:\DSH-Backups" -InstallRoot "D:\DSH\Desktop"

# 只复制脚本和配置，暂不复制 profile
.\setup.ps1 -RepoPath "D:\DSH-Backups" -SkipInitial

# 如需备份 .credentials.yaml 与 APIKey（默认不备份）
.\setup.ps1 -RepoPath "D:\DSH-Backups" -IncludeCredentials
```

### 3. 安装插件

打开 DSH 桌面端的 **设置 → 插件**，选择从仓库安装，填写：

```text
https://github.com/SShiRkiT/dsh-quick-backup
```

然后重启 DSH，应该能看到 **设置 → 备份**。

> 私有仓库需要先完成 GitHub 登录；公开后不需要。
> 开发调试时也可以让 DSH 指向你本地的仓库目录。

### 4. 使用

打开 **设置 → 备份**。如果 setup 没有配置过备份路径，在 **备份仓库路径** 输入框中填写路径，然后点 **保存路径**。

| 控件 | 作用 |
| --- | --- |
| 备份仓库路径 | 设置或修改本地数据仓库路径 |
| 备份凭据与 APIKey | 默认关闭；开启后备份 `.credentials.yaml` 和 APIKey |
| 备份 | 增量备份（遵守 60 秒最小间隔） |
| 忽略间隔备份 | 立即强制备份 |
| 校验 / 深度校验 | 校验仓库与 Git 对象 |
| 历史版本 | 选择版本 |
| 复制恢复命令 | 复制安全的恢复命令 |
| 导出 | 将选定版本导出到新目录 |
| 启用 / 停用 | 安装/移除登录 watcher |
| 运行诊断 | 执行一次不备份的 watcher 检查 |

## 备份仓库路径

- 插件默认路径为**空**；不会擅自假设某个目录。
- `setup.ps1` 会把选定路径写入 `%LOCALAPPDATA%\dsh-quick-backup\config.json`。
- 插件也支持环境变量 `DSH_BACKUP_REPO`（优先级最高）和同一个配置文件。
- 路径必须是本地绝对路径，例如 `D:\DSH-Backups`。
- 该目录必须是由 `setup.ps1` 创建的数据仓库（包含 `scripts\backup.ps1`）。如果还没初始化，面板会显示“未就绪”并提示先运行 setup。
- 在插件中修改路径会立即生效，不需要重启 DSH。

## 凭据备份开关

- 默认**关闭**：不备份 `.credentials.yaml` 与 `APIKey`。
- 可在 **设置 → 备份 → 备份凭据与 APIKey** 开启，或在 setup 时使用 `-IncludeCredentials`。
- 开启后，后续版本会包含这两项；关闭只会排除后续版本，**旧 Git 历史不会自动清理**。如果之前备份过凭据，需要重建数据仓库或清理 Git 历史，才能真正移除旧副本。

## 版本规则

格式：`vYYMMDD.E.SSS`

| 段 | 含义 |
| --- | --- |
| `YYMMDD` | 当前**大环境基线**建立日期 |
| `E` | 该日期内第几次大环境变动（1、2……；跨天重置为 1） |
| `SSS` | 该基线内第几次小变动（001……；大环境变动时重置） |

以下情况进位：

- **大版本 / 环境变动**：DSH 升级、插件安装/更新/移除、`dsh-ops` 或运行时更新
- **小版本**：会话、附件、设置、凭据、工作区状态、脚本/文档更新

示例：

```text
v261025.1.001   基线
v261025.1.002   新对话
v261025.2.001   同一天更新插件
v261026.1.001   次日升级 DSH
```

详细规则见 [docs/VERSIONING.md](docs/VERSIONING.md)。

## 仓库结构

```text
dsh-quick-backup/          # 本仓库（不含个人数据）
├─ package.json            # DSH 插件包根配置
├─ lib/                    # 插件 host + client
├─ cordis.patch.yml
├─ scripts/                # 会复制到数据仓库的工作流脚本
├─ setup.ps1               # 创建本地数据仓库
├─ docs/
└─ test/                   # 插件自测

<你选择的路径>/             # 数据仓库（仅本地，绝不提交到这里）
├─ .git/                   # 备份历史
├─ mirror/                 # 当前 DSH 状态镜像
├─ state/                  # 日志、每版本元数据（gitignored）
├─ backup.config.json      # 本地配置（gitignored）
├─ version.txt
├─ VERSIONS.md
└─ scripts/
```

数据仓库是一个**独立**的 Git 仓库。本项目的 `.gitignore` 不会跟踪任何备份数据。

## 命令行

以下命令都在**数据仓库**中运行：

```powershell
$B = "D:\DSH-Backups"

# 立即备份
powershell -ExecutionPolicy Bypass -File "$B\scripts\backup.ps1" -Trigger manual

# 查看版本
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" -List

# 回档（会关闭 DSH！）
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" v261025.1.002 -Force

# 只导出
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" v261025.1.002 -ExtractTo "D:\DSH-restore-261025-1-002"

# 校验
powershell -ExecutionPolicy Bypass -File "$B\scripts\verify.ps1" -Deep
```

## 缓存文件不备份

以下内容会被有意排除，避免单纯重启就产生新版本：

- `.dsh\cache`、`.dsh\logs`
- `storages\session_projcache*`
- `storages\cost-meter\`（包括 `ledger.json`；**成本历史不备份**）
- `studymate\reach\`
- Electron 的 `Cache`、`Code Cache`、`GPU*`、`logs`、`Local Storage`、`Session Storage`、`Network`、`Shared Dictionary`、`blob_storage`、`WebStorage`、`Preferences`、`LOG*`、`lockfile`、`Cookies*`、`DIPS*`
- `profiles\node_modules`（失效 junction）
- DSH 程序本体

会话正文（`sessions`、`attachments`）和设置**会**被备份。

## 回档安全

- 回档脚本会关闭 DSH（当前会话会结束）。
- 当前 profile 会被改名为 `.dsh.pre-restore-<时间戳>`，而不是直接删除。
- 设置页**不会**直接执行回档；插件只复制一条命令，由你在独立 PowerShell 窗口中运行。
- 回档前请先确认选定版本的 DSH 程序版本与当前一致（仓库中保存了 `install-info.txt`）。
- 回档完成后，下一次备份会把回档后的状态记录为新版本。

## 隐私与安全

- 备份数据仓库**仅在本地**；`push.default=nothing` 和 `pre-push` 钩子会阻止误推送。
- 数据仓库包含你的会话、附件、设置等隐私内容；若开启凭据备份，还会包含**明文凭据**（`.credentials.yaml`、`APIKey`），请按敏感数据保管。
- 本 GitHub 仓库**不包含**任何凭据、会话、profile 副本或备份数据。
- 不要把数据仓库上传到 GitHub 或云盘。

详见 [docs/SECURITY.md](docs/SECURITY.md)。

## 卸载

```powershell
# 移除 setup 安装的登录 watcher
powershell -ExecutionPolicy Bypass -File "D:\DSH-Backups\scripts\uninstall-autostart.ps1"

# 移除插件
dsh plugin --profile desktop remove dsh-quick-backup
```

只有当你不再需要历史时才删除数据仓库。

## 故障排查

- 设置里没有插件：检查 `dsh plugin --profile <name> list`，然后重启 DSH。
- 面板显示“未就绪”：路径为空，或该目录不是数据仓库；运行 `setup.ps1 -RepoPath <path>`，或保存正确的路径。
- 备份失败：查看 `state\logs\backup.log`、`state\last-run.json`。
- 正常使用**不需要** Git 认证；本工具从不推送。
- 需要对象完整性检查时运行 `verify.ps1 -Deep`。

## 开发

```powershell
# PowerShell 语法检查（Windows PowerShell 5.1）
powershell -File .\scripts\verify.ps1   # 需要已有数据仓库

# 插件自测
node .\plugin\verify.mjs
```

`test/verify.mjs` 使用临时 fixture，不会接触你的 DSH 数据。

## 许可证

MIT，见 [LICENSE](LICENSE)。
