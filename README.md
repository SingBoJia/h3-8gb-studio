# MiniMax-H3 8GB 显存本地出片工具箱

> 在 **8GB 显存** 的消费级显卡上把 MiniMax-H3 视频生成跑顺手的全套方案：
> 中文「一键出片」网页、多段拼接长视频（1~2 分钟）、参考图模式（人物 / 道具 / 场景）、
> 成片自动 60fps 插帧、自动存档到「下载」文件夹。
>
> 全部在 Windows + ComfyUI 便携版上实测通过（RTX 5060 Ti 8GB + 32GB 内存，ComfyUI v0.39.0）。

<sub>English: A Windows toolkit for running MiniMax-H3 video generation on an 8 GB VRAM GPU — Chinese web studio, long-video chaining (Motion Context), reference-image (Ref2VA) mode, 60 fps interpolation. Tested on RTX 5060 Ti 8 GB.</sub>

---

## 能做什么

| 功能 | 入口 | 说明 |
| --- | --- | --- |
| 🎬 一键出片 | `h3-studio/start.ps1` | 中文网页表单：全局提示词 + 每段提示词 + **每段可配图**，自动分段生成、段间衔接、拼接成整片，实时进度与 ETA |
| 🖼️ 参考图出片 | `h3-studio/run-ref-shot.ps1` | 给 4 张参考图（角色脸 / 全身 / 道具 / 场景），让画面里的人、剑、场景跟图一致；内置六段式分镜提示词格式与 60fps 插帧 |
| 🎞️ 长视频制作 | `make-h3-film.ps1` | 问答式：填内容 → 自动切 9 段 × 15 秒（约 1 分 55 秒成片），用 Motion Context 做段间运动衔接 + 交叉溶解 |
| ⚙️ ComfyUI 工作流 | `workflows/*.json` | 两个改好的官方模板：`文生视频（8G显存）`（默认 4 步加速）、`多段图生视频（全局+分段提示词）` |
| 🎨 后期工具 | `h3-studio/h3_post.py` | 提亮 / 锐化 / 运动补偿插帧到 60fps（命令行） |

**实测速度**（RTX 5060 Ti 8GB，ComfyUI 便携版）：

| 任务 | 用时 |
| --- | --- |
| 5 秒 / 640×384 / 4 步（turbo） | ≈ 1.5 分钟 |
| 12 秒 / 832×480 / 20 步（高质量） | ≈ 17.5 分钟 |
| 2 段 × 5 秒拼接（≈8 秒成片） | ≈ 3 分钟 |
| 9 段 × 15 秒（≈2 分钟成片） | ≈ 30 分钟 |

---

## 目录结构

```
minimax-h3-8gb-studio/
├── install.ps1                 # 安装：拷贝脚本到 ComfyUI 目录 + 建桌面快捷方式 + 检查模型
├── launch-h3.ps1               # ComfyUI 启动器（预留 0.6GB 显存给桌面）
├── make-h3-film.ps1            # 问答式长视频制作
├── h3-make-film.ps1            # 长视频核心脚本（分段 + Motion Context 衔接 + 拼接）
├── h3-studio/                  # 一键出片网页应用
│   ├── server.py               #   本地服务（Python 标准库，无第三方依赖）
│   ├── index.html              #   中文表单前端
│   ├── start.ps1               #   双击启动（没开 ComfyUI 会自动处理）
│   ├── run-ref-shot.ps1        #   参考图出片入口
│   ├── h3_ref_run.py           #   参考图出片核心（Ref2VA）
│   └── h3_post.py              #   提亮 / 锐化 / 插帧
├── workflows/                  # ComfyUI 工作流（拖进网页即可用）
├── custom_nodes/comfyui-h3-segment-prompt/   # 自建小节点：全局+分段提示词
├── prompts/                    # 参考图模式的六段式提示词示例
└── docs/使用说明.md             # 详细操作手册
```

---

## 安装

### 0. 前置条件

- Windows 10/11，**8GB 显存** 显卡（实测 RTX 5060 Ti 8GB；3060 12GB 等更宽松）
- 32GB 内存（16GB 可能因权重换页显著变慢）
- 约 35GB 空闲磁盘（模型）+ 若干 GB 输出
- [ComfyUI 便携版](https://github.com/comfyanonymous/ComfyUI/releases)（Windows portable，v0.39.0 实测），默认解压到 `C:\ComfyUI_windows_portable`（装别处也行，脚本会自动识别）

### 1. 下载模型

到 Hugging Face 仓库 [Comfy-Org/MiniMax-H3_ComfyUI_repackaged](https://huggingface.co/Comfy-Org/MiniMax-H3_ComfyUI_repackaged) 下载以下文件，按表放入 ComfyUI 的 `models\` 对应子目录：

| 文件 | 放入 | 大小 |
| --- | --- | --- |
| `minimax_h3_fl2va_pruned_nvfp4.safetensors` | `models\diffusion_models\` | 10.9 GB |
| `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | `models\text_encoders\` | 14.6 GB |
| `minimax_h3_video_vae_int8_convrot.safetensors` | `models\vae\` | 2.6 GB |
| `minimax_h3_audio_vae_fp32.safetensors` | `models\vae\` | 0.6 GB |
| `minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors` | `models\loras\` | 1.8 GB |
| `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors`（参考图模式用） | `models\loras\` | 1.8 GB |

> 多数文件在仓库的 `split_files\` 下按类型分目录；用仓库页面的文件搜索框按文件名搜即可。
> - 如果提示 **401 / 要求登录**：先登录 Hugging Face 账号（部分模型仓库需要先在页面点同意条款再审阅下载）。
> - 下载速度异常或连不上：可尝试 [hf-mirror.com](https://hf-mirror.com) 镜像，或社区量化仓库 [DmitryDB/MiniMax-H3-ComfyUI-Quants](https://huggingface.co/DmitryDB/MiniMax-H3-ComfyUI-Quants)。
> - Hugging Face 的 Xet CDN 对部分网络不稳定，用浏览器直下或 `hf download` 工具比 `curl -C -` 续传更可靠。

### 2. 安装第三方节点（长视频衔接必需）

```powershell
cd C:\ComfyUI_windows_portable\ComfyUI\custom_nodes
git clone https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context
```

安装本仓库自带的 `comfyui-h3-segment-prompt` 节点由下一步的 `install.ps1` 自动完成。

### 3. 安装本工具箱

```powershell
# 在仓库目录里执行（默认装到 C:\ComfyUI_windows_portable）
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 装在别处：
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ComfyRoot "D:\ComfyUI_windows_portable"
```

脚本会：拷贝脚本到 ComfyUI 目录 → 安装自建节点 → 复制工作流 → 在桌面创建 4 个快捷方式 → 检查模型是否齐。

### 4. 开始用

双击桌面 **「MiniMax-H3 一键出片」**（推荐先玩这个）；第一次启动约 1~2 分钟，之后模型常驻。

---

## 使用要点

### 一键出片（网页表单）

- **全局提示词**：整片共用的内容（人物长相、场景、画风、光线、声音氛围），每段自动带上。
- **每段提示词**：写「在哪里 + 谁在做什么 + 镜头怎么动 + 什么声音」。
- **每段配图**（可选）：
  - 第 1 段配图 = 从这张图开始演（图生视频）；
  - 后面每段可选「接着上一段演」（一镜到底，配图则演到该图为止）或「用图另起一段」（分镜叙事）。
- 跑完自动出播放器，**同时自动复制一份到 `C:\Users\<你>\Downloads`**。

### 参考图出片（Ref2VA）

- 参考图放 `ComfyUI\input\`，默认文件名 `ref_face.png` / `ref_body.png` / `ref_sword.png` / `ref_scene.png`，换成自己的图即可（比例贴近成片比例效果最好）。
- 提示词用官方六段式（见 `prompts/` 示例）：`subject_definitions` / `summary` / `retention_analysis` / `detailed_description` / `overall_soundscape` / `non_diegetic_music`，用 `<Picture 1>~<Picture 4>` 指代参考图，对白写 `<d>[Japanese] 台词</d>`。
- **画面太暗时**：在提示词里强调「人物是画面里最亮的部分，月光形成明亮主光，皮肤曝光正常，不要压成死黑」——实测这一步能把画面里人物可见度提高一个量级。

### 长视频（>15 秒）

MiniMax-H3 单段最长 15 秒；更长要靠分段 + 衔接：

- `make-h3-film.ps1` 全自动（推荐）；`h3-make-film.ps1` 可精细控制参数。
- 段间用 [ComfyUI-H3-Motion-Context](https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context) 的运动上下文衔接（`context_length` 只能取 5/22/39/56，56 帧 ≈ 2.33 秒；`audio_context_length` 取 24 的倍数）。
- 实测量化效果：带衔接的接缝 PSNR ≈ 25.8dB，无衔接 ≈ 12.3dB。

---

## 技术笔记（踩过的坑）

- **帧数公式**：`17n + 5`（5、22、39、56、…、294、311…），12 秒 = 294 帧 = 12.25 秒；单段最长 15 秒（362 帧）。官方模板里是个 `max(5, round(a*24)) + (5 - ...% 17) % 17` 的表达式节点。
- **8GB 显存参数建议**：预览 480×288 / 4 步 + turbo LoRA；日常 640×384 / 4~12 步；高质量 832×480 / 20 步。启动参数加 `--reserve-vram 0.6` 给桌面留显存。
- **参考图节点 API 写法**（ComfyUI 开发者注意）：`MiniMaxH3ReferenceToVideo` 的 `ref_images` 是 autogrow 输入，API 格式里要写成**扁平键**：`"ref_images.ref_image_0": ["节点id", 0]`。
- **参考图模式不需要专用底模**：官方模板用 `minimax_h3_ref2va_*`，但实测 `fl2va_pruned_nvfp4` + `ref2v_turbo_4step` LoRA 就能工作（后者元数据里写的 base 本来就是 fl2va）。用纯色参考图做过对照实验：红图→输出平均色 RGB(232,28,34)，蓝图→(47,24,247)，参考图确实在驱动生成。
- **60fps 是插出来的**：H3 原生 24fps。内置的 `minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1` 是运动补偿插帧（实测 731 帧 0 重复），快动作处可能有轻微果冻感，介意就用原生 24fps。
- **Motion Context 的一个细节**：开启了衔接的段会丢弃 first_frame 锚点（钉住的头占了那个位置），但保留 last_frame 锚点。
- **PowerShell 脚本编码**：本仓库 `.ps1` 一律 UTF-8 **带 BOM**，否则 PowerShell 5.1 读中文会乱码报语法错。
- **ffmpeg 拼接**：concat 列表文件不能带 BOM，用 `[IO.File]::WriteAllLines(..., UTF8Encoding($false))`。

---

## 常见问题

**Q: 提示显存不足 / 跑到一半很卡？**
把画质调低、每段时长调短；关掉游戏和浏览器标签页。8GB 显存下 640×384 是性价比甜点。

**Q: 网页打不开？**
再双击一次「MiniMax-H3 一键出片」，它会自己把服务拉起来；ComfyUI 没开也会自动拉起。

**Q: 成片在哪？**
`C:\Users\<你>\Downloads`（自动复制），原始文件在 `ComfyUI\output\h3_studio\`（或 `h3_ref\`）。

**Q: 模型下载提示 401 / 卡住？**
换 hf-mirror.com 镜像或走代理；Hugging Face 的 Xet CDN 对部分网络不稳定，续传下载容易卡死，建议断点重试或换镜像。

**Q: 能商用吗？**
脚本部分 MIT，随便用。模型权重和生成内容请遵循 [MiniMax-H3](https://huggingface.co/MiniMaxAI/MiniMax-H3) 的许可条款。

---

## 第三方组件与致谢

- [MiniMax-H3](https://huggingface.co/MiniMaxAI/MiniMax-H3) —— 模型本体（MiniMax）
- [Comfy-Org/MiniMax-H3_ComfyUI_repackaged](https://huggingface.co/Comfy-Org/MiniMax-H3_ComfyUI_repackaged) —— ComfyUI 适配的量化权重
- [ComfyUI](https://github.com/comfyanonymous/ComfyUI) —— 推理框架（GPL-3.0）
- [NikoDemon80/ComfyUI-H3-Motion-Context](https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context) —— 段间运动/音频衔接节点
- `workflows/` 下的 JSON 改编自 ComfyUI 官方 H3 模板（Apache-2.0，Comfy Org）

## License

[MIT](LICENSE)（指本仓库的脚本与文档；`workflows/` 中的工作流改编自 ComfyUI 官方模板，遵循其 Apache-2.0 许可）
