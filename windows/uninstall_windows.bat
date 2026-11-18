@echo off
rem 格一代理 Windows 一键卸载
if exist "%LOCALAPPDATA%\ProxyClient\格一代理.exe" (
    start "" /wait "%LOCALAPPDATA%\ProxyClient\格一代理.exe" /uninstall
) else (
    start "" /wait "%~dp0geyi_agent.exe" /uninstall
)
echo === 卸载完成 ===
pause
