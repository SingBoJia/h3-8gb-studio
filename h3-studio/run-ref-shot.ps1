<#
  MiniMax-H3 参考图出片（人物 / 道具 / 场景 参考）

  用法：双击桌面「MiniMax-H3 参考图出片」快捷方式，按提示回答即可。
  也可以直接命令行跑：
    .\run-ref-shot.ps1 -Seconds 12 -Quality high            # 832x480 20步，最清晰
    .\run-ref-shot.ps1 -Seconds 5  -Quality preview         # 480x288 4步，一分钟出结果
#>
param(
    [string]$PromptFile = "$PSScriptRoot\prompt-aiden.txt",
    [double]$Seconds = 12,
    [ValidateSet("preview", "standard", "high")]
    [string]$Quality = "high",
    [int]$Seed = 777,
    [string]$OutPrefix = "aiden",
    [switch]$Fps60,
    [string[]]$RefImages = @("ref_face.png", "ref_body.png", "ref_sword.png", "ref_scene.png"),
    [switch]$NoAsk
)

$ErrorActionPreference = 'Stop'

# 脚本就在 h3-studio 里，往上一层就是 ComfyUI 便携版根目录
$comfyRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $comfyRoot 'python_embeded\python.exe'))) { $comfyRoot = 'C:\ComfyUI_windows_portable' }
$py = Join-Path $comfyRoot 'python_embeded\python.exe'
$runner = Join-Path $PSScriptRoot 'h3_ref_run.py'

if (-not (Test-Path $py)) { $py = "python" }
if (-not (Test-Path $runner)) { throw "找不到 $runner" }

# 如果 ComfyUI 没在跑，自动把它拉起来
function Test-Comfy {
    try {
        Invoke-RestMethod "http://127.0.0.1:8188/system_stats" -TimeoutSec 4 | Out-Null
        return $true
    } catch { return $false }
}

if (-not (Test-Comfy)) {
    Write-Host "  ComfyUI 还没启动，正在自动打开（第一次要等 1-2 分钟）..." -ForegroundColor Yellow
    $launcher = Join-Path $comfyRoot 'launch-h3.ps1'
    if (Test-Path $launcher) {
        Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$launcher`""
    } else {
        Start-Process powershell.exe -ArgumentList "-NoProfile", "-Command", "Set-Location '$(Join-Path $comfyRoot 'ComfyUI')'; & '$py' -s main.py --port 8188 --reserve-vram 0.6 --disable-auto-launch"
    }
    $tries = 0
    while (-not (Test-Comfy)) {
        Start-Sleep -Seconds 5
        $tries++
        if ($tries -gt 60) { throw "ComfyUI 启动超时，请先双击桌面的「MiniMax-H3 启动」" }
        if ($tries % 6 -eq 0) { Write-Host "    还在启动... ($($tries * 5) 秒)" -ForegroundColor DarkGray }
    }
    Write-Host "  ComfyUI 就绪" -ForegroundColor Green
}

if (-not $NoAsk) {
    Write-Host ""
    Write-Host "  MiniMax-H3 参考图出片" -ForegroundColor Cyan
    Write-Host "  ----------------------" -ForegroundColor DarkGray
    Write-Host "  参考图按顺序：1)角色脸 2)角色全身 3)武器 4)场景" -ForegroundColor DarkGray
    Write-Host "  想让模型演什么，请在打开的记事本里改提示词（保存后回到本窗口）" -ForegroundColor DarkGray
    Write-Host ""
    Start-Process notepad.exe -ArgumentList $PromptFile -Wait

    $s = Read-Host "  要生成几秒？（直接回车 = $Seconds 秒）"
    if ($s) { $Seconds = [double]$s }

    Write-Host "  清晰度：1=预览(快)  2=标准  3=最高(慢，约 20 分钟)" -ForegroundColor Yellow
    $q = Read-Host "  选 1/2/3（直接回车 = 3）"
    switch ($q) {
        "1" { $Quality = "preview" }
        "2" { $Quality = "standard" }
        default { $Quality = "high" }
    }

    $n = Read-Host "  要不要顺便插帧到 60fps？（y/n，默认 y）"
    if ($n -ne "n" -and $n -ne "N") { $Fps60 = $true }
}

$params = @("--seconds", $Seconds, "--seed", $Seed, "--out-prefix", $OutPrefix, "--refs") + $RefImages
if ($PromptFile) { $params += @("--prompt-file", $PromptFile) }
switch ($Quality) {
    "preview" { $params += @("--width", 480, "--height", 288, "--steps", 4, "--use-turbo") }
    "standard" { $params += @("--width", 640, "--height", 384, "--steps", 12, "--use-turbo") }
    "high" { $params += @("--width", 832, "--height", 480, "--steps", 20) }
}
if ($Fps60) { $params += "--fps60" }

Write-Host ""
Write-Host "  开始生成，请耐心等待（关掉这个窗口会中断）..." -ForegroundColor Green
& $py -u $runner @params

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "  完成！成片已保存到「下载」文件夹。" -ForegroundColor Green
    Start-Process explorer.exe (Join-Path $env:USERPROFILE "Downloads")
}
