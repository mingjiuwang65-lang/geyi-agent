格一代理 · Windows 客户端
=========================
版本 1.3.0 · 含桌面快捷方式 / 开机自启 / 程序内卸载

【一键安装】
双击  install_windows.bat
  - 自动安装到 %LOCALAPPDATA%\ProxyClient
  - 创建桌面快捷方式「格一代理」
  - 写入开机自启 (注册表 Run + 守护任务)
  - 写入控制面板卸载项
  - 启动托盘, 右下角显示 5 节点状态

【直接运行】
双击  geyi_agent.exe  -> 启动托盘
右键 geyi_agent.exe 运行:  geyi_agent.exe /install   (等价一键安装)

【卸载】
方法一: 桌面/开始菜单 -> 右键「卸载 格一代理」
方法二: 托盘图标 -> 「卸载 格一代理...」
方法三: 控制面板 -> 程序和功能 -> 格一代理 -> 卸载
方法四: 双击  uninstall_windows.bat
  卸载会清理: 托盘/守护任务/开机自启/桌面快捷方式/开始菜单/卸载项/系统代理/CA

【下载与校验】
http://10.0.50.199:15889/geyi/geyi_agent.exe
SHA256: e59c6a292b965aff9f4f4f6be02be034522cd817d21daff2b9cd6ea369783015
certutil -hashfile geyi_agent.exe SHA256
