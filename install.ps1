<#
  MiniMax-H3 8GB 工具箱 —— 安装脚本
  ------------------------------------------------------------------
  把本仓库的脚本装进你的 ComfyUI 便携版，并在桌面创建快捷方式。

  用法（在仓库目录里执行）：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -ComfyRoot "D:\ComfyUI_windows_portable"
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoShortcuts
#>
param(
    [string]$ComfyRoot = '',
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# ---------- 定位 ComfyUI ----------
if (-not $ComfyRoot) {
    if ($repo -and (Test-Path (Join-Path $repo 'python_embeded\python.exe'))) {
        $ComfyRoot = $repo
    } elseif (Test-Path 'C:\ComfyUI_windows_portable\python_embeded\python.exe') {
        $ComfyRoot = 'C:\ComfyUI_windows_portable'
    } else {
        Say '找不到 ComfyUI 便携版，请用 -ComfyRoot 指定它的目录，例如：' 'Red'
        Say '    .\install.ps1 -ComfyRoot "D:\ComfyUI_windows_portable"'
        Read-Host '按回车退出'
        exit 1
    }
}
if (-not (Test-Path (Join-Path $ComfyRoot 'python_embeded\python.exe'))) {
    Say "目录不像 ComfyUI 便携版（找不到 python_embeded）：$ComfyRoot" 'Red'
    Read-Host '按回车退出'
    exit 1
}

$comfyDir = Join-Path $ComfyRoot 'ComfyUI'
Say ''
Say '==================================================' 'Cyan'
Say '        MiniMax-H3 8GB 工具箱 · 安装' 'Cyan'
Say '==================================================' 'Cyan'
Say "仓库    : $repo"
Say "ComfyUI : $ComfyRoot"
Say ''

function Copy-Into($srcItem, $dstDir) {
    if (-not (Test-Path $srcItem)) { return }
    $srcFull = (Resolve-Path $srcItem).Path
    $dstFull = (Resolve-Path $dstDir -ErrorAction SilentlyContinue).Path
    if ($dstFull -and $srcFull -eq $dstFull) { return }   # 仓库就在目标位置，跳过
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    if ((Get-Item $srcItem).PSIsContainer) {
        # 目录：把里面的文件合并进目标子目录（跳过 __pycache__）
        $leaf = Split-Path $srcItem -Leaf
        $target = Join-Path $dstDir $leaf
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem $srcItem -Exclude '__pycache__' | ForEach-Object {
            Copy-Item $_.FullName $target -Recurse -Force
        }
    } else {
        Copy-Item $srcItem $dstDir -Force
    }
}

# ---------- 拷贝脚本 ----------
Say '[1/4] 拷贝脚本 ...' 'Yellow'
foreach ($f in 'launch-h3.ps1', 'make-h3-film.ps1', 'h3-make-film.ps1') {
    Copy-Into (Join-Path $repo $f) $ComfyRoot
    Say "    $f"
}
Copy-Into (Join-Path $repo 'h3-studio') $ComfyRoot
Say '    h3-studio\'
foreach ($f in 'server.py', 'index.html', 'start.ps1', 'run-ref-shot.ps1', 'h3_ref_run.py', 'h3_post.py') {
    if (-not (Test-Path (Join-Path $ComfyRoot "h3-studio\$f"))) { Say "    !! 缺少 h3-studio\$f" 'Red' }
}

Say '[2/4] 安装自建节点 ...' 'Yellow'
$nodeSrc = Join-Path $repo 'custom_nodes\comfyui-h3-segment-prompt'
Copy-Into $nodeSrc (Join-Path $comfyDir 'custom_nodes')
Say '    comfyui-h3-segment-prompt（全局+分段提示词）'

Say '[3/4] 复制工作流 ...' 'Yellow'
$wfDst = Join-Path $comfyDir 'user\default\workflows'
New-Item -ItemType Directory -Path $wfDst -Force | Out-Null
Get-ChildItem (Join-Path $repo 'workflows') -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName $wfDst -Force
    Say "    $($_.Name)"
}

# ---------- 桌面快捷方式 ----------
Say '[4/4] 创建桌面快捷方式 ...' 'Yellow'
if (-not $NoShortcuts) {
    $ws = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcuts = @(
        @{ Name = 'MiniMax-H3 启动';        Script = (Join-Path $ComfyRoot 'launch-h3.ps1');          Icon = 16;  Desc = '启动 ComfyUI（进阶调参用）' },
        @{ Name = 'MiniMax-H3 一键出片';    Script = (Join-Path $ComfyRoot 'h3-studio\start.ps1');    Icon = 220; Desc = '中文表单出片（推荐）' },
        @{ Name = 'MiniMax-H3 参考图出片';  Script = (Join-Path $ComfyRoot 'h3-studio\run-ref-shot.ps1'); Icon = 221; Desc = '用人物/道具/场景参考图出片' },
        @{ Name = 'MiniMax-H3 制作长视频';  Script = (Join-Path $ComfyRoot 'make-h3-film.ps1');      Icon = 116; Desc = '问答式自动出长片' }
    )
    foreach ($s in $shortcuts) {
        $lnk = $ws.CreateShortcut((Join-Path $desktop ($s.Name + '.lnk')))
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $s.Script + '"'
        $lnk.WorkingDirectory = Split-Path $s.Script -Parent
        $lnk.IconLocation = "%SystemRoot%\System32\shell32.dll,$($s.Icon)"
        $lnk.Description = $s.Desc
        $lnk.Save()
        Say "    $($s.Name)"
    }
} else {
    Say '    （已跳过）'
}

# ---------- 模型检查 ----------
Say ''
Say '---- 模型检查 ----' 'Cyan'
$models = @(
    @{ File = 'diffusion_models\minimax_h3_fl2va_pruned_nvfp4.safetensors';                                 Size = '10.9 GB' },
    @{ File = 'text_encoders\qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors';                                 Size = '14.6 GB' },
    @{ File = 'vae\minimax_h3_video_vae_int8_convrot.safetensors';                                          Size = '2.6 GB' },
    @{ File = 'vae\minimax_h3_audio_vae_fp32.safetensors';                                                  Size = '0.6 GB' },
    @{ File = 'loras\minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors';                       Size = '1.8 GB' },
    @{ File = 'loras\minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors';                           Size = '1.8 GB' }
)
$missing = @()
foreach ($m in $models) {
    $full = Join-Path $comfyDir ('models\' + $m.File)
    if (Test-Path $full) {
        Say ("    OK   {0}" -f (Split-Path $m.File -Leaf)) 'Green'
    } else {
        Say ("    缺   {0}   （{1}）" -f (Split-Path $m.File -Leaf), $m.Size) 'Red'
        $missing += $m.File
    }
}

if (-not (Test-Path (Join-Path $comfyDir 'custom_nodes\ComfyUI-H3-Motion-Context'))) {
    Say ''
    Say '    提醒：长视频衔接需要第三方节点，还没装的话执行：' 'Yellow'
    Say ('        cd "' + (Join-Path $comfyDir 'custom_nodes') + '"')
    Say '        git clone https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context'
}

Say ''
if ($missing.Count -gt 0) {
    Say '模型还没下全。请到 Hugging Face 仓库按文件名搜索下载：' 'Yellow'
    Say '    https://huggingface.co/Comfy-Org/MiniMax-H3_ComfyUI_repackaged'
    Say '（国内网络可试 https://hf-mirror.com 镜像）'
    Say ''
}
Say '安装完成！双击桌面的「MiniMax-H3 一键出片」开始用。' 'Green'
Say '详细玩法见 docs\使用说明.md' 'Gray'
Read-Host '按回车退出'
