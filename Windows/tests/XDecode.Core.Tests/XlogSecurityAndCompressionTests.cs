using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Math;
using XDecode.Core;
using ZstdSharp;

namespace XDecode.Core.Tests;

public sealed class XlogSecurityAndCompressionTests
{
    [Fact]
    public void EncryptedFrameTriesWrongKeyBeforeMatchingKey()
    {
        var expected = Encoding.UTF8.GetBytes("encrypted xlog fixture\n");
        var fixture = EncryptedFrame(expected);
        var decoded = new XlogDecoder([
            new XlogCredentials(Scalar(3)),
            new XlogCredentials(Scalar(1))
        ]).Decode(fixture, "encrypted.xlog");
        Assert.True(decoded.IsComplete);
        Assert.Equal(expected, decoded.Data);
        Assert.Contains("成功 1 帧，失败 0 帧", decoded.Diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void EncryptedFrameWithoutKeyHasExplicitCounts()
    {
        var error = Assert.Throws<DecodeException>(() =>
            new XlogDecoder().Decode(EncryptedFrame(Encoding.UTF8.GetBytes("secret\n")), "missing.xlog"));
        Assert.Contains("成功 0 帧，失败 1 帧", error.Message, StringComparison.Ordinal);
        Assert.Contains("缺少匹配", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EncryptedFrameWithWrongKeyReportsMismatch()
    {
        var error = Assert.Throws<DecodeException>(() =>
            new XlogDecoder([new XlogCredentials(Scalar(4))])
                .Decode(EncryptedFrame(Encoding.UTF8.GetBytes("secret\n")), "wrong.xlog"));
        Assert.Contains("成功 0 帧，失败 1 帧", error.Message, StringComparison.Ordinal);
        Assert.Contains("私钥不匹配", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void MissingKeyKeepsOnlySuccessfulPlaintextFrames()
    {
        var plain = Encoding.UTF8.GetBytes("plaintext metadata\n");
        var fixture = XlogFrame(0x08, plain, ScalarBytes(0, 64), 1)
            .Concat(EncryptedFrame(Encoding.UTF8.GetBytes("encrypted payload\n"), 2)).ToArray();
        var decoded = new XlogDecoder().Decode(fixture, "partial.xlog");
        Assert.False(decoded.IsComplete);
        Assert.Equal(plain, decoded.Data);
        Assert.Contains("成功 1 帧，失败 1 帧", decoded.Diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void SyncFlushedRawDeflateFrameIsAccepted()
    {
        var expected = Encoding.UTF8.GetBytes(
            string.Concat(Enumerable.Range(0, 500).Select(index => $"sync-flush line {index}\n")));
        var compressed = SyncFlushedDeflate(expected);
        Assert.Equal(new byte[] { 0, 0, 0xff, 0xff }, compressed[^4..]);
        var decoded = new XlogDecoder().Decode(
            XlogFrame(0x09, compressed, ScalarBytes(0, 64), 1), "sync.xlog");
        Assert.Equal(expected, decoded.Data);
    }

    [Fact]
    public void TruncatedRawDeflateFrameFails()
    {
        var compressed = SyncFlushedDeflate(Encoding.UTF8.GetBytes("truncated fixture\n"));
        var truncated = compressed[..^1];
        Assert.Throws<DecodeException>(() => new XlogDecoder().Decode(
            XlogFrame(0x09, truncated, ScalarBytes(0, 64), 1), "truncated.xlog"));
    }

    [Fact]
    public void ZstandardFrameDecodes()
    {
        var expected = Encoding.UTF8.GetBytes("zstandard xlog\n");
        using var compressor = new Compressor(3);
        var compressed = compressor.Wrap(expected).ToArray();
        var decoded = new XlogDecoder().Decode(
            XlogFrame(0x0b, compressed, ScalarBytes(0, 64), 1), "zstd.xlog");
        Assert.Equal(expected, decoded.Data);
    }

    private static byte[] EncryptedFrame(byte[] plaintext, ushort sequence = 1)
    {
        var domain = SecNamedCurves.GetByName("secp256k1");
        var serverScalar = new BigInteger(1, Scalar(1));
        var clientScalar = new BigInteger(1, Scalar(2));
        var clientPublic = domain.G.Multiply(clientScalar).Normalize();
        var shared = clientPublic.Multiply(serverScalar).Normalize().GetEncoded(false);
        var teaKey = shared[1..17];
        var encrypted = TeaEncrypt(RawDeflate(plaintext), teaKey);
        return XlogFrame(0x07, encrypted, clientPublic.GetEncoded(false)[1..], sequence);
    }

    private static byte[] XlogFrame(
        byte magic, byte[] payload, byte[] publicKey, ushort sequence)
    {
        var keyLength = magic is 0x03 or 0x04 or 0x05 ? 4 : 64;
        var data = new byte[9 + keyLength + payload.Length + 1];
        data[0] = magic;
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(1), sequence);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(5), (uint)payload.Length);
        publicKey.AsSpan(0, keyLength).CopyTo(data.AsSpan(9));
        payload.CopyTo(data, 9 + keyLength);
        return data;
    }

    private static byte[] RawDeflate(byte[] data)
    {
        using var output = new MemoryStream();
        using (var stream = new DeflateStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
            stream.Write(data);
        return output.ToArray();
    }

    private static byte[] SyncFlushedDeflate(byte[] data)
    {
        using var output = new MemoryStream();
        using var stream = new DeflateStream(output, CompressionLevel.SmallestSize, leaveOpen: true);
        stream.Write(data);
        stream.Flush();
        return output.ToArray();
    }

    private static byte[] TeaEncrypt(ReadOnlySpan<byte> data, ReadOnlySpan<byte> key)
    {
        var output = data.ToArray();
        var keyWords = new uint[4];
        for (var index = 0; index < keyWords.Length; index++)
            keyWords[index] = BinaryPrimitives.ReadUInt32LittleEndian(key.Slice(index * 4, 4));
        var completeLength = data.Length / 8 * 8;
        for (var offset = 0; offset < completeLength; offset += 8)
        {
            var v0 = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(offset, 4));
            var v1 = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(offset + 4, 4));
            const uint delta = 0x9e3779b9;
            uint sum = 0;
            for (var round = 0; round < 16; round++)
            {
                sum = unchecked(sum + delta);
                v0 = unchecked(v0 + (((v1 << 4) + keyWords[0]) ^ (v1 + sum) ^ ((v1 >> 5) + keyWords[1])));
                v1 = unchecked(v1 + (((v0 << 4) + keyWords[2]) ^ (v0 + sum) ^ ((v0 >> 5) + keyWords[3])));
            }
            BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(offset, 4), v0);
            BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(offset + 4, 4), v1);
        }
        return output;
    }

    private static byte[] Scalar(byte value)
    {
        var data = new byte[32];
        data[^1] = value;
        return data;
    }

    private static byte[] ScalarBytes(byte value, int count)
    {
        var data = new byte[count];
        data[^1] = value;
        return data;
    }
}
