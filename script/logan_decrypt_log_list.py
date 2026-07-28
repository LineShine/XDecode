#!/usr/bin/env python
#coding=utf8

import gzip
import os
import threading
from io import BytesIO
import struct

# pip install pycryptodome
# 需要../site-packages下的crypto文件夹改成Crypto
from Crypto.Cipher import AES
from datetime import datetime


def logan_parse(infile, dst, key, iv):
    print(f"current_thread={threading.current_thread().name},infile: {infile}")
    start_time = datetime.now()
    dst = open(dst, 'w+')
    with open(infile, mode='rb') as file:
        # 读取1个字节
        while file.read(1) == b'\x01':
            try:
                # 读取四个字节, 转成int(大端)
                bts = file.read(4)
                # print("four bytes: ", [bts])
                size = struct.unpack('>I', bts)[0]
                print(f"current_thread={threading.current_thread().name},size: {size}")
                if size <= 0 or size >= 10000000:
                    continue
                # 读取加密内容
                encrypted_content = file.read(size)
                # print("encrypted_content: ", [encrypted_content])
                # des 解密
                aes_decrypted = AES.new(key, AES.MODE_CBC, iv)
                decrypted = aes_decrypted.decrypt(encrypted_content)
                # print("decrypted_content: ", [decrypted])

                # 读取压缩内容
                compressed_content = decrypted

                # 获取最后一个字节
                last_byte = compressed_content[-1].to_bytes(length=1, byteorder='big', signed=True)
                padding_length = struct.unpack('>b', last_byte)[0]
                # print("padding_len: ", padding_length)

                # 截取padding之前字节
                compressed_content = compressed_content[0:-padding_length]
                # print ("compressed_content: ", [compressed_content])

                # 解压
                temp_io = BytesIO(compressed_content)
                un_gzip_io = gzip.GzipFile(mode='rb', fileobj=temp_io)

                decompressed = un_gzip_io.read()

                # 写入文件
                # print(decompressed)
                dst.write(decompressed.decode())

                # 最后读一个尾巴
                tail = file.read(1)
            except Exception as e:
                print(f"current_thread={threading.current_thread().name},e: {e}")
                continue
    end_time = datetime.now()
    during_time = end_time - start_time
    print(f"current_thread={threading.current_thread().name},during_time: {during_time}")

# 获取文件列表
# recursive：是否递归目录
def read_dir(dir_path, recursive=True):
    if dir_path[-1] == '/' or dir_path[-1] == '\\':
        dir_path = dir_path[0:-2]
    all_files = []
    if os.path.isdir(dir_path):
        file_list = os.listdir(dir_path)
        for f in file_list:
            f = dir_path + '/' + f
            if os.path.isdir(f):
                # 是否递归
                if recursive:
                    sub_files = read_dir(f)
                    all_files = sub_files + all_files  # 合并当前目录与子目录的所有文件路径
                else:
                    all_files.append(f)
            else:
                all_files.append(f)
        return all_files
    else:
        return 'Error,not a dir'

if __name__ == "__main__":
    key = "0123456789067890".encode('utf-8')
    iv = "0123456789067890".encode('utf-8')
    out_end = "_output"
    out_suffix = ".txt"

    # logan_dir = r"D:\Logan"
    logan_dir = r"/Users/lingxiang/Downloads/2024-04-17"
    tk = []
    start_time = datetime.now()
    for file in read_dir(logan_dir):
        input_path = file
        output_path = input_path + out_end + out_suffix
        #
        if file.find(out_end) >= 0:
            print(file)
            # 删除，测试用
            os.remove(file)
            continue
        if os.path.exists(output_path):
            continue

        # logan_parse(input_path, output_path, key, iv)

        t = threading.Thread(target=logan_parse, name=file, args=(input_path, output_path, key, iv,))
        t.start()
        tk.append(t)
    for t in tk:
        t.join()
    end_time = datetime.now()
    during_time = end_time - start_time
    print(f"during_time: {during_time}")

