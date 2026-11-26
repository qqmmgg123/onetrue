# -*- coding: utf-8 -*-
"""生成软著「程序鉴别材料」源码文本：前 30 页 + 后 30 页（默认每页 50 行）。"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"
OUT_DIR = Path(__file__).resolve().parent
SOFTWARE = "醍醐"
VERSION = "V1.0"
LINES_PER_PAGE = 50
PAGES_EACH = 30  # 前/后各 30 页

# 跳过易含敏感配置或生成物的文件（可按需调整）
SKIP_NAME_PARTS = (
    ".g.dart",
    ".freezed.dart",
    ".mocks.dart",
)


def should_skip(path: Path) -> bool:
    name = path.name
    return any(s in name for s in SKIP_NAME_PARTS)


def collect_files() -> list[Path]:
    files = sorted(LIB.rglob("*.dart"), key=lambda p: str(p).replace("\\", "/").lower())
    return [p for p in files if p.is_file() and not should_skip(p)]


def redact(line: str) -> str:
    """简单脱敏：避免把疑似密钥字面量打进交存材料。"""
    if re.search(r"(api[_-]?key|secret|password|token)\s*[:=]", line, re.I):
        if "fromEnvironment" in line or "String.fromEnvironment" in line:
            return line
        return re.sub(r"(['\"])([^'\"]{8,})\1", r"\1***REDACTED***\1", line)
    return line


def build_corpus(files: list[Path]) -> list[str]:
    lines: list[str] = []
    for f in files:
        rel = f.relative_to(ROOT).as_posix()
        lines.append(f"// ===== FILE: {rel} =====")
        text = f.read_text(encoding="utf-8", errors="replace")
        for raw in text.splitlines():
            lines.append(redact(raw.rstrip("\n")))
        if not lines or lines[-1] != "":
            lines.append("")
    return lines


def page_header(page_no: int, total: int) -> str:
    return f"{SOFTWARE} {VERSION} 源程序  第 {page_no} 页 / 共 {total} 页"


def render_pages(chunk: list[str], start_page: int, total_pages: int) -> list[str]:
    out: list[str] = []
    page = start_page
    i = 0
    while i < len(chunk):
        out.append(page_header(page, total_pages))
        out.append("-" * 72)
        block = chunk[i : i + LINES_PER_PAGE]
        # 不足一页也保持至少展示，并用空行补到观感完整（交存习惯）
        while len(block) < LINES_PER_PAGE:
            block.append("")
        out.extend(block)
        out.append("")
        out.append("")
        i += LINES_PER_PAGE
        page += 1
    return out


def main() -> None:
    files = collect_files()
    if not files:
        raise SystemExit(f"未找到 dart 源码: {LIB}")

    corpus = build_corpus(files)
    need = LINES_PER_PAGE * PAGES_EACH
    total_pages = PAGES_EACH * 2

    if len(corpus) <= need * 2:
        # 源码较短：全文分页
        pages = []
        page = 1
        i = 0
        # 重新计算总页数
        total_pages = max(1, (len(corpus) + LINES_PER_PAGE - 1) // LINES_PER_PAGE)
        while i < len(corpus):
            pages.extend(
                render_pages(corpus[i : i + LINES_PER_PAGE], page, total_pages)[
                    : LINES_PER_PAGE + 4
                ]
            )
            # 上面 render 会补空行，直接手写更清晰
            i += LINES_PER_PAGE
            page += 1
        # 简化：短源码走统一切片逻辑
        front = corpus
        back: list[str] = []
        mode = "全文"
    else:
        front = corpus[:need]
        back = corpus[-need:]
        mode = f"前{PAGES_EACH}页+后{PAGES_EACH}页"

    out_lines: list[str] = [
        f"{SOFTWARE} {VERSION} 程序鉴别材料（一般交存）",
        f"交存方式：{mode}",
        f"每页行数：{LINES_PER_PAGE}",
        f"源文件数：{len(files)}",
        f"源码总行数（含文件头标记）：{len(corpus)}",
        "",
        "=" * 72,
        "【前部连续页】" if back else "【全文】",
        "=" * 72,
        "",
    ]

    # 前部
    page_no = 1
    i = 0
    front_pages = PAGES_EACH if back else max(1, (len(front) + LINES_PER_PAGE - 1) // LINES_PER_PAGE)
    total_pages = front_pages + (PAGES_EACH if back else 0)
    while i < len(front):
        out_lines.append(page_header(page_no, total_pages))
        out_lines.append("-" * 72)
        block = front[i : i + LINES_PER_PAGE]
        while len(block) < LINES_PER_PAGE:
            block.append("")
        out_lines.extend(block)
        out_lines.append("")
        i += LINES_PER_PAGE
        page_no += 1
        if back and page_no > PAGES_EACH:
            break

    if back:
        out_lines.append("")
        out_lines.append("=" * 72)
        out_lines.append("【后部连续页】")
        out_lines.append("=" * 72)
        out_lines.append("")
        i = 0
        while i < len(back):
            out_lines.append(page_header(page_no, total_pages))
            out_lines.append("-" * 72)
            block = back[i : i + LINES_PER_PAGE]
            while len(block) < LINES_PER_PAGE:
                block.append("")
            out_lines.extend(block)
            out_lines.append("")
            i += LINES_PER_PAGE
            page_no += 1

    out_txt = OUT_DIR / f"{SOFTWARE}_{VERSION}_程序鉴别材料.txt"
    out_txt.write_text("\n".join(out_lines), encoding="utf-8")

    # 同时给出文件清单，便于核对
    list_path = OUT_DIR / f"{SOFTWARE}_{VERSION}_源文件清单.txt"
    list_path.write_text(
        "\n".join(str(p.relative_to(ROOT).as_posix()) for p in files) + "\n",
        encoding="utf-8",
    )

    print(f"wrote {out_txt}")
    print(f"wrote {list_path}")
    print(f"files={len(files)} corpus_lines={len(corpus)} mode={mode}")


if __name__ == "__main__":
    main()
