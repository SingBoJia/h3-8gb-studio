<#
  MiniMax-H3 长视频制作（交互式）
  ------------------------------------------------------------------
  双击桌面快捷方式后按提示输入即可。全流程自动完成：
    确保 ComfyUI 在运行 -> 分段生成（每段尾部衔接下一段）-> 交叉溶解拼接 -> 打开成片
  参数（一般不用管）：
    -ComfyRoot      ComfyUI 便携版目录
    -NoOpenFolder   完成后不自动打开文件夹
#>
param(
    [string]$ComfyRoot = '',
    [switch]$NoOpenFolder
)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'MiniMax-H3 长视频制作' } catch { }

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

function Ask-Text([string]$Label, [string]$Default) {
    while ($true) {
        if ($Default) { $v = Read-Host "$Label [$Default]" } else { $v = Read-Host $Label }
        if ([string]::IsNullOrWhiteSpace($v)) {
            if ($Default) { return $Default }
            Write-Host '  不能为空，请重新输入。' -ForegroundColor Yellow
            continue
        }
        return $v.Trim()
    }
}

function Ask-Number([string]$Label, [double]$Default, [double]$Min, [double]$Max) {
    while ($true) {
        $v = Read-Host "$Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        $d = 0.0
        if ([double]::TryParse($v.Trim(), [ref]$d) -and $d -ge $Min -and $d -le $Max) { return $d }
        Write-Host ("  请输入 {0} ~ {1} 之间的数字。" -f $Min, $Max) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '            MiniMax-H3 长视频制作' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '直接按回车 = 使用方括号里的默认值' -ForegroundColor DarkGray
Write-Host ''

$prompt = Ask-Text '视频内容描述（中文英文都行，越具体越好）' ''
$seg    = [int](Ask-Number '分几段（每段最多 15 秒）' 9 1 60)
$sec    = Ask-Number '每段几秒' 15 1 15
$xf     = [int](Ask-Number '接缝交叉溶解帧数（0=硬切，6 帧≈0.25 秒）' 6 0 48)

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$defaultOut = Join-Path ([Environment]::GetFolderPath('Desktop')) "H3成片_$stamp.mp4"
$out = Ask-Text '输出文件' $defaultOut

# 和 ComfyUI 模板一致：帧数取 17n+5
$t   = [math]::Max(5, [math]::Round($sec * 24))
$len = [int]($t + ((5 - ($t % 17)) % 17))
$trim = 56 / 24.0
$net  = $len / 24.0 + ($seg - 1) * ($len / 24.0 - $trim)
$eta  = [math]::Round($seg * $sec * 0.24, 0)

Write-Host ''
Write-Host ('将生成 {0} 段 x {1} 帧（{2:N2} 秒/段）' -f $seg, $len, ($len / 24.0))
Write-Host ('成片净时长约 {0:N0} 秒（{1:N1} 分钟）' -f $net, ($net / 60))
if ($xf -gt 0) { Write-Host ("接缝处理：{0} 帧交叉溶解" -f $xf) } else { Write-Host '接缝处理：硬切' }
Write-Host ('预计耗时约 {0} 分钟（按 5060Ti 8GB 实测速度估算）' -f $eta)
Write-Host ''
$go = Ask-Text '确认开始？(Y/n)' 'Y'
if ($go -notmatch '^[Yy]') { Write-Host '已取消。'; Read-Host '按回车退出'; exit 0 }

# 确保 ComfyUI 在运行（用子进程调用，它的 exit 不会影响本脚本）
$launcher = Join-Path $ComfyRoot 'launch-h3.ps1'
if (Test-Path $launcher) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -NoBrowser
} else {
    Write-Host "提示：未找到启动器 $launcher，请确认 ComfyUI 已在运行。" -ForegroundColor Yellow
}

$film = Join-Path $ComfyRoot 'h3-make-film.ps1'
if (-not (Test-Path $film)) {
    Write-Host "找不到出片脚本：$film" -ForegroundColor Red
    Read-Host '按回车退出'; exit 1
}

Write-Host ''
Write-Host '开始生成（可以最小化这个窗口，期间别关它）...' -ForegroundColor Cyan
Write-Host ''

$sw = [Diagnostics.Stopwatch]::StartNew()
$filmArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $film,
              '-Segments', "$seg", '-SecondsPerSegment', "$sec",
              '-BasePrompt', $prompt, '-OutFile', $out)
if ($xf -gt 0) { $filmArgs += @('-Crossfade', '-CrossfadeFrames', "$xf") }

& powershell.exe @filmArgs
$code = $LASTEXITCODE
$mins = [math]::Round($sw.Elapsed.TotalMinutes, 1)

Write-Host ''
if ($code -eq 0 -and (Test-Path $out)) {
    Write-Host '完成！' -ForegroundColor Green
    Write-Host ("成片   : {0}" -f $out)
    Write-Host ("大小   : {0:N1} MB" -f ((Get-Item $out).Length / 1MB))
    Write-Host ("总耗时 : {0} 分钟" -f $mins)
    if (-not $NoOpenFolder) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $out) }
} else {
    Write-Host '生成过程中出错，请把上面的错误信息发给助手。' -ForegroundColor Red
}
Read-Host '按回车退出'
