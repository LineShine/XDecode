#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Decrypt and decompress an iOS Logan log file."""

import argparse
import struct
import sys
import zlib
from pathlib import Path
from typing import BinaryIO, Optional, Tuple

try:
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import unpad
except ImportError as error:
    raise SystemExit(
        "缺少 PyCryptodome，请执行：python3 -m pip install pycryptodome"
    ) from error


PROTOCOL_HEAD = b"\x01"
PROTOCOL_TAIL = b"\x00"
SIZE_BYTES = 4
AES_KEY_SIZE = 16


def parse_secret(value: Optional[str], name: str) -> bytes:
    """Return a 16-byte secret, defaulting omitted values to zero bytes."""
    if value is None:
        return bytes(AES_KEY_SIZE)

    secret = value.encode("utf-8")
    if len(secret) != AES_KEY_SIZE:
        raise ValueError(
            f"{name} 必须是 {AES_KEY_SIZE} 字节，当前 UTF-8 编码后为 {len(secret)} 字节"
        )
    return secret


def read_exact(file: BinaryIO, size: int) -> bytes:
    """Read up to size bytes, allowing the caller to report truncated frames."""
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = file.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def decrypt_frame(ciphertext: bytes, key: bytes, iv: bytes) -> Tuple[bytes, str]:
    if not ciphertext:
        raise ValueError("加密内容为空")
    if len(ciphertext) % AES.block_size != 0:
        raise ValueError(
            f"加密内容长度 {len(ciphertext)} 不是 AES 块大小 {AES.block_size} 的倍数"
        )

    decrypted = AES.new(key, AES.MODE_CBC, iv).decrypt(ciphertext)

    try:
        compressed = unpad(decrypted, AES.block_size, style="pkcs7")
        padding_mode = "PKCS#7"
    except ValueError:
        # Older Logan parsers also accept CBC data without protocol-level padding.
        compressed = decrypted
        padding_mode = "legacy/no-padding"

    try:
        # Logan writes a GZIP stream. zlib stops at its end and tolerates legacy
        # trailing bytes, which matches the official Java parser's fallback.
        plaintext = zlib.decompress(compressed, 16 + zlib.MAX_WBITS)
    except zlib.error as error:
        raise ValueError(
            "解密结果不是有效的 GZIP 数据；请检查 key/IV，或确认日志文件未损坏"
        ) from error

    return plaintext, padding_mode


def logan_parse(
    input_path: Path,
    output_path: Path,
    key: bytes,
    iv: bytes,
    debug: bool = False,
) -> Tuple[int, int, int]:
    frame_count = 0
    success_count = 0
    failure_count = 0
    warning_count = 0

    with input_path.open("rb") as source, output_path.open("wb") as destination:
        while True:
            frame_offset = source.tell()
            marker = source.read(1)
            if not marker:
                break

            if marker != PROTOCOL_HEAD:
                print(
                    f"错误：偏移 {frame_offset} 的协议头应为 0x01，实际为 0x{marker.hex()}",
                    file=sys.stderr,
                )
                failure_count += 1
                break

            size_data = read_exact(source, SIZE_BYTES)
            if len(size_data) != SIZE_BYTES:
                print(
                    f"错误：第 {frame_count + 1} 帧长度字段不完整",
                    file=sys.stderr,
                )
                failure_count += 1
                break

            frame_count += 1
            encrypted_size = struct.unpack(">I", size_data)[0]
            encrypted_content = read_exact(source, encrypted_size)
            if len(encrypted_content) != encrypted_size:
                print(
                    f"错误：第 {frame_count} 帧声明 {encrypted_size} 字节，"
                    f"实际只读取到 {len(encrypted_content)} 字节",
                    file=sys.stderr,
                )
                failure_count += 1
                break

            tail = source.read(1)
            if tail != PROTOCOL_TAIL:
                warning_count += 1
                if tail:
                    print(
                        f"警告：第 {frame_count} 帧尾标记应为 0x00，实际为 0x{tail.hex()}",
                        file=sys.stderr,
                    )
                    source.seek(-1, 1)
                else:
                    print(
                        f"警告：第 {frame_count} 帧缺少尾标记，文件可能在 flush 前被复制",
                        file=sys.stderr,
                    )

            try:
                plaintext, padding_mode = decrypt_frame(
                    encrypted_content, key, iv
                )
            except ValueError as error:
                failure_count += 1
                print(
                    f"错误：第 {frame_count} 帧解密失败：{error}",
                    file=sys.stderr,
                )
                continue

            destination.write(plaintext)
            success_count += 1
            if debug:
                print(
                    f"第 {frame_count} 帧：密文 {encrypted_size} 字节，"
                    f"明文 {len(plaintext)} 字节，填充 {padding_mode}"
                )

    return success_count, failure_count, warning_count


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="解密并解压 iOS Logan 日志")
    parser.add_argument("-i", "--input", required=True, help="输入日志文件路径")
    parser.add_argument(
        "-o",
        "--output",
        help="输出文件路径，默认在输入路径后添加 _decompressed.txt",
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
    parser.add_argument("--debug", action="store_true", help="输出每帧解析信息")
    return parser


def main() -> int:
    parser = build_argument_parser()
    options = parser.parse_args()

    input_path = Path(options.input).expanduser()
    output_path = (
        Path(options.output).expanduser()
        if options.output
        else Path(f"{input_path}_decompressed.txt")
    )

    if not input_path.is_file():
        parser.error(f"输入文件不存在：{input_path}")

    try:
        if input_path.resolve() == output_path.resolve():
            parser.error("输出文件不能与输入文件相同")
        key = parse_secret(options.key, "AES key")
        iv = parse_secret(options.iv, "AES IV")
    except ValueError as error:
        parser.error(str(error))

    try:
        success_count, failure_count, warning_count = logan_parse(
            input_path, output_path, key, iv, options.debug
        )
    except OSError as error:
        print(f"文件处理失败：{error}", file=sys.stderr)
        return 1

    print(
        f"解析完成：成功 {success_count} 帧，失败 {failure_count} 帧，"
        f"警告 {warning_count} 个，输出：{output_path}"
    )
    return 0 if success_count > 0 and failure_count == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
