using System.Buffers.Binary;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Math;

namespace XDecode.Core;

public sealed class XlogDecoder(IEnumerable<XlogCredentials>? credentials = null) : ILogDecoder
{
    private readonly XlogCredentials[] _credentials = credentials?.ToArray() ?? [];
    public LogFormat Format => LogFormat.Xlog;

    public DecodedLog Decode(ReadOnlyMemory<byte> data, string sourcePath)
    {
        if (data.IsEmpty) throw DecodeException.Malformed("Xlog 文件为空");
        var span = data.Span;
        var cursor = FindFrameStart(span, 0);
        if (cursor < 0) throw DecodeException.Malformed("未找到有效的 Xlog 数据帧");

        using var output = new MemoryStream();
        var diagnostics = new Diagnostics();
        ushort? previousSequence = null;
        int? preferredCredentialIndex = null;
        if (cursor > 0)
        {
            diagnostics.DamagedSections++;
            diagnostics.SkippedBytes += cursor;
        }

        while (cursor < span.Length)
        {
            if (!Frame.TryRead(span, cursor, out var frame))
            {
                diagnostics.DamagedSections++;
                var recovered = FindFrameStart(span, cursor + 1);
                if (recovered >= 0)
                {
                    diagnostics.SkippedBytes += recovered - cursor;
                    cursor = recovered;
                    continue;
                }
                diagnostics.SkippedBytes += span.Length - cursor;
                break;
            }

            diagnostics.TotalFrames++;
            if (previousSequence.HasValue && frame.Sequence > 1 &&
                frame.Sequence != previousSequence.Value + 1)
                diagnostics.SequenceGaps++;
            if (frame.Sequence != 0) previousSequence = frame.Sequence;

            try
            {
                var maximum = checked(DecodeLimits.MaximumDecompressedOutputSize - (int)output.Length);
                var decoded = DecodePayload(frame, ref preferredCredentialIndex, maximum);
                DecodeLimits.ValidateOutputSize(output.Length, decoded.Length);
                output.Write(decoded);
                diagnostics.SuccessfulFrames++;
            }
            catch (PayloadException exception) when (exception.MissingCredentials)
            {
                diagnostics.FailedFrames++;
                diagnostics.MissingKeyFrames++;
            }
            catch (PayloadException)
            {
                diagnostics.FailedFrames++;
                diagnostics.RejectedKeyFrames++;
            }
            catch (DecodeException exception) when (exception.Kind == DecodeErrorKind.OutputLimitExceeded)
            {
                throw;
            }
            catch
            {
                diagnostics.FailedFrames++;
                diagnostics.InvalidPayloadFrames++;
            }
            cursor = frame.NextOffset;
        }

        var bytes = output.ToArray();
        if (diagnostics.SuccessfulFrames == 0 || bytes.Length == 0)
        {
            if (diagnostics.MissingKeyFrames > 0)
                throw DecodeException.DecodingFailed($"{diagnostics.FailureSummary}；缺少匹配的 Xlog secp256k1 私钥");
            if (diagnostics.RejectedKeyFrames > 0)
                throw DecodeException.DecodingFailed($"{diagnostics.FailureSummary}；Xlog 私钥不匹配或加密数据帧损坏");
            throw DecodeException.DecodingFailed($"{diagnostics.FailureSummary}；没有可输出的日志内容");
        }
        return diagnostics.IsComplete
            ? DecodedLog.Complete(bytes, diagnostics.CompleteMessage)
            : DecodedLog.Partial(bytes, diagnostics.Message);
    }

    private byte[] DecodePayload(Frame frame, ref int? preferredCredentialIndex, int maximumOutputSize)
    {
        if (!Info(frame.Magic).RequiresEcdh)
            return Decompress(frame.Payload, frame.Magic, maximumOutputSize);
        if (_credentials.Length == 0) throw PayloadException.Missing();

        var indices = Enumerable.Range(0, _credentials.Length).ToList();
        if (preferredCredentialIndex is { } preferred && indices.Remove(preferred))
            indices.Insert(0, preferred);
        foreach (var index in indices)
        {
            try
            {
                var key = DeriveTeaKey(frame.PublicKey, _credentials[index].PrivateKey);
                var decrypted = Tea.Decrypt(frame.Payload, key);
                var decoded = Decompress(decrypted, frame.Magic, maximumOutputSize);
                preferredCredentialIndex = index;
                return decoded;
            }
            catch (DecodeException exception) when (exception.Kind == DecodeErrorKind.OutputLimitExceeded)
            {
                throw;
            }
            catch { }
        }
        throw PayloadException.Rejected();
    }

    private static byte[] Decompress(ReadOnlySpan<byte> payload, XlogMagic magic, int maximumOutputSize) =>
        magic switch
        {
            XlogMagic.Compress or XlogMagic.CompressNoCrypt or XlogMagic.CompressEcdh =>
                CompressionUtilities.InflateRaw(payload, maximumOutputSize),
            XlogMagic.CompressChunked =>
                CompressionUtilities.InflateRaw(JoinChunkedPayload(payload), maximumOutputSize),
            XlogMagic.SyncZstdCrypt or XlogMagic.SyncZstdNoCrypt or
                XlogMagic.AsyncZstdCrypt or XlogMagic.AsyncZstdNoCrypt =>
                CompressionUtilities.Zstd(payload, maximumOutputSize),
            _ => CopyBounded(payload, maximumOutputSize)
        };

    private static byte[] CopyBounded(ReadOnlySpan<byte> payload, int maximumOutputSize)
    {
        DecodeLimits.ValidateOutputSize(0, payload.Length, maximumOutputSize);
        return payload.ToArray();
    }

    private static byte[] JoinChunkedPayload(ReadOnlySpan<byte> payload)
    {
        using var output = new MemoryStream();
        var cursor = 0;
        while (cursor < payload.Length)
        {
            var length = payload.UInt16LE(cursor);
            cursor += 2;
            output.Write(payload.CheckedRange(cursor, length));
            cursor += length;
        }
        return output.ToArray();
    }

    private static byte[] DeriveTeaKey(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> privateKey)
    {
        if (publicKey.Length != 64) throw DecodeException.DecryptionFailed("Xlog ECDH 公钥长度无效");
        try
        {
            var domain = SecNamedCurves.GetByName("secp256k1");
            var encoded = new byte[65];
            encoded[0] = 0x04;
            publicKey.CopyTo(encoded.AsSpan(1));
            var point = domain.Curve.DecodePoint(encoded);
            var scalar = new BigInteger(1, privateKey.ToArray());
            var shared = point.Multiply(scalar).Normalize().GetEncoded(false);
            if (shared.Length != 65) throw DecodeException.DecryptionFailed("ECDH 共享点长度无效");
            return shared[1..17];
        }
        catch (DecodeException) { throw; }
        catch (Exception exception) { throw DecodeException.DecryptionFailed($"ECDH：{exception.Message}", exception); }
    }

    private static int FindFrameStart(ReadOnlySpan<byte> data, int start)
    {
        for (var offset = Math.Max(start, 0); offset < data.Length; offset++)
            if (Frame.TryRead(data, offset, out _)) return offset;
        return -1;
    }

    private sealed class PayloadException(bool missing) : Exception
    {
        public bool MissingCredentials { get; } = missing;
        public static PayloadException Missing() => new(true);
        public static PayloadException Rejected() => new(false);
    }

    private sealed class Diagnostics
    {
        public int TotalFrames, SuccessfulFrames, FailedFrames, MissingKeyFrames, RejectedKeyFrames;
        public int InvalidPayloadFrames, DamagedSections, SkippedBytes, SequenceGaps;
        public bool IsComplete => FailedFrames == 0 && DamagedSections == 0 && SequenceGaps == 0;
        public string CompleteMessage => $"Xlog 解密完成：成功 {SuccessfulFrames} 帧，失败 0 帧";
        public string FailureSummary => $"Xlog 解密失败：成功 0 帧，失败 {FailedFrames} 帧";
        public string Message
        {
            get
            {
                var details = new List<string> { $"Xlog 部分解密：成功 {SuccessfulFrames} 帧，失败 {FailedFrames} 帧" };
                if (MissingKeyFrames > 0) details.Add($"{MissingKeyFrames} 个加密帧缺少匹配私钥");
                if (RejectedKeyFrames > 0) details.Add($"{RejectedKeyFrames} 个加密帧密钥不匹配或已损坏");
                if (InvalidPayloadFrames > 0) details.Add($"{InvalidPayloadFrames} 个数据帧解压失败或已损坏");
                if (DamagedSections > 0) details.Add($"跳过 {DamagedSections} 段损坏数据（{SkippedBytes} 字节）");
                if (SequenceGaps > 0) details.Add($"检测到 {SequenceGaps} 处日志序号缺失");
                return string.Join('；', details);
            }
        }
    }

    private enum XlogMagic : byte
    {
        NoCompress = 0x03, Compress = 0x04, CompressChunked = 0x05,
        NoCompressExtended = 0x06, CompressEcdh = 0x07, NoCompressNoCrypt = 0x08,
        CompressNoCrypt = 0x09, SyncZstdCrypt = 0x0a, SyncZstdNoCrypt = 0x0b,
        AsyncZstdCrypt = 0x0c, AsyncZstdNoCrypt = 0x0d
    }

    private readonly record struct MagicInfo(int KeyLength, bool RequiresEcdh);

    private static MagicInfo Info(XlogMagic magic) => magic switch
    {
        XlogMagic.NoCompress or XlogMagic.Compress or XlogMagic.CompressChunked => new(4, false),
        XlogMagic.CompressEcdh or XlogMagic.SyncZstdCrypt or XlogMagic.AsyncZstdCrypt => new(64, true),
        _ => new(64, false)
    };

    private readonly record struct Frame(
        XlogMagic Magic, ushort Sequence, byte[] PublicKey, byte[] Payload, int NextOffset)
    {
        public static bool TryRead(ReadOnlySpan<byte> data, int offset, out Frame frame)
        {
            frame = default;
            try
            {
                var rawMagic = data.UInt8(offset);
                if (rawMagic is < 0x03 or > 0x0d) return false;
                var magic = (XlogMagic)rawMagic;
                var info = Info(magic);
                var headerLength = 1 + 2 + 1 + 1 + 4 + info.KeyLength;
                if (offset < 0 || offset > data.Length - headerLength - 1) return false;
                var payloadLength = checked((int)data.UInt32LE(offset + 5));
                var payloadStart = checked(offset + headerLength);
                var endMarker = checked(payloadStart + payloadLength);
                if (endMarker >= data.Length || data[endMarker] != 0) return false;
                frame = new(
                    magic,
                    data.UInt16LE(offset + 1),
                    data.CheckedRange(offset + 9, info.KeyLength).ToArray(),
                    data.CheckedRange(payloadStart, payloadLength).ToArray(),
                    endMarker + 1);
                return true;
            }
            catch { return false; }
        }
    }

    private static class Tea
    {
        public static byte[] Decrypt(ReadOnlySpan<byte> data, ReadOnlySpan<byte> key)
        {
            if (key.Length < 16) return data.ToArray();
            var output = new byte[data.Length];
            var keyWords = new uint[4];
            for (var index = 0; index < 4; index++)
                keyWords[index] = BinaryPrimitives.ReadUInt32LittleEndian(key.Slice(index * 4, 4));
            var completeLength = data.Length / 8 * 8;
            for (var offset = 0; offset < completeLength; offset += 8)
            {
                var v0 = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(offset, 4));
                var v1 = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(offset + 4, 4));
                const uint delta = 0x9e3779b9;
                var sum = unchecked(delta << 4);
                for (var round = 0; round < 16; round++)
                {
                    v1 = unchecked(v1 - (((v0 << 4) + keyWords[2]) ^ (v0 + sum) ^ ((v0 >> 5) + keyWords[3])));
                    v0 = unchecked(v0 - (((v1 << 4) + keyWords[0]) ^ (v1 + sum) ^ ((v1 >> 5) + keyWords[1])));
                    sum = unchecked(sum - delta);
                }
                BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(offset, 4), v0);
                BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(offset + 4, 4), v1);
            }
            data[completeLength..].CopyTo(output.AsSpan(completeLength));
            return output;
        }
    }
}
