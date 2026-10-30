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
#   4) DesktopEntryGenerator._add_appimage_version 强制写入版本号（不是跳过 ——
#      详见下方第 4 段的完整说明）。
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

# 4) 强制写入 X-AppImage-Version（**不是**跳过它 —— 2026-10-23 实测纠正）。
#
#    Gear Lever 的真实命名逻辑（上游 src/providers/AppImageProvider.py, install_file()）：
#        候选名 = desktop 条目 Name= 小写 + ".appimage"          → "heinplay.appimage"
#        若目标目录 ~/.local/share/gearlever/ 里已存在同名文件，为避免覆盖而加后缀：
#            有版本号 → "heinplay.appimage_1_4_0.appimage"
#            无版本号 → "heinplay.appimage_0.appimage"（i=0 兜底，纯属无意义退化）
#        走内置更新(update_file)时则保留旧文件名 basename，不加任何后缀。
#
#    ⇒ 结论一：**去掉版本字段并不能消除后缀**，只会把 _1_4_0 变成 _0。
#      上一轮"跳过写入版本"的改动方向是错的（实测得到 heinplay.appimage_0.appimage）。
#    ⇒ 结论二：版本字段必须保留：
#      ① 冲突时的后缀带真实版本，可辨识；
#      ② Gear Lever 安装时会把该键写进系统 desktop 文件，其更新检测依赖它。
#
#    ⇒ 结论三："所有版本都装成 heinplay.appimage" 靠的是 desktop 条目的
#      Name=HeinPlay（决定集成后的**基础名**）—— 与交付文件名无关：
#      交付名带版本（heinplay-<ver>-linux-x86_64.AppImage）照样装成
#      heinplay.appimage。后缀只在目标目录已有同名文件时才出现，那是
#      Gear Lever「不覆盖已有安装」的既定策略，无法由 AppImage 内部消除；
#      要同名覆盖升级请走覆盖式安装路径（一键安装脚本 mv -f 覆盖，
#      或 Gear Lever 内置更新的 REPLACE 分支保留旧 basename）。
import os

from appimagebuilder.modules.setup import desktop_entry_generator as _deg


def _forced_appimage_version(self, version):
    """强制写入 X-AppImage-Version，并保证只有一行、值非空。"""
    ver = str(version or "").strip()
    if not ver:
        ver = os.environ.get("APP_VERSION", "").strip() or "1.4.1"
    # 先剔除可能已有的重复键，避免出现两行 X-AppImage-Version。
    self.contents = [
        line for line in self.contents if not line.startswith("X-AppImage-Version=")
    ]
    idx = self._get_desktop_entry_header_index()
    self.contents.insert(idx + 1, "X-AppImage-Version=%s\n" % ver)


_deg.DesktopEntryGenerator._add_appimage_version = _forced_appimage_version

# 调用真正的 appimage-builder 入口。
from appimagebuilder.__main__ import __main__ as _aib_main

# 把脚本参数透传给 appimage-builder（argv[0] 改为占位名）。
sys.argv = ["appimage-builder"] + sys.argv[1:]
_aib_main()
