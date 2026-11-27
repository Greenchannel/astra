@echo off
setlocal
cd /d "%~dp0"

where uv >nul 2>nul
if errorlevel 1 (
    echo.
    echo 未找到 uv。请先安装 uv：https://docs.astral.sh/uv/
    echo 或参考 README.md 使用其他方式启动。
    echo.
    pause
    exit /b 1
)

uv run astra
if errorlevel 1 pause
