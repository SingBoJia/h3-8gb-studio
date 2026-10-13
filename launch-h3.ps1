<#
  MiniMax-H3 启动器
  ------------------------------------------------------------
  - 若 ComfyUI 已在运行：直接打开浏览器
  - 若未运行：启动服务（给桌面留 0.6GB 显存），就绪后自动打开浏览器
  参数（一般不用改）：
    -Port        端口，默认 8188
    -ReserveVram 给桌面预留的显存 GB，默认 0.6
    -NoBrowser   只启动服务，不开浏览器
#>
param(
    [int]$Port = 8188,
    [string]$ComfyRoot = '',
    [double]$ReserveVram = 0.6,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'

# 不传 -ComfyRoot 时自动识别：脚本所在目录 -> 默认安装位置
if (-not $ComfyRoot) {
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'python_embeded\python.exe'))) {
        $ComfyRoot = $PSScriptRoot
    } elseif (Test-Path 'C:\ComfyUI_windows_portable\python_embeded\python.exe') {
        $ComfyRoot = 'C:\ComfyUI_windows_portable'
    } else {
        Write-Host '找不到 ComfyUI 便携版，请用 -ComfyRoot 指定它的目录。' -ForegroundColor Red
        Read-Host '按回车退出'
        exit 1
    }
}

$url = "http://127.0.0.1:$Port"
$python = Join-Path $ComfyRoot 'python_embeded\python.exe'
$main   = Join-Path $ComfyRoot 'ComfyUI\main.py'

if (-not (Test-Path $python) -or -not (Test-Path $main)) {
    Write-Host "找不到 ComfyUI，请检查目录：$ComfyRoot" -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}

function Test-ComfyUp {
    try {
        $r = Invoke-WebRequest -Uri "$url/system_stats" -UseBasicParsing -TimeoutSec 3
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

if (Test-ComfyUp) {
    Write-Host "ComfyUI 已经在运行：$url" -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}

Write-Host '正在启动 ComfyUI ...' -ForegroundColor Cyan
Start-Process -FilePath $python `
    -ArgumentList @('-s', $main, '--port', "$Port", '--reserve-vram', "$ReserveVram", '--disable-auto-launch') `
    -WorkingDirectory (Join-Path $ComfyRoot 'ComfyUI') `
    -WindowStyle Minimized

$deadline = (Get-Date).AddMinutes(5)
$spin = @('|', '/', '-', '\')
$i = 0
while ((Get-Date) -lt $deadline) {
    if (Test-ComfyUp) {
        Write-Host ''
        Write-Host "已就绪：$url" -ForegroundColor Green
        if (-not $NoBrowser) { Start-Process $url }
        Start-Sleep -Seconds 2
        exit 0
    }
    Write-Host ("`r等待服务就绪 {0} " -f $spin[$i % 4]) -NoNewline
    $i++
    Start-Sleep -Seconds 2
}

Write-Host ''
Write-Host '启动超时。请查看最小化的 ComfyUI 窗口里的日志。' -ForegroundColor Red
Read-Host '按回车退出'
exit 1
