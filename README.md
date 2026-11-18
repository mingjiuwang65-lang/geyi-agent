# 格一代理（GeYiProxy）客户端源码

Windows 托盘代理客户端 + Linux 一键安装客户端。从 WorkBuddy 项目平移，供 CodeBuddy 继续开发。

## 目录结构

| 目录 | 内容 |
|---|---|
| `src/格一代理.cs` | 主源码（C#，约 121KB；托盘/配置中心/自动切换/随机轮换/升级器/安装卸载全在此单文件） |
| `src/build.ps1` | 编译打包脚本（CodeDOM/csc，**非 Visual Studio**） |
| `src/pack.py` / `make_icons.py` | 内嵌 payload 打包、图标生成 |
| `src/version.txt` | 版本号（VER / BUILD / CFGVER / PRODUCT） |
| `src/update.manifest.sample` | 升级清单样例 |
| `payload/` | 内嵌到 exe 的脚本/配置（PowerShell/VBS/conf），**不含私钥** |
| `linux/` | Linux 客户端：`install.sh` / `uninstall.sh` / `geYiProxy`（status/rotate/uninstall） |
| `windows/` | Windows 安装/卸载 bat + 说明 |
| `docs/` | 项目进度说明 + Linux 测试报告与安装指南 |

## 当前版本

- **1.3.1**（BUILD 20261118-1，CFGVER 3）
- exe SHA256：`E59C6A292B965AFF9F4F4F6BE02BE034522CD817D21DAFF2B9CD6EA369783015`（794112B）
- Windows zip SHA256：`3198144C8E5AC11E40D55C6A777823B590263CACC89A2F663602FD65FFE69602`
- Linux tar.gz SHA256：`28DFD445FCAF28D023C554D88CC9C7EB0F23AB71A891BF2E426D2C01B94F0348`

## ⚠️ 接手必读（三个致命坑）

### 1. 私钥不在仓库内，必须线下注入
本仓库**只有公钥和签名**（`payload/ca_root_pub.xml`、`ca_sign_pub_*.xml`、`bp_sig_*.txt`）。
以下私钥**故意未入库**，需从原工作区线下安全介质注入，否则无法构建 CA 链：
- `ca_root_priv.xml`（根私钥，PEM 格式）
- `ca_sign_priv_195/196/197/198.xml`（业务私钥，.NET XML 格式）
- `internet_assistant_ca.cer`、`geyi.ico`、`geyi_logo.png`（二进制，原 payload 内有）

### 2. 编译必须走 ASCII 暂存目录
`build.ps1` 用 CodeDOM/csc，`powershell.exe -File` 按 OEM 代码页读脚本，**中文路径会乱码**。
正确做法：
```powershell
# 把 src 复制到纯 ASCII 目录（如 C:\temp\geyi_build）再编译
$env:GEYI_BUILD_ROOT = 'C:\temp\geyi_build'
Set-ExecutionPolicy -Scope Process Bypass
& 'C:\temp\geyi_build\build.ps1'
```
构建产物 30 个 payload 文件需在 `C:\temp\payload`，输出到 `C:\temp\格一代理.exe`。

### 3. 金丝雀铁律（部署安全）
任何客户端升级**必须先在本机 `mingjiu-pc` 验证**（版本号变更、新功能出数、进程不崩、无回滚），
通过后才允许改 `update.manifest` 的 `PHASE=all` 全量推送。**禁止跳过金丝雀直接全量。**

## 升级器三条铁律（违反会变无限重启循环）

1. **禁止 `File.Copy` 覆盖运行中的 exe** → 必须 rename-exchange（写 `.new` → Move 改名）。
2. **升级失败必须清 `pending_update.flag`** → 否则每次启动重装 → 守护拉起 → 死循环。
3. **必须做版本数值比较**（`Util.CompareVer`）→ 待装版本 ≤ 当前版本直接忽略。

## 服务端配套（不在本仓库）

5 个代理节点（195~199，`10.0.50.195~199`）的发布点唯一在 199：
`http://10.0.50.199:15889/geyi/`，提供 `geyi_agent.exe` / `update.manifest` / 下载页 / 校验文件。
节点服务脚本 `proxy_gw_service.ps1` 及 CA 轮换链在原工作区 `ProxyClient_Packages/198_deploy/`。

## 节点设计（已去角色化）

195~199 五台为**同构自动分配池**，无固定角色。客户端健康探测 + 连续 3 次异常自动切换 +
随机轮换（只从健康池挑、空闲才切），失效节点自动剔除，不选失效节点上线。
