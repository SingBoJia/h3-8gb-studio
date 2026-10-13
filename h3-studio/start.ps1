<#
  MiniMax-H3 一键出片 —— 启动器
  双击桌面「MiniMax-H3 一键出片」后：没开就启动，然后自动打开浏览器。
#>
param(
    [int]$Port = 8799,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'

# 脚本就在 h3-studio 里，往上一层就是 ComfyUI 便携版根目录
$root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $root 'python_embeded\python.exe'))) { $root = 'C:\ComfyUI_windows_portable' }
$studio = $PSScriptRoot
$python = Join-Path $root 'python_embeded\python.exe'
$server = Join-Path $studio 'server.py'
$url = "http://127.0.0.1:$Port"

try { $Host.UI.RawUI.WindowTitle = 'MiniMax-H3 一键出片' } catch { }

function Test-StudioUp {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

if (-not (Test-Path $python) -or -not (Test-Path $server)) {
    Write-Host "找不到文件：$server" -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}

if (-not (Test-StudioUp)) {
    Write-Host '正在启动「一键出片」服务…' -ForegroundColor Cyan
    Start-Process -FilePath $python -ArgumentList @($server) `
        -WorkingDirectory $studio -WindowStyle Minimized
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-StudioUp) { break }
        Start-Sleep -Milliseconds 700
    }
}

if (Test-StudioUp) {
    Write-Host "已就绪：$url" -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process $url }
    Start-Sleep -Seconds 1
} else {
    Write-Host '启动超时，请看最小化的窗口里的报错。' -ForegroundColor Red
    Read-Host '按回车退出'
}
