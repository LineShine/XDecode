#!/usr/bin/env python3

#
# 解析xlog日志：
# python3 xlog_crypt_log.py halame_20250807_1.xlog 1.log
#

import sys
import os
import glob
import zlib
import struct
import traceback

from cryptography.hazmat.primitives.asymmetric import ec


MAGIC_NO_COMPRESS_START = 0x03
MAGIC_NO_COMPRESS_START1 = 0x06
MAGIC_NO_COMPRESS_NO_CRYPT_START = 0x08
MAGIC_COMPRESS_START = 0x04
MAGIC_COMPRESS_START1 = 0x05
MAGIC_COMPRESS_START2 = 0x07
MAGIC_COMPRESS_NO_CRYPT_START = 0x09

MAGIC_END = 0x00

lastseq = 0

PRIV_KEY = "e85cbab83d34ebed37ca6e06f9dfbaaf58b5888f7cd54302f9525f9ecd0d84e9"
PUB_KEY = "26c3be39315683ad749e43ae6f2a104ee46888f78496f6fad92f8fdb6ab2bee2f22c5612e130a3efd8bad8aea75b8a1dd660946e437a35ccd88110d8ff328cb2"

def tea_decipher(v, k):
    op = 0xffffffff
    v0, v1 = struct.unpack('<2I', v[0:8])
    k1, k2, k3, k4 = struct.unpack('<4I', k[0:16])
    delta = 0x9E3779B9
    s = (delta << 4) & op
    for _ in range(16):
        v1 = (v1 - (((v0<<4) + k3) ^ (v0 + s) ^ ((v0>>5) + k4))) & op
        v0 = (v0 - (((v1<<4) + k1) ^ (v1 + s) ^ ((v1>>5) + k2))) & op
        s = (s - delta) & op
    return struct.pack('<2I', v0, v1)


def tea_decrypt(v, k):
    num = len(v) // 8 * 8
    ret = bytearray()
    for i in range(0, num, 8):
        ret.extend(tea_decipher(v[i:i+8], k))

    ret.extend(v[num:])
    return bytes(ret)


def derive_tea_key(client_public_key):
    if len(client_public_key) != 64:
        raise ValueError("XLog client public key must be 64 bytes")

    server_private_key = ec.derive_private_key(
        int(PRIV_KEY, 16),
        ec.SECP256K1(),
    )
    client_public_numbers = ec.EllipticCurvePublicNumbers(
        int.from_bytes(client_public_key[:32], "big"),
        int.from_bytes(client_public_key[32:], "big"),
        ec.SECP256K1(),
    )
    client_key = client_public_numbers.public_key()
    return server_private_key.exchange(ec.ECDH(), client_key)


def validate_key_pair():
    public_numbers = ec.derive_private_key(
        int(PRIV_KEY, 16),
        ec.SECP256K1(),
    ).public_key().public_numbers()
    derived_public_key = (
        public_numbers.x.to_bytes(32, "big")
        + public_numbers.y.to_bytes(32, "big")
    ).hex()
    if derived_public_key.lower() != PUB_KEY.lower():
        raise ValueError("PRIV_KEY and PUB_KEY do not belong to the same key pair")


def IsGoodLogBuffer(_buffer, _offset, count):

    if _offset == len(_buffer): return (True, '')

    magic_start = _buffer[_offset] 
    if MAGIC_NO_COMPRESS_START==magic_start or MAGIC_COMPRESS_START==magic_start or MAGIC_COMPRESS_START1==magic_start:
        crypt_key_len = 4
    elif MAGIC_COMPRESS_START2==magic_start or MAGIC_NO_COMPRESS_START1==magic_start or MAGIC_NO_COMPRESS_NO_CRYPT_START==magic_start or MAGIC_COMPRESS_NO_CRYPT_START==magic_start:
        crypt_key_len = 64
    else:
        return (False, '_buffer[%d]:%d != MAGIC_NUM_START'%(_offset, _buffer[_offset]))

    headerLen = 1 + 2 + 1 + 1 + 4 + crypt_key_len

    if _offset + headerLen + 1 + 1 > len(_buffer): return (False, 'offset:%d > len(buffer):%d'%(_offset, len(_buffer)))
    length = struct.unpack_from("<I", _buffer, _offset+headerLen-4-crypt_key_len)[0]
    if _offset + headerLen + length + 1 > len(_buffer): return (False, 'log length:%d, end pos %d > len(buffer):%d'%(length, _offset + headerLen + length + 1, len(_buffer)))
    if MAGIC_END!=_buffer[_offset + headerLen + length]: return (False, 'log length:%d, buffer[%d]:%d != MAGIC_END'%(length, _offset + headerLen + length, _buffer[_offset + headerLen + length]))


    if (1>=count): return (True, '')
    else: return IsGoodLogBuffer(_buffer, _offset+headerLen+length+1, count-1)
        
    
def GetLogStartPos(_buffer, _count):
    offset = 0
    while True:
        if offset >= len(_buffer): break
        
        if MAGIC_NO_COMPRESS_START==_buffer[offset] or MAGIC_NO_COMPRESS_START1==_buffer[offset] or MAGIC_COMPRESS_START==_buffer[offset] or MAGIC_COMPRESS_START1==_buffer[offset] or MAGIC_COMPRESS_START2==_buffer[offset] or MAGIC_COMPRESS_NO_CRYPT_START==_buffer[offset] or MAGIC_NO_COMPRESS_NO_CRYPT_START==_buffer[offset]:
            if IsGoodLogBuffer(_buffer, offset, _count)[0]: return offset
        offset+=1
        
    return -1    
    
def DecodeBuffer(_buffer, _offset, _outbuffer):
    
    if _offset >= len(_buffer): return -1
    # if _offset + 1 + 4 + 1 + 1 > len(_buffer): return -1
    ret = IsGoodLogBuffer(_buffer, _offset, 1)
    if not ret[0]:
        fixpos = GetLogStartPos(_buffer[_offset:], 1)
        if -1==fixpos: 
            return -1
        else:
            _outbuffer.extend(("[F]decode_log_file.py decode error len=%d, result:%s \n"%(fixpos, ret[1])).encode())
            _offset += fixpos 

    magic_start = _buffer[_offset]
    if MAGIC_NO_COMPRESS_START==magic_start or MAGIC_COMPRESS_START==magic_start or MAGIC_COMPRESS_START1==magic_start:
        crypt_key_len = 4
    elif MAGIC_COMPRESS_START2==magic_start or MAGIC_NO_COMPRESS_START1==magic_start or MAGIC_NO_COMPRESS_NO_CRYPT_START==magic_start or MAGIC_COMPRESS_NO_CRYPT_START==magic_start:
        crypt_key_len = 64
    else:
        _outbuffer.extend(('in DecodeBuffer _buffer[%d]:%d != MAGIC_NUM_START'%(_offset, magic_start)).encode())
        return -1

    headerLen = 1 + 2 + 1 + 1 + 4 + crypt_key_len
    length = struct.unpack_from("<I", _buffer, _offset+headerLen-4-crypt_key_len)[0]

    seq=struct.unpack_from("<H", _buffer, _offset+headerLen-4-crypt_key_len-2-2)[0]

    global lastseq
    if seq != 0 and seq != 1 and lastseq != 0 and seq != (lastseq+1):
        _outbuffer.extend(("[F]decode_log_file.py log seq:%d-%d is missing\n" %(lastseq+1, seq-1)).encode())

    if seq != 0:
        lastseq = seq

    tmpbuffer = bytes(_buffer[_offset+headerLen:_offset+headerLen+length])

    try:
        decompressor = zlib.decompressobj(-zlib.MAX_WBITS)

        if MAGIC_NO_COMPRESS_START1==_buffer[_offset]:
            pass
        
        elif MAGIC_COMPRESS_START2==_buffer[_offset]:
            client_public_key = bytes(
                _buffer[_offset+headerLen-crypt_key_len:_offset+headerLen]
            )
            tea_key = derive_tea_key(client_public_key)

            tmpbuffer = tea_decrypt(tmpbuffer, tea_key)
            tmpbuffer = decompressor.decompress(tmpbuffer)
        elif MAGIC_COMPRESS_START==_buffer[_offset] or MAGIC_COMPRESS_NO_CRYPT_START==_buffer[_offset]:
            tmpbuffer = decompressor.decompress(tmpbuffer)
        elif MAGIC_COMPRESS_START1==_buffer[_offset]:
            decompress_data = bytearray()
            while len(tmpbuffer) > 0:
                single_log_len = struct.unpack_from("<H", tmpbuffer, 0)[0]
                decompress_data.extend(tmpbuffer[2:single_log_len+2])
                tmpbuffer = tmpbuffer[single_log_len+2:len(tmpbuffer)]

            tmpbuffer = decompressor.decompress(bytes(decompress_data))

        else:
            pass

            # _outbuffer.extend('seq:%d, hour:%d-%d len:%d decompress:%d\n' %(seq, ord(begin_hour), ord(end_hour), length, len(tmpbuffer)))
    except Exception as e:
        traceback.print_exc()  
        _outbuffer.extend(("[F]decode_log_file.py decompress err, " + str(e) + "\n").encode())
        return _offset+headerLen+length+1

    _outbuffer.extend(tmpbuffer)
    
    return _offset+headerLen+length+1


def ParseFile(_file, _outfile):
    fp = open(_file, "rb")
    _buffer = bytearray(os.path.getsize(_file))
    fp.readinto(_buffer)
    fp.close()
    startpos = GetLogStartPos(_buffer, 2)
    if -1==startpos:
        return
    
    outbuffer = bytearray()
    
    while True:
        startpos = DecodeBuffer(_buffer, startpos, outbuffer)
        if -1==startpos: break;
    
    if 0==len(outbuffer): return
    
    fpout = open(_outfile, "wb")
    fpout.write(outbuffer)
    fpout.close()
    
def main(args):
    global lastseq

    validate_key_pair()

    if 1==len(args):
        if os.path.isdir(args[0]):
            filelist = glob.glob(args[0] + "/*.xlog")
            for filepath in filelist:
                lastseq = 0
                ParseFile(filepath, filepath+".log")
        else: ParseFile(args[0], args[0]+".log")    
    elif 2==len(args):
        ParseFile(args[0], args[1])    
    else: 
        filelist = glob.glob("*.xlog")
        for filepath in filelist:
            lastseq = 0
            ParseFile(filepath, filepath+".log")

if __name__ == "__main__":
    main(sys.argv[1:])
