# h3-make-film.ps1
# 用 MiniMax-H3 + Motion Context 自动拼出 1-2 分钟长视频：
#   第 1 段从头生成，之后每段都用上一段的 sampler 输出 latent 做尾部衔接，
#   每段开头被钉住的帧（默认 56 帧 ≈ 2.33s）由 Trim 节点裁掉，最后无损拼接成整片。
#
# 示例（9 段 × 15 秒，净时长约 1 分 55 秒，预计耗时约 30 分钟）：
#   .\h3-make-film.ps1 -Segments 9 -SecondsPerSegment 15 -BasePrompt "..." -OutFile D:\film\final.mp4
#
# 每段一个提示词时用 -PromptFile（每行一个）：
#   .\h3-make-film.ps1 -Segments 4 -PromptFile .\prompts.txt -OutFile D:\film\final.mp4

[CmdletBinding()]
param(
    [string]$Server = "http://127.0.0.1:8188",
    [string]$Ffmpeg = "",
    [string]$ComfyOutput = "",
    [int]$Width = 640,
    [int]$Height = 384,
    [int]$Steps = 4,
    [int]$Segments = 9,
    [int]$SecondsPerSegment = 15,
    [string]$ContextLength = "56",
    [int]$AudioContextLength = 48,
    [int]$Seed = 12345,
    [string]$BasePrompt = "A calm ocean at sunset, gentle waves rolling onto a sandy beach, warm golden light, slow camera push-in, ambient sea sound.",
    [string]$PromptFile,
    [string]$OutFile = "",
    [switch]$Crossfade,
    [int]$CrossfadeFrames = 6,
    [switch]$AssembleOnly,
    [string[]]$SegmentFiles,
    [string]$Unet = "minimax_h3_fl2va_pruned_nvfp4.safetensors",
    [string]$Clip = "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
    [string]$VideoVae = "minimax_h3_video_vae_int8_convrot.safetensors",
    [string]$AudioVae = "minimax_h3_audio_vae_fp32.safetensors",
    [string]$Lora = "minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors"
)

$ErrorActionPreference = 'Stop'
$script:Server = $Server

# 不传路径时自动识别 ComfyUI 目录：脚本所在目录 -> 默认安装位置
$comfyRoot = $null
foreach ($cand in @($PSScriptRoot, 'C:\ComfyUI_windows_portable')) {
    if ($cand -and (Test-Path (Join-Path $cand 'ComfyUI\output'))) { $comfyRoot = $cand; break }
}
if ($comfyRoot) {
    if (-not $ComfyOutput) { $ComfyOutput = Join-Path $comfyRoot 'ComfyUI\output' }
    if (-not $OutFile) { $OutFile = Join-Path $ComfyOutput 'h3_film\final.mp4' }
}
if (-not $ComfyOutput) { throw "无法自动识别 ComfyUI 目录，请用 -ComfyOutput 指定输出文件夹" }
if (-not $OutFile) { $OutFile = Join-Path $ComfyOutput 'h3_film\final.mp4' }

# 自动查找 ffmpeg：-Ffmpeg 指定 > PATH > 常见安装位置（避免写死某个会变的路径）
function Resolve-FfmpegPath([string]$Hint) {
    if ($Hint) {
        if (Test-Path $Hint) { return $Hint }
        throw "指定的 ffmpeg 不存在：$Hint"
    }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cands = @()
    $cands += Get-ChildItem "$env:LOCALAPPDATA\*\*\ffmpeg*" -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'bin\ffmpeg.exe' }
    $cands += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe')
    $cands += "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe"
    $cands += "${env:ProgramFiles(x86)}\ffmpeg\bin\ffmpeg.exe"
    foreach ($c in $cands) {
        if (-not $c) { continue }
        try {
            if (Test-Path -LiteralPath $c -PathType Leaf -ErrorAction Stop) { return $c }
        } catch {
            # 无权访问某个候选路径时继续搜索其他 FFmpeg 位置。
            continue
        }
    }
    throw "找不到 ffmpeg.exe。请安装 ffmpeg 并加入 PATH，或用 -Ffmpeg 参数指定完整路径。"
}
$Ffmpeg = Resolve-FfmpegPath $Ffmpeg

# H3 要求帧数满足 17n+5（官方模板用的就是这个公式）
$t = [math]::Max(5, [math]::Round($SecondsPerSegment * 24))
$Length = [int]($t + ((5 - ($t % 17)) % 17))
Write-Host "每段 $SecondsPerSegment 秒 -> $Length 帧 ($([math]::Round($Length/24,2))s)" -ForegroundColor Cyan

$trimSeconds = [int]$ContextLength / 24.0
Write-Host ("每段会裁掉 {0} 帧 = {1:N2}s 的衔接头（第一段无衔接头，不裁）" -f [int]$ContextLength, $trimSeconds) -ForegroundColor Cyan
$netSeconds = ($Length / 24.0) + ($Segments - 1) * ($Length / 24.0 - $trimSeconds)
Write-Host ("整片净时长约 {0:N0} 秒" -f $netSeconds) -ForegroundColor Cyan

$prompts = @()
if ($PromptFile) {
    $prompts = Get-Content $PromptFile | Where-Object { $_.Trim() -ne "" }
    if ($prompts.Count -lt $Segments) { throw "PromptFile 只有 $($prompts.Count) 行，但需要 $Segments 段" }
} else {
    for ($i = 1; $i -le $Segments; $i++) {
        if ($i -eq 1) { $prompts += $BasePrompt }
        else { $prompts += "$BasePrompt The shot continues seamlessly from the previous moment: identical subject, same camera movement and speed, same lighting and scene, continuous ambient sound." }
    }
}

function Submit-Graph([hashtable]$Graph) {
    $body = @{ prompt = $Graph; client_id = "h3-make-film" } | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $resp = Invoke-WebRequest -Uri "$script:Server/prompt" -Method Post -Body $bytes -ContentType "application/json" -UseBasicParsing
    $j = $resp.Content | ConvertFrom-Json
    if (-not $j.prompt_id) { throw "提交失败: $($resp.Content)" }
    return $j.prompt_id
}

function Wait-Graph([string]$PromptId, [string]$Label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Start-Sleep -Seconds 10
        $hist = (Invoke-WebRequest -Uri "$script:Server/history/$PromptId" -UseBasicParsing).Content | ConvertFrom-Json
        if ($hist.PSObject.Properties.Name -contains $PromptId) { break }
        Write-Host ("    {0} 运行中 {1:N1} 分钟" -f $Label, $sw.Elapsed.TotalMinutes)
    }
    $entry = $hist.$PromptId
    if ($entry.status.status_str -ne "success") {
        $entry.status | ConvertTo-Json -Depth 6 | Write-Host
        throw "生成失败: $Label"
    }
    Write-Host ("    {0} 完成，用时 {1:N2} 分钟" -f $Label, $sw.Elapsed.TotalMinutes) -ForegroundColor Green
    $file = $null
    foreach ($o in $entry.outputs.PSObject.Properties) {
        foreach ($k in $o.Value.PSObject.Properties) {
            if ($k.Name -eq "videos" -or $k.Name -eq "images" -or $k.Name -eq "gifs") {
                foreach ($item in $k.Value) {
                    if ($item.filename) {
                        # ComfyUI 只给文件名，子目录在 subfolder 字段里
                        if ($item.subfolder) { $file = Join-Path (Join-Path $ComfyOutput $item.subfolder) $item.filename }
                        else { $file = Join-Path $ComfyOutput $item.filename }
                    }
                }
            }
        }
    }
    return $file
}

function New-SegmentGraph([string]$Prompt, [int]$Index) {
    $g = @{}
    $g["1"]  = @{ class_type = "UNETLoader";         inputs = @{ unet_name = $Unet; weight_dtype = "default" } }
    $g["2"]  = @{ class_type = "LoraLoaderModelOnly"; inputs = @{ model = @("1", 0); lora_name = $Lora; strength_model = 1.0 } }
    $g["3"]  = @{ class_type = "CLIPLoader";         inputs = @{ clip_name = $Clip; type = "minimax" } }
    $g["4"]  = @{ class_type = "VAELoader";          inputs = @{ vae_name = $VideoVae } }
    $g["5"]  = @{ class_type = "VAELoader";          inputs = @{ vae_name = $AudioVae } }
    $g["6"]  = @{ class_type = "MiniMaxH3ImageToVideo"; inputs = @{ clip = @("3", 0); vae = @("4", 0); prompt = $Prompt; width = $Width; height = $Height; length = $Length } }

    $mc = @{ conditioning = @("6", 0); vae = @("4", 0); latent = @("6", 1); context_length = $ContextLength; audio_context_length = $AudioContextLength }
    if ($Index -gt 1) { $mc["context_latent"] = @("21", 0) }
    $g["7"]  = @{ class_type = "MiniMaxH3MotionContext"; inputs = $mc }

    $g["8"]  = @{ class_type = "BasicScheduler";     inputs = @{ model = @("2", 0); scheduler = "simple"; steps = $Steps; denoise = 1.0 } }
    $g["9"]  = @{ class_type = "KSamplerSelect";     inputs = @{ sampler_name = "res_multistep" } }
    $g["10"] = @{ class_type = "BasicGuider";        inputs = @{ model = @("2", 0); conditioning = @("7", 0) } }
    $g["11"] = @{ class_type = "RandomNoise";        inputs = @{ noise_seed = $Seed + $Index } }
    $g["12"] = @{ class_type = "SamplerCustomAdvanced"; inputs = @{ noise = @("11", 0); guider = @("10", 0); sampler = @("9", 0); sigmas = @("8", 0); latent_image = @("6", 1) } }
    $g["13"] = @{ class_type = "VAEDecode";          inputs = @{ samples = @("12", 0); vae = @("4", 0) } }
    $g["14"] = @{ class_type = "VAEDecodeAudio";     inputs = @{ samples = @("12", 0); vae = @("5", 0) } }
    $g["15"] = @{ class_type = "MiniMaxH3MotionContextTrim"; inputs = @{ images = @("13", 0); trim_frames = @("7", 1); audio = @("14", 0); fps = 24; match_tail = $true } }
    $g["16"] = @{ class_type = "CreateVideo";        inputs = @{ images = @("15", 0); fps = 24; audio = @("15", 1) } }
    $g["17"] = @{ class_type = "SaveVideo";          inputs = @{ video = @("16", 0); filename_prefix = ("h3_film/seg{0:d2}" -f $Index); format = "mp4" } }
    $g["18"] = @{ class_type = "MiniMaxH3MotionContextSaveLatent"; inputs = @{ latent = @("12", 0); filename_prefix = "h3_context/clip"; clip_index = $Index } }
    if ($Index -gt 1) {
        $g["21"] = @{ class_type = "MiniMaxH3MotionContextLoadLatent"; inputs = @{ latent_path = "h3_context"; clip_index = ($Index - 1) } }
    }
    return $g
}

$filmStart = Get-Date
$produced = @()
if (-not $AssembleOnly) {
    for ($i = 1; $i -le $Segments; $i++) {
        Write-Host "===== 第 $i / $Segments 段 =====" -ForegroundColor Cyan
        $g = New-SegmentGraph -Prompt $prompts[$i - 1] -Index $i
        $fn = Wait-Graph (Submit-Graph $g) ("seg$i")
        # Wait-Graph 现在直接返回绝对路径，不要再拼接前缀
        if ($fn) { $produced += [pscustomobject]@{ Index = $i; Path = $fn } }
    }
    Write-Host ("全部段落完成，总耗时 {0:N1} 分钟" -f ((Get-Date) - $filmStart).TotalMinutes) -ForegroundColor Green
} else {
    Write-Host "已跳过生成（-AssembleOnly），直接重新拼接已有片段" -ForegroundColor Yellow
}

# ---- 拼接 ----
$segDir = Join-Path $ComfyOutput "h3_film"
$segFiles = @()
if ($SegmentFiles -and $SegmentFiles.Count -gt 0) {
    $segFiles = $SegmentFiles
} elseif ($produced.Count -eq $Segments) {
    $segFiles = @($produced | Sort-Object Index | ForEach-Object { $_.Path })
} else {
    Write-Host "警告：无法确认本次运行的片段，改用『每个序号取最新文件』，可能混入其它批次，建议用 -SegmentFiles 明确指定" -ForegroundColor Yellow
    for ($i = 1; $i -le $Segments; $i++) {
        $f = Get-ChildItem $segDir -Filter ("seg{0:d2}_*.mp4" -f $i) | Sort-Object LastWriteTime | Select-Object -Last 1
        if (-not $f) { throw "缺少第 $i 段输出文件" }
        $segFiles += $f.FullName
    }
}
foreach ($p in $segFiles) { Write-Host ("  片段: {0}" -f (Split-Path $p -Leaf)) }

$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$inv = [Globalization.CultureInfo]::InvariantCulture

# 统一的 ffmpeg 调用封装：ffmpeg 会把日志写到 stderr，在 $ErrorActionPreference='Stop' 下会被当成错误
function Invoke-Ffmpeg([string[]]$ffArgs, [switch]$Quiet) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = (& $Ffmpeg @ffArgs 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0 -and -not $Quiet) { Write-Host $out.Trim() }
    return $code
}

function Get-Seconds([string]$p) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $s = (& $Ffmpeg -hide_banner -i $p 2>&1 | Out-String)
    $ErrorActionPreference = $saved
    $m = [regex]::Match($s, 'Duration: (\d+):(\d+):(\d+\.\d+)')
    if (-not $m.Success) { throw "无法读取时长: $p" }
    return ([int]$m.Groups[1].Value * 3600) + ([int]$m.Groups[2].Value * 60) + [double]$m.Groups[3].Value
}

if ($Crossfade -and $Segments -gt 1) {
    # 接缝处做短交叉溶解：把硬跳变摊成若干帧的柔和过渡（默认 6 帧 ≈ 0.25s）
    $d = $CrossfadeFrames / 24.0
    $dStr = $d.ToString('0.####', $inv)
    $fc = ""
    $prevV = "[0:v]"
    $prevA = "[0:a]"
    $L = Get-Seconds $segFiles[0]
    for ($i = 1; $i -lt $Segments; $i++) {
        $off = ($L - $d).ToString('0.####', $inv)
        $fc += $prevV + "[" + $i + ":v]xfade=transition=fade:duration=" + $dStr + ":offset=" + $off + "[v" + $i + "];"
        $fc += $prevA + "[" + $i + ":a]acrossfade=d=" + $dStr + ":c1=tri:c2=tri[a" + $i + "];"
        $prevV = "[v" + $i + "]"
        $prevA = "[a" + $i + "]"
        $L = $L + (Get-Seconds $segFiles[$i]) - $d
    }
    $last = $Segments - 1
    $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error')
    foreach ($p in $segFiles) { $ffArgs += @('-i', $p) }
    $ffArgs += @('-filter_complex', $fc.TrimEnd(';'), '-map', ("[v" + $last + "]"), '-map', ("[a" + $last + "]"),
                 '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
                 '-c:a', 'aac', '-b:a', '192k', $OutFile)
    $code = Invoke-Ffmpeg $ffArgs
    if ($code -ne 0) { throw "交叉溶解拼接失败" }
    Write-Host ("交叉溶解拼接完成：每处接缝 {0} 帧 ≈ {1:N2}s" -f $CrossfadeFrames, $d) -ForegroundColor Green
} else {
    $listPath = Join-Path $segDir "list.txt"
    $lines = @()
    foreach ($p in $segFiles) { $lines += "file '" + ($p -replace '\\', '/') + "'" }
    # 注意：不要用 Set-Content -Encoding UTF8（PS 5.1 会写 BOM），ffmpeg concat 列表不接受 BOM
    [System.IO.File]::WriteAllLines($listPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    & $Ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i $listPath -c copy $OutFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "无损拼接失败（可能段落参数不一致），改用重编码拼接..." -ForegroundColor Yellow
        $code = Invoke-Ffmpeg @('-y', '-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $listPath,
                                '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-c:a', 'aac', '-b:a', '192k', $OutFile)
        if ($code -ne 0) { throw "拼接失败" }
    }
}

$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dur = (& $Ffmpeg -hide_banner -i $OutFile 2>&1 | Out-String) -split "`n" | Where-Object { $_ -match "Duration" }
$ErrorActionPreference = $savedEap
Write-Host ""
Write-Host "成片: $OutFile" -ForegroundColor Green
Write-Host ($dur.Trim())
Write-Host ("大小: {0:N1} MB" -f ((Get-Item $OutFile).Length / 1MB))

# 成片统一复制一份到「下载」文件夹
$saveDir = Join-Path $env:USERPROFILE "Downloads"
try {
    if (-not (Test-Path $saveDir)) { New-Item -ItemType Directory -Path $saveDir -Force | Out-Null }
    $saved = Join-Path $saveDir (Split-Path $OutFile -Leaf)
    Copy-Item $OutFile $saved -Force
    Write-Host "已保存到: $saved" -ForegroundColor Green
} catch {
    Write-Host "复制到下载文件夹失败: $_" -ForegroundColor Yellow
}
