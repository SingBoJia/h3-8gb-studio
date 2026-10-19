<#
  MiniMax-H3 启动器
  ------------------------------------------------------------
  - 若 ComfyUI 已在运行：直接打开浏览器
  - 若未运行：启动服务（给桌面留 0.6GB 显存），就绪后自动打开浏览器
  参数（一般不用改）：
    -Port        端口，默认 8188
    -ReserveVram 给桌面预留的显存 GB，默认 0.6
    -NoBrowser   只启动服务，不开浏览器
    -DisableDynamicVram  关闭动态显存（默认开启；三项同时关闭会导致加载 UNet 时崩溃）
    -DisableMmap         关闭 safetensors mmap（默认开启）
    -DisableAsyncOffload 关闭异步权重 offload（默认开启）
#>
param(
    [int]$Port = 8188,
    [string]$ComfyRoot = '',
    [double]$ReserveVram = 0.6,
    [switch]$NoBrowser,
    # 默认全部保持 ComfyUI 原生行为（DynamicVRAM / mmap / 异步 offload 均为开启）。
    # 传下面任一开关会相应关闭对应特性——已证实本机同时关闭三项会让 ComfyUI
    # 在加载 UNet 时进程级崩溃（access violation @ comfy/utils.py:175 load_torch_file）。
    [switch]$DisableDynamicVram,
    [switch]$DisableMmap,
    [switch]$DisableAsyncOffload
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
# 本机实测（16GB 页面文件 + 64GB 内存）：开启 pinned memory 时 aimdo 宿主缓冲
# 会把提交量顶到上限（81.4/81.6 GB）并报 GetOverlappedResult error=1450 / os error 1455，
# 加载权重即失败；关闭后提交量峰值 ~57 GB 且出片正常。
$comfyArgs = @('-s', $main, '--port', "$Port", '--reserve-vram', "$ReserveVram", '--disable-auto-launch', '--disable-pinned-memory')
if ($DisableDynamicVram) { $comfyArgs += '--disable-dynamic-vram' }
if ($DisableMmap) { $comfyArgs += '--disable-mmap' }
if ($DisableAsyncOffload) { $comfyArgs += '--disable-async-offload' }

Start-Process -FilePath $python `
    -ArgumentList $comfyArgs `
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
