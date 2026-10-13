"""H3 Segment Prompt — per-segment prompts for MiniMax H3 chains.

Chains built with ComfyUI-H3-Motion-Context run one clip per queue, and the
chain buttons advance the Motion Context Load Latent index between runs.
This node turns one global prompt plus a list of per-segment prompts into the
single prompt string the H3 Image-to-Video node wants, picking the segment
that matches the clip currently being generated.

Nothing here touches ComfyUI or the Motion Context pack: the only wiring it
needs is the Load Latent node's `clip_index` output.
"""

import logging
import re

LOGGER = logging.getLogger("h3_segment_prompt")

# A separator line is three or more dashes / em-dashes / equals signs and
# nothing else. Anything else stays part of the segment text.
SEPARATOR = re.compile(r"(?m)^[ \t]*[-—–=]{3,}[ \t]*$")


def split_segments(text):
    """Split the multiline widget into stripped, non-empty segment prompts."""
    blocks = SEPARATOR.split(str(text or ""))
    return [block.strip() for block in blocks if block.strip()]


class H3SegmentPrompt:
    """Pick one prompt per chain segment; prefix the shared global prompt."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "clip_index": ("INT", {
                    "default": 0, "min": 0, "max": 9999, "step": 1,
                    "tooltip": "接 H3 Motion Context Load Latent 的 clip_index 输出。"
                               "第一段是 0，之后每点一次 Approve / Chain 自动 +1，"
                               "本节点据此选择第几段提示词。",
                }),
                "global_prompt": ("STRING", {
                    "default": "", "multiline": True, "dynamicPrompts": False,
                    "tooltip": "全局提示词：每一段都会带上，拼在该段提示词的前面。"
                               "适合写风格、画质、镜头与声音等整条片子共用的内容。",
                }),
                "segment_prompts": ("STRING", {
                    "default": "", "multiline": True, "dynamicPrompts": False,
                    "tooltip": "分段提示词：一段一节，节与节之间用单独一行 --- 分隔。"
                               "第 1 节给第 1 段，第 2 节给第 2 段……段数超过节数时重复最后一节。",
                }),
            },
        }

    RETURN_TYPES = ("STRING", "INT", "STRING")
    RETURN_NAMES = ("prompt", "segment_number", "segment_text")
    FUNCTION = "build"
    CATEGORY = "conditioning/minimax"
    DESCRIPTION = ("按 clip_index 选取当前段的提示词，与全局提示词拼成最终 prompt。"
                   "段与段之间用一行 --- 分隔；段数不够时重复最后一节。")

    def build(self, clip_index, global_prompt, segment_prompts):
        index = max(0, int(clip_index))
        number = index + 1
        segments = split_segments(segment_prompts)
        if segments:
            if number > len(segments):
                LOGGER.info(
                    "h3_segment_prompt: 第 %d 段超出已写的 %d 节，重复最后一节",
                    number, len(segments))
            text = segments[min(number, len(segments)) - 1]
        else:
            text = ""
        global_text = str(global_prompt or "").strip()
        if global_text and text:
            prompt = "%s\n\n%s" % (global_text, text)
        else:
            prompt = global_text or text
        if not prompt:
            LOGGER.warning(
                "h3_segment_prompt: 第 %d 段的提示词是空的（全局和分段都没写）", number)
        return (prompt, number, text)


NODE_CLASS_MAPPINGS = {
    "H3SegmentPrompt": H3SegmentPrompt,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "H3SegmentPrompt": "H3 Segment Prompt (全局+分段提示词)",
}
