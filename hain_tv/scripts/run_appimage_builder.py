#!/usr/bin/env python3
# 运行 appimage-builder 并修复其对 stripped 二进制的架构检测缺陷。
#
# 问题：appimage-builder 的 AppRunV2 在 _find_embed_archs 阶段扫描 AppDir 里的
# 可执行 ELF，依赖 has_start_symbol（读 _start 符号）判定"这是可执行文件"。
# Flutter release 构建默认 strip 二进制，.symtab 被移除，_start 只存在于该表，
# 导致 hain_tv 不被识别为 BinaryExecutable，集合为空 -> 报
# "Unable to determine the bundle architecture"。
#
# 本垫片在运行时按属性 monkeypatch，不依赖源码文本匹配，对 appimage-builder
# 各版本都有效：
#   1) elf.has_start_symbol 对任一 ELF 可执行文件返回 True；
#   2) ExecutablesScanner.scan_file 兜底：若原扫描未产出 BinaryExecutable
#      且文件是 ELF，则补一个 BinaryExecutable(arch=x86_64)；
#   3) AppRunV2Setup._find_embed_archs 兜底：集合为空时默认 x86_64。
#
# 用法（由 build_linux_appimage.sh 调用）：
#   python3 run_appimage_builder.py --recipe AppImageBuilder.yml
import sys

import appimagebuilder.utils.elf as elf
from appimagebuilder.modules.setup.apprun_2.executables import BinaryExecutable
from appimagebuilder.modules.setup.apprun_2.executables_scanner import (
    ExecutablesScanner,
)
from appimagebuilder.modules.setup.apprun_2 import apprun2

# 1) 任一 ELF 可执行文件都视为可执行（绕过 stripped 后缺失 _start 的问题）。
_original_has_magic_bytes = elf.has_magic_bytes
elf.has_start_symbol = lambda path: bool(_original_has_magic_bytes(path))


# 2) 兜底扫描：确保 ELF 可执行文件被当成 BinaryExecutable。
_orig_scan_file = ExecutablesScanner.scan_file


def _patched_scan_file(self, path):
    results = _orig_scan_file(self, path)
    if not any(isinstance(e, BinaryExecutable) for e in results):
        if _original_has_magic_bytes(path):
            try:
                arch = elf.get_arch(path)
            except Exception:
                arch = "x86_64"
            results = results + [BinaryExecutable(path, arch)]
    return results


ExecutablesScanner.scan_file = _patched_scan_file


# 3) 兜底架构检测：集合为空时默认 x86_64，避免 RuntimeError。
def _patched_find_embed_archs(self, executables):
    embed_archs = set()
    for executable in executables:
        if isinstance(executable, BinaryExecutable):
            if executable.arch:
                embed_archs.add(executable.arch)
    if not embed_archs:
        embed_archs.add("x86_64")
    return embed_archs


apprun2.AppRunV2Setup._find_embed_archs = _patched_find_embed_archs

# 调用真正的 appimage-builder 入口。
from appimagebuilder.__main__ import __main__ as _aib_main

# 把脚本参数透传给 appimage-builder（argv[0] 改为占位名）。
sys.argv = ["appimage-builder"] + sys.argv[1:]
_aib_main()
