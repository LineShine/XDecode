#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Batch-decrypt iOS Logan log files with the shared single-file parser."""

import argparse
import sys
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

try:
    from logan_decrypt_log import logan_parse, parse_secret
except ImportError as error:
    raise SystemExit(
        "无法导入 logan_decrypt_log.py，请确认两个脚本位于同一目录"
    ) from error


OUTPUT_SUFFIX = "_output.txt"
DEFAULT_WORKERS = 4


@dataclass(frozen=True)
class BatchResult:
    input_path: Path
    output_path: Path
    success_frames: int = 0
    failure_frames: int = 0
    warning_count: int = 0
    skipped: bool = False
    error: Optional[str] = None

    @property
    def succeeded(self) -> bool:
        return (
            not self.skipped
            and self.error is None
            and self.success_frames > 0
            and self.failure_frames == 0
        )


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.resolve().relative_to(directory.resolve())
        return True
    except ValueError:
        return False


def is_hidden(path: Path, input_dir: Path) -> bool:
    relative_path = path.relative_to(input_dir)
    return any(part.startswith(".") for part in relative_path.parts)


def collect_input_files(
    input_dir: Path,
    pattern: str,
    recursive: bool,
    output_dir: Optional[Path],
) -> List[Path]:
    iterator = input_dir.rglob(pattern) if recursive else input_dir.glob(pattern)
    files = []

    for path in iterator:
        if (
            is_hidden(path, input_dir)
            or not path.is_file()
            or path.name.endswith(OUTPUT_SUFFIX)
        ):
            continue
        if (
            output_dir is not None
            and output_dir != input_dir
            and is_within(path, output_dir)
        ):
            continue
        files.append(path)

    return sorted(files, key=lambda path: str(path))


def make_output_path(
    input_path: Path,
    input_dir: Path,
    output_dir: Optional[Path],
) -> Path:
    if output_dir is None:
        return Path(f"{input_path}{OUTPUT_SUFFIX}")

    relative_path = input_path.relative_to(input_dir)
    return output_dir / relative_path.parent / f"{relative_path.name}{OUTPUT_SUFFIX}"


def decrypt_one(
    input_path: Path,
    output_path: Path,
    key: bytes,
    iv: bytes,
    overwrite: bool,
    debug: bool,
) -> BatchResult:
    if output_path.exists() and not overwrite:
        return BatchResult(input_path, output_path, skipped=True)

    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        success_frames, failure_frames, warning_count = logan_parse(
            input_path,
            output_path,
            key,
            iv,
            debug,
        )
    except OSError as error:
        return BatchResult(input_path, output_path, error=str(error))

    return BatchResult(
        input_path=input_path,
        output_path=output_path,
        success_frames=success_frames,
        failure_frames=failure_frames,
        warning_count=warning_count,
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="批量解密并解压 iOS Logan 日志")
    parser.add_argument("-i", "--input", required=True, help="输入日志目录")
    parser.add_argument(
        "-o",
        "--output-dir",
        help="输出目录；未提供时在每个输入文件旁生成 *_output.txt",
    )
    parser.add_argument(
        "-k",
        "--key",
        help="16 字节 AES key 文本，未提供时使用 16 个 0x00 字节",
    )
    parser.add_argument(
        "-v",
        "--iv",
        help="16 字节 AES IV 文本，未提供时使用 16 个 0x00 字节",
    )
    parser.add_argument(
        "-j",
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"最大并发数，默认 {DEFAULT_WORKERS}",
    )
    parser.add_argument(
        "--pattern",
        default="*",
        help="文件匹配模式，默认 *",
    )
    parser.add_argument(
        "--no-recursive",
        action="store_true",
        help="只处理输入目录第一层文件",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="覆盖已存在的输出文件；默认跳过",
    )
    parser.add_argument("--debug", action="store_true", help="输出每帧解析信息")
    return parser


def main() -> int:
    parser = build_argument_parser()
    options = parser.parse_args()

    input_dir = Path(options.input).expanduser().resolve()
    output_dir = (
        Path(options.output_dir).expanduser().resolve()
        if options.output_dir
        else None
    )

    if not input_dir.is_dir():
        parser.error(f"输入目录不存在：{input_dir}")
    if options.workers <= 0:
        parser.error("最大并发数必须大于 0")

    try:
        key = parse_secret(options.key, "AES key")
        iv = parse_secret(options.iv, "AES IV")
    except ValueError as error:
        parser.error(str(error))

    input_files = collect_input_files(
        input_dir,
        options.pattern,
        not options.no_recursive,
        output_dir,
    )
    if not input_files:
        print(f"未找到匹配的输入文件：{input_dir}")
        return 0

    results = []
    future_inputs: Dict[Future, Path] = {}
    with ThreadPoolExecutor(max_workers=options.workers) as executor:
        for input_path in input_files:
            output_path = make_output_path(input_path, input_dir, output_dir)
            future = executor.submit(
                decrypt_one,
                input_path,
                output_path,
                key,
                iv,
                options.overwrite,
                options.debug,
            )
            future_inputs[future] = input_path

        for future in as_completed(future_inputs):
            input_path = future_inputs[future]
            try:
                result = future.result()
            except Exception as error:
                result = BatchResult(
                    input_path,
                    make_output_path(input_path, input_dir, output_dir),
                    error=f"未预期错误：{error}",
                )
            results.append(result)

            if result.skipped:
                print(f"[跳过] {result.input_path} -> 输出已存在")
            elif result.succeeded:
                print(
                    f"[成功] {result.input_path} -> {result.output_path} "
                    f"({result.success_frames} 帧，{result.warning_count} 个警告)"
                )
            else:
                detail = result.error or (
                    f"成功 {result.success_frames} 帧，失败 {result.failure_frames} 帧"
                )
                print(f"[失败] {result.input_path}：{detail}", file=sys.stderr)

    success_files = sum(result.succeeded for result in results)
    skipped_files = sum(result.skipped for result in results)
    failed_files = len(results) - success_files - skipped_files
    success_frames = sum(result.success_frames for result in results)
    failure_frames = sum(result.failure_frames for result in results)
    warnings = sum(result.warning_count for result in results)

    print(
        "批量解析完成："
        f"文件成功 {success_files}，失败 {failed_files}，跳过 {skipped_files}；"
        f"帧成功 {success_frames}，失败 {failure_frames}，警告 {warnings}"
    )
    return 0 if failed_files == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
