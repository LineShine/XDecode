#
# 解析mx日志：
# python3 decode_mx.py 2025-12-17_log.mx
#

import os
import struct
import sys
import argparse
from datetime import datetime

# --- FlatBuffers 基础常量 ---
_SIZE_OF_UINT32 = 4
_SIZE_OF_UINT64 = 8
_SIZE_OF_INT8 = 1
_SIZE_OF_INT32 = 4
_SIZE_OF_UINT16 = 2

class LogSerialize:
    """
    手动解析 FlatBuffers LogSerialize 对象。
    逻辑对应 Dart 脚本中的 LogSerialize 及 Reader 实现。
    """
    def __init__(self, buffer: bytes):
        self._buffer = buffer

        # [核心逻辑] FlatBuffers Buffer 的起始通常是一个指向 Root Table 的偏移量 (UOffset)
        if len(buffer) < 4:
            raise ValueError(f"Buffer too short: {len(buffer)}")

        # 1. 读取 Root Table 的偏移量
        root_offset = struct.unpack('<I', buffer[0:_SIZE_OF_UINT32])[0]

        # 2. 计算 Root Table 的绝对起始位置
        self._table_start = root_offset

        # 安全检查
        if self._table_start >= len(buffer):
            raise ValueError(f"Invalid Root Offset: {root_offset}, Buffer Len: {len(buffer)}")

        # 3. 获取 VTable 的位置
        # Table 的前 4 个字节是 VTable 的相对偏移量 (soffset_t, int32)
        # VTable 绝对位置 = Table起始位置 - VTable相对偏移量
        vtable_soffset_bytes = self._buffer[self._table_start : self._table_start + _SIZE_OF_INT32]
        vtable_soffset = struct.unpack('<i', vtable_soffset_bytes)[0]
        self._vtable_start = self._table_start - vtable_soffset

        # 4. 读取 VTable 大小 (uint16)
        self._vtable_size = struct.unpack('<H', self._buffer[self._vtable_start : self._vtable_start + 2])[0]

    def _get_field_offset_from_vtable(self, vtable_offset: int) -> int:
        """
        根据 VTable 偏移量查找字段的偏移量。
        如果 vtable_offset 超过了 vtable 的大小，说明该字段在写入时不存在（使用默认值）。
        """
        if vtable_offset >= self._vtable_size:
            return 0
        # VTable 结构: [vtable_size(2)][object_size(2)][offset(2)]...[offset(2)]
        # 传入的 vtable_offset 是相对于 VTable 起始位置的字节偏移
        offset_in_vtable = self._vtable_start + vtable_offset
        return struct.unpack('<H', self._buffer[offset_in_vtable : offset_in_vtable + 2])[0]

    def _read_scalar(self, vtable_offset: int, size: int, fmt: str, default_val):
        """读取标量字段"""
        field_offset = self._get_field_offset_from_vtable(vtable_offset)
        if field_offset == 0:
            return default_val

        # 数据绝对位置 = Table起始 + 字段相对偏移
        data_loc = self._table_start + field_offset
        return struct.unpack(fmt, self._buffer[data_loc : data_loc + size])[0]

    def _read_string(self, vtable_offset: int) -> str:
        """读取字符串字段"""
        field_offset = self._get_field_offset_from_vtable(vtable_offset)
        if field_offset == 0:
            return ""

        # 字符串字段存储的是字符串对象的相对偏移 (UOffset)
        offset_loc = self._table_start + field_offset
        relative_offset = struct.unpack('<I', self._buffer[offset_loc : offset_loc + 4])[0]

        # 跳转到字符串对象: 长度(4) + 数据
        str_start = offset_loc + relative_offset
        str_len = struct.unpack('<I', self._buffer[str_start : str_start + 4])[0]

        str_data_start = str_start + 4
        str_bytes = self._buffer[str_data_start : str_data_start + str_len]

        try:
            return str_bytes.decode('utf-8')
        except UnicodeDecodeError:
            # 回退方案，避免崩溃
            return str_bytes.decode('latin-1', errors='replace')

    # --- 字段映射 (参考 Dart 代码) ---
    @property
    def name(self) -> str: return self._read_string(4)
    @property
    def tag(self) -> str: return self._read_string(6)
    @property
    def msg(self) -> str: return self._read_string(8)
    @property
    def level(self) -> int: return self._read_scalar(10, _SIZE_OF_INT8, '<b', 0)
    @property
    def threadId(self) -> int: return self._read_scalar(12, _SIZE_OF_INT32, '<i', 0)
    @property
    def isMainThread(self) -> int: return self._read_scalar(14, _SIZE_OF_INT8, '<B', 0)
    @property
    def timestamp(self) -> int: return self._read_scalar(16, _SIZE_OF_UINT64, '<Q', 0)

def _level_str(level: int) -> str:
    mapping = {0: 'D', 1: 'I', 2: 'W', 3: 'E', 4: 'F'}
    return mapping.get(level, 'D')

def decoder(log_path: str):
    if not os.path.exists(log_path):
        print(f"[ERROR] 文件不存在: {log_path}")
        return

    # 输出文件名为原文件名替换扩展名为 .log
    output_path = os.path.splitext(log_path)[0] + '.log'
    print(f"正在解码: {log_path}")
    print(f"输出路径: {output_path}")

    with open(log_path, 'rb') as f:
        in_bytes = f.read()

    file_len = len(in_bytes)
    if file_len < 4:
        print("[ERROR] 文件内容过短，无法解析。")
        return

    # 读取文件头部的 Total Size
    total_size = struct.unpack('<I', in_bytes[0:4])[0]

    # 偏移量起始位置 (Total Size 占了 4 字节)
    begin = 4
    count = 0

    try:
        with open(output_path, 'w', encoding='utf-8') as sink:
            while begin < file_len and begin <= total_size:
                # 1. 读取当前 Log Item 的大小
                if begin + 4 > file_len:
                    break

                item_size = struct.unpack('<I', in_bytes[begin : begin+4])[0]
                start = begin + 4

                if start + item_size > file_len:
                    print(f"[WARN] 数据块大小越界，停止解析。Offset: {begin}")
                    break

                # 2. 获取 Log Item 的二进制数据
                buffer = in_bytes[start : start + item_size]

                try:
                    # 3. 解析 FlatBuffer
                    log = LogSerialize(buffer)

                    # 4. 格式化输出
                    # Dart 传入的是微秒，需转为秒
                    ts_seconds = log.timestamp / 1_000_000.0

                    if ts_seconds > 0:
                        dt = datetime.fromtimestamp(ts_seconds)
                        time_str = dt.strftime('%Y-%m-%d %H:%M:%S.%f')
                    else:
                        time_str = "1970-01-01 00:00:00.000"

                    level = _level_str(log.level)

                    # 处理 tag
                    tags = log.tag.split(',')
                    tag_str = str(tags) if log.tag else "[]"

                    # 写入一行
                    line = f"{time_str} {level} {tag_str} {log.msg}\n"
                    sink.write(line)
                    count += 1

                except Exception as e:
                    # 单条日志解析失败不影响整体
                    # print(f"[WARN] 解析单条日志失败 (Offset {begin}): {e}")
                    pass

                # 移动指针到下一条日志
                begin = begin + 4 + item_size

        print(f"解码完成！共处理 {count} 条日志。")

    except Exception as e:
        print(f"[ERROR] 写入文件时发生错误: {e}")

def main():
    parser = argparse.ArgumentParser(description="将 .mx 日志文件解码为可读的 .log 文件")
    parser.add_argument("input_file", help=".mx 日志文件的路径")

    args = parser.parse_args()

    decoder(args.input_file)

if __name__ == '__main__':
    main()