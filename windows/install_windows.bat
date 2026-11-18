@echo off
rem 格一代理 Windows 一键安装 - 调用内置 /install (创建桌面快捷方式/开机自启/卸载项/托盘)
set "HERE=%~dp0"
echo === 格一代理 Windows 客户端 安装 ===
rem 若 exe 在 %LOCALAPPDATA%\ProxyClient 则直接安装, 否则先释放
if exist "%LOCALAPPDATA%\ProxyClient\格一代理.exe" (
    start "" /wait "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /install
) else (
    start "" /wait "%HERE%geyi_agent.exe" /install
)
echo.
echo === 安装完成: 桌面出现"格一代理"快捷方式, 托盘右下角显示 5 节点状态 ===
echo 卸载: 桌面右键 -> 卸载, 或 控制面板卸载, 或 托盘图标 -> 卸载 格一代理
pause
