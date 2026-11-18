格一代理 (GeYiProxy) 1.1.0 — Windows 正式交付说明
============================================================

【本次版本变化】
  1) 图标换成格一集团 logo：exe 文件图标、任务栏托盘图标、配置窗口 banner 全部统一；
     托盘在 logo 右下角叠加状态色点（绿/黄/红/灰）。
  2) 新增原生配置窗口（托盘右键「配置 / 服务器管理...」、双击图标、开始菜单
     「配置 格一代理」或 /config）：可增删改服务器、切换当前服务器、配置每台服务器
     的 CA 验签链与直连例外，并直接切换运行模式、查看状态、管理升级。
  3) 多代理服务器：servers.conf 为唯一配置源，active_server.txt 指定当前服务器。
     每台服务器独立绑定「代理地址/端口 + CA 分发端点 + RSA 验签公钥 + 直连例外」。
     切换时自动：写 active → 改代理 → 清旧 CA → 验签装新 CA → 触发在线监测心跳。
     signed 模式与现在的 199 完全一致（明文内网 /ca.txt + RSA-SHA256 验签）。
  4) 版本控制 + 自动升级：version.txt 单点生成 VER/BUILD/CFGVER，注入 exe 程序集版本、
     app_version.txt、托盘菜单、配置窗口和「程序和功能」。升级清单 SHA256 校验 +
     canary/all 灰度，PHASE=canary 时只有 mingjiu-pc 能自动装。

【交付物】
  格一代理.exe   单文件原生程序(.NET Framework 4.0 WinForms GUI 子系统, AnyCPU)
                 组件、CA、公钥、配置、在线监测、升级器、卸载逻辑全部内嵌。
  publish\       可直接发布的升级点：格一代理.exe + update.manifest (含 SHA256/SIZE)。
  源码\          格一代理.cs / build.ps1 / version.txt / make_icons.py / pack.py /
                 update.manifest.sample / geyi.ico 及全部 payload，可审计、可重编译。

【适用系统】
  Windows 7 SP1 / Windows 10 / Windows 11，x86 / x64。依赖 .NET Framework 4.0+（系统自带）。
  普通用户即可安装/卸载；管理员运行可额外写 HKLM 吊销检查与本机级 CA。

【安装 — 一步】
  双击 格一代理.exe（首次静默安装后当前进程直接变托盘常驻，零 CMD/PS 弹窗）。
  静默/批量：格一代理.exe /install /silent
  再次运行：单实例，不会开第二个托盘。

【配置窗口 / 托盘开关】
  托盘右键 →「配置 / 服务器管理...」，或双击托盘图标，或：
      "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /config
  四个页签：
    代理服务器   列表增删改复制；名称 / 主机 / 端口 / CA 模式 / CA 分发地址 /
                验签公钥(可导入) / 本地证书(可导入) / 直连例外；
                「设为当前服务器并应用」「仅保存配置」。
    运行与状态   自动 / 强制代理 / 强制直连 + 立即应用、刷新状态、立即重新检测。
    版本与升级   清单地址、允许自动安装、检查间隔；立即检查更新、手动批准安装。
    关于         版本号 / BUILD / CFGVER / 架构红线。
  托盘右键另有「切换代理服务器」子菜单（当前项打勾）与「运行模式」子菜单，
  不用打开窗口也能一键切换。

【多服务器 / 各走各的 CA】
  servers.conf 格式（UTF-8，管道分隔，CFGVER=2）：
      id|name|host|port|caMode|caUrl|caCert|pubKey|bypass|enabled
  caMode:
    signed  从 <caUrl> 取 VER/THUMB/TS/CA/SIG，用该服务器自己的 <pubKey> 做
            RSA-SHA256 验签，校验自签名 / subject=mitmproxy / 未过期 / 指纹一致，
            装当前 CA 并清理旧的 mitmproxy 根证书。与 199 现有机制逐字一致。
    static  导入安装目录下的本地 DER 证书 <caCert>，校验自签名与有效期。
    none    该服务器不做 TLS 中间人，不装 CA。
  新增第二台网关：配置窗口点「新增」→ 填主机/端口/CA 地址 → 「导入...」该网关的
  ca_sign_pub_<id>.xml（公钥 XML，私钥永远留在网关）→ 「设为当前服务器并应用」。
  命令行等价：
      "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /switch srv2
      "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /servers
  注意：切换后若新网关不可达，在线监测会按 fail-open 自动关代理，回家/离线不会断网。

【版本控制】
  版本单点来源：源码\version.txt（VER / BUILD / CFGVER / PRODUCT）。
  build.ps1 编译前注入 AssemblyVersion、FileVersion、C# 常量和 app_version.txt，
  并自动计算 exe 的 SHA256/SIZE 生成 publish\update.manifest。
  查看版本：
      "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /version
      "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /status
  版本同时显示在托盘菜单、配置窗口、状态文本与「程序和功能」DisplayVersion。

【自动升级（canary 灰度铁律已写进程序）】
  发布点：把 publish\ 整个目录放到内网 Web / UNC 共享 / 本地目录，客户端
  update.conf 的 UPDATE_URL 指向其中的 update.manifest。
  清单字段：VER / BUILD / URL / SHA256 / SIZE / PHASE / CANARY_HOSTS / NOTE。
  检查：ProxyClient_TrayGuard 每分钟任务里节流到默认 60 分钟查一次；托盘菜单
  「立即检查更新」可强制。下载后必须 SHA256 + SIZE 双校验，不符直接删除拒装。
  放行规则（硬编码，不能靠清单绕过）：
      PHASE=canary  仅 CANARY_HOSTS 列出的主机(默认 mingjiu-pc)可自动安装
      PHASE=all     全体客户端放行
      PHASE=hold    全部只提示不安装
      AUTO_UPDATE=0 全部只提示，需人工点「手动批准并安装更新」
  安装：托盘发现 pending_update.flag → 启动已校验的新 exe /upgrade → 停旧托盘 →
  覆盖 格一代理.exe → 重放安装器（保留 servers.conf / active_server.txt /
  update.conf / 各服务器公钥与证书）→ 写回版本号 → 拉起新托盘。
  日志：%LOCALAPPDATA%\ProxyClient\update.log、upgrade.log、update_state.txt。

  【升级铁律】任何新版必须先 PHASE=canary 只推 mingjiu-pc：
  确认「版本号已变更 + 托盘常驻 + verify=PASS + 配置保留 + 可回滚」之后，
  才把清单改成 PHASE=all 分批推其余机器；全量脚本必须显式排除 mingjiu-pc。

【卸载 — 三种入口】
  控制面板「程序和功能」→ 格一代理 → 卸载 / 托盘右键 →「卸载 格一代理...」/
  命令行 格一代理.exe /uninstall [/silent]。
  按序清：任务 → 托盘 → 启动项/ARP/快捷方式 → 代理与吊销 → 环境变量 →
  全部 mitmproxy 根证书 → 安装目录(含 servers.conf、升级组件、downloads) → 延迟删自身。
  日志 %TEMP%\GeYiProxy_uninstall.log。卸载后浏览器恢复直连。

【托盘颜色】
  绿 = 当前服务器代理生效 / 海外可访问；黄 = 直连中；
  红 = 网关不可达但代理仍开(断网风险)；灰 = 在线监测心跳超过 240 秒。
  心跳超时/恢复属于假告警，只静默换图标不弹气泡；真实状态变化有 2 分钟冷却。
  托盘自救只补一次决策，绝不把用户手选的 On/Off 强行改回 Auto。

【v1.1.0 修复：电池供电时在线监测停摆（2026-11-14 实测）】
  症状：托盘反复提示「等待在线监测状态」/「海外可访问」，但上网一直正常。
  根因：New-ScheduledTaskSettingsSet 默认带
        DisallowStartIfOnBatteries=true / StopIfGoingOnBatteries=true，
        笔记本拔电源后 Windows 直接停掉两个 PT1M 任务 -> Guard 不写心跳。
  修复：task_ctl.ps1 注册时显式关掉这两个位（Win7 回退路径改 XML 后再注册）。
  复核两个位必须为 false：
        powershell -NoProfile -Command "Export-ScheduledTask -TaskName ProxyClient_TrayGuard | Select-String IfOnBatteries"
  网络侧判据：连续 20 次 TCP 探测网关端口全通即与网络无关。

【一键开关】
  "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /setmode On|Off|Auto
  "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /checkupdate
  "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /approve

【架构红线】
  * 10.0.50.199:15888 是「上网助手」(移动一机一PIN 管控) 的正向代理，必须保留
    MITM；15900 管理通道一律不动；不能改成纯隧道。
  * proxy_mode.ps1 是代理注册表的唯一写入点；托盘只读 proxy_state.txt、只发令，
    自动决策由 PT1M 的 ProxyClient_TrayGuard 承担，托盘挂了不影响上网。
  * 两个计划任务均以 wscript.exe GUI 子系统为宿主，零 CMD 黑框 / 零 PS 蓝框。
  * 内网 10/172.16-31/192.168 与微信/QQ 域名在 ProxyOverride 里直连。
  * CA 签名私钥只在网关，不在交付包内；客户端每分钟验签同步，IA 轮换 CA 可自愈。

【验证】
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\ProxyClient\verify.ps1"
  RESULT=PASS 即验收通过（On 态与 fail-open 直连态均判 PASS）。

【剩余风险 / 上线必读】
  1) exe 未做企业代码签名。首次运行可能被 SmartScreen/360 按「未知发布者」拦。
     全量推送前务必签名，或把 SHA256 加进终端管控/杀软哈希白名单。
     升级包同样要签名；清单的 SHA256 只保证传输完整，不保证发布者身份。
  2) 非管理员安装时 HKLM 吊销检查与本机级 CA 不写入（HKCU 级已够浏览器用）。
  3) 不主动触发真·IA/CA 轮换（需重启 IA 并 GUI 重新登录，属生产风险操作）。
  4) Linux 两包仍缺真机金丝雀；本次仅宣布 Windows EXE 包可交付。
  5) 全量推送脚本必须显式排除 mingjiu-pc。
