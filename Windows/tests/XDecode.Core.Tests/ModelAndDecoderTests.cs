using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using XDecode.Core;

namespace XDecode.Core.Tests;

public sealed class ModelAndDecoderTests
{
    [Theory]
    [InlineData("sample.xlog", LogFormat.Xlog)]
    [InlineData("sample.MX", LogFormat.Mx)]
    [InlineData("sample.logan", LogFormat.Logan)]
    [InlineData("2026-07-27", LogFormat.Logan)]
    [InlineData("1_2.zip", LogFormat.Zip)]
    public void DetectsSupportedFormats(string name, LogFormat expected) =>
        Assert.Equal(expected, LogFormats.Detect(Path.Combine("C:\\logs", name)));

    [Theory]
    [InlineData(DecodeState.Completed, "\"completed\"")]
    [InlineData(DecodeState.PartiallyCompleted, "\"partiallyCompleted\"")]
    [InlineData(DecodeState.CompletedWithWarning, "\"completedWithWarning\"")]
    [InlineData(DecodeState.Skipped, "\"skipped\"")]
    [InlineData(DecodeState.Failed, "\"failed\"")]
    public void DecodeStatesPreserveWireValues(DecodeState state, string expected)
    {
        Assert.Equal(expected, JsonSerializer.Serialize(state));
        Assert.Equal(state, JsonSerializer.Deserialize<DecodeState>(expected));
    }

    [Theory]
    [InlineData(LogFormat.Xlog, "\"xlog\"")]
    [InlineData(LogFormat.Mx, "\"mx\"")]
    [InlineData(LogFormat.Logan, "\"logan\"")]
    [InlineData(LogFormat.Zip, "\"zip\"")]
    public void LogFormatsPreserveWireValues(LogFormat format, string expected)
    {
        Assert.Equal(expected, JsonSerializer.Serialize(format));
        Assert.Equal(format, JsonSerializer.Deserialize<LogFormat>(expected));
    }

    [Theory]
    [InlineData(DecodeOrigin.Automatic, "\"automatic\"")]
    [InlineData(DecodeOrigin.DragAndDrop, "\"dragAndDrop\"")]
    [InlineData(DecodeOrigin.FilePicker, "\"filePicker\"")]
    [InlineData(DecodeOrigin.Explorer, "\"explorer\"")]
    [InlineData(DecodeOrigin.OpenWith, "\"openWith\"")]
    public void DecodeOriginsPreserveWireValues(DecodeOrigin origin, string expected)
    {
        Assert.Equal(expected, JsonSerializer.Serialize(origin));
        Assert.Equal(origin, JsonSerializer.Deserialize<DecodeOrigin>(expected));
    }

    [Theory]
    [InlineData("2026-7-27")]
    [InlineData("archive")]
    [InlineData("sample.txt")]
    public void RejectsUnsupportedFormats(string name) =>
        Assert.Throws<DecodeException>(() => LogFormats.Detect(Path.Combine("C:\\logs", name)));

    [Fact]
    public void LoganCredentialsRequireSixteenBytesAndTruncate()
    {
        Assert.Throws<DecodeException>(() => new LoganCredentials("short", "1234567890123456"));
        var value = new LoganCredentials("1234567890123456-extra", "abcdefghijklmnop-extra");
        Assert.Equal("1234567890123456", Encoding.UTF8.GetString(value.Key));
        Assert.Equal("abcdefghijklmnop", Encoding.UTF8.GetString(value.IV));
    }

    [Theory]
    [InlineData("")]
    [InlineData("abc")]
    [InlineData("0000000000000000000000000000000000000000000000000000000000000000")]
    [InlineData("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")]
    public void XlogCredentialsRejectInvalidScalars(string value) =>
        Assert.Throws<DecodeException>(() => new XlogCredentials(value));

    [Fact]
    public void XlogCredentialsNormalizeWhitespaceAndPrefix()
    {
        var value = new XlogCredentials("0x 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " +
                                        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01");
        Assert.Equal(1, value.PrivateKey[^1]);
    }

    [Fact]
    public void XlogDecodesPlainFrame()
    {
        var expected = Encoding.UTF8.GetBytes("plain xlog\n");
        var decoded = new XlogDecoder().Decode(XlogFrame(0x08, expected), "plain.xlog");
        Assert.True(decoded.IsComplete);
        Assert.Equal(expected, decoded.Data);
    }

    [Fact]
    public void XlogDecodesRawDeflateFrame()
    {
        var expected = Encoding.UTF8.GetBytes("compressed xlog\n");
        var decoded = new XlogDecoder().Decode(
            XlogFrame(0x09, RawDeflate(expected)), "compressed.xlog");
        Assert.Equal(expected, decoded.Data);
    }

    [Fact]
    public void XlogReportsRecoveredFramesAsIncomplete()
    {
        var frame = XlogFrame(0x08, Encoding.UTF8.GetBytes("recovered\n"));
        var data = new byte[] { 0xff, 0xee, 0xdd }.Concat(frame).ToArray();
        var decoded = new XlogDecoder().Decode(data, "damaged.xlog");
        Assert.False(decoded.IsComplete);
        Assert.Contains("损坏", decoded.Diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void XlogRejectsSequenceGapAsIncomplete()
    {
        var first = XlogFrame(0x08, Encoding.UTF8.GetBytes("one\n"), sequence: 1);
        var second = XlogFrame(0x08, Encoding.UTF8.GetBytes("three\n"), sequence: 3);
        var decoded = new XlogDecoder().Decode(first.Concat(second).ToArray(), "gap.xlog");
        Assert.False(decoded.IsComplete);
        Assert.Contains("序号缺失", decoded.Diagnostic, StringComparison.Ordinal);
    }

    [Fact]
    public void MxDecodesFlatBufferFixture()
    {
        var decoded = new MxDecoder().Decode(MxFile(), "sample.mx");
        var line = Encoding.UTF8.GetString(decoded.Data);
        Assert.Contains(" I ['network', 'api'] hello from mx", line, StringComparison.Ordinal);
        Assert.EndsWith("\n", line, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("AAE=")]
    public void MxRejectsMalformedInput(string base64) =>
        Assert.Throws<DecodeException>(() =>
            new MxDecoder().Decode(Convert.FromBase64String(base64), "broken.mx"));

    [Fact]
    public void LoganDecryptsGzipPaddedFrame()
    {
        var credentials = new LoganCredentials("0123456789067890", "0123456789067890");
        var expected = Encoding.UTF8.GetBytes("logan fixture\n");
        var encrypted = EncryptAes(Gzip(expected), credentials, PaddingMode.PKCS7);
        var decoded = new LoganDecoder(credentials).Decode(LoganFrame(encrypted), "sample.logan");
        Assert.Equal(expected, decoded.Data);
    }

    [Fact]
    public void LoganTriesEveryCredential()
    {
        var valid = new LoganCredentials("0123456789067890", "0123456789067890");
        var wrong = new LoganCredentials("1111111111111111", "2222222222222222");
        var expected = Encoding.UTF8.GetBytes("candidate\n");
        var encrypted = EncryptAes(Gzip(expected), valid, PaddingMode.PKCS7);
        var decoded = new LoganDecoder([wrong, valid]).Decode(LoganFrame(encrypted), "sample.logan");
        Assert.Equal(expected, decoded.Data);
    }

    [Fact]
    public void LoganUsesZeroFilledCompatibilityCandidate()
    {
        var zero = new LoganCredentials(new byte[16], new byte[16]);
        var expected = Encoding.UTF8.GetBytes("unkeyed\n");
        var encrypted = EncryptAes(Gzip(expected), zero, PaddingMode.PKCS7);
        var decoded = new LoganDecoder([]).Decode(LoganFrame(encrypted), "sample.logan");
        Assert.Equal(expected, decoded.Data);
    }

    [Theory]
    [InlineData("fwAB")]
    [InlineData("AQAAABClpaWlpaWlpaWlpaWlpaWlAA==")]
    public void LoganRejectsMalformedFrames(string base64) =>
        Assert.ThrowsAny<Exception>(() =>
            new LoganDecoder(new LoganCredentials("0123456789067890", "0123456789067890"))
                .Decode(Convert.FromBase64String(base64), "bad.logan"));

    [Fact]
    public void OutputLimitAcceptsExactValueAndRejectsOverflow()
    {
        DecodeLimits.ValidateOutputSize(60, 40, 100);
        var exception = Assert.Throws<DecodeException>(() =>
            DecodeLimits.ValidateOutputSize(60, 41, 100));
        Assert.Equal(DecodeErrorKind.OutputLimitExceeded, exception.Kind);
    }

    private static byte[] XlogFrame(byte magic, byte[] payload, ushort sequence = 1)
    {
        var keyLength = magic is 0x03 or 0x04 or 0x05 ? 4 : 64;
        var data = new byte[1 + 2 + 2 + 4 + keyLength + payload.Length + 1];
        data[0] = magic;
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(1), sequence);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(5), (uint)payload.Length);
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

    private static byte[] Gzip(byte[] data)
    {
        using var output = new MemoryStream();
        using (var stream = new GZipStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
            stream.Write(data);
        return output.ToArray();
    }

    private static byte[] EncryptAes(byte[] data, LoganCredentials credentials, PaddingMode padding)
    {
        using var aes = Aes.Create();
        aes.Mode = CipherMode.CBC;
        aes.Padding = padding;
        aes.Key = credentials.Key;
        aes.IV = credentials.IV;
        using var encryptor = aes.CreateEncryptor();
        return encryptor.TransformFinalBlock(data, 0, data.Length);
    }

    private static byte[] LoganFrame(byte[] encrypted)
    {
        var data = new byte[1 + 4 + encrypted.Length + 1];
        data[0] = 1;
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(1), (uint)encrypted.Length);
        encrypted.CopyTo(data, 5);
        return data;
    }

    private static byte[] MxFile()
    {
        const int tableStart = 24;
        const int tagStart = 48;
        const int messageStart = 64;
        var tag = Encoding.UTF8.GetBytes("network,api");
        var message = Encoding.UTF8.GetBytes("hello from mx");
        var item = new byte[messageStart + 4 + message.Length + 1];
        WriteUInt32(item, 0, tableStart);
        WriteUInt16(item, 4, 18);
        WriteUInt16(item, 6, 24);
        WriteUInt16(item, 10, 4);
        WriteUInt16(item, 12, 8);
        WriteUInt16(item, 14, 12);
        WriteUInt16(item, 20, 16);
        WriteUInt32(item, tableStart, tableStart - 4);
        WriteUInt32(item, tableStart + 4, tagStart - (tableStart + 4));
        WriteUInt32(item, tableStart + 8, messageStart - (tableStart + 8));
        item[tableStart + 12] = 1;
        BinaryPrimitives.WriteUInt64LittleEndian(item.AsSpan(tableStart + 16), 1_700_000_000_123_456);
        WriteUInt32(item, tagStart, tag.Length);
        tag.CopyTo(item, tagStart + 4);
        WriteUInt32(item, messageStart, message.Length);
        message.CopyTo(item, messageStart + 4);

        var file = new byte[8 + item.Length];
        WriteUInt32(file, 0, file.Length);
        WriteUInt32(file, 4, item.Length);
        item.CopyTo(file, 8);
        return file;
    }

    private static void WriteUInt16(byte[] data, int offset, int value) =>
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(offset), (ushort)value);
    private static void WriteUInt32(byte[] data, int offset, int value) =>
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(offset), (uint)value);
}
