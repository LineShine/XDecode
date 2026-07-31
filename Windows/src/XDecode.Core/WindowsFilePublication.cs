using System.ComponentModel;
using System.Runtime.InteropServices;

namespace XDecode.Core;

internal static partial class WindowsFilePublication
{
    private const int ErrorAlreadyExists = 183;
    private const int ErrorFileExists = 80;

    public static bool TryMoveExclusive(string sourcePath, string destinationPath)
    {
        if (MoveFileEx(sourcePath, destinationPath, 0))
        {
            try
            {
                var attributes = File.GetAttributes(destinationPath);
                if ((attributes & FileAttributes.Hidden) != 0)
                    File.SetAttributes(destinationPath, attributes & ~FileAttributes.Hidden);
                return true;
            }
            catch (Exception exception)
            {
                if (MoveFileEx(destinationPath, sourcePath, 0))
                    throw DecodeException.FileOperation(
                        $"无法取消发布目标的隐藏属性：{exception.Message}", exception);

                var rollbackError = Marshal.GetLastPInvokeError();
                throw DecodeException.FileOperation(
                    $"无法取消发布目标的隐藏属性，且回滚失败：{new Win32Exception(rollbackError).Message}",
                    exception);
            }
        }
        var error = Marshal.GetLastPInvokeError();
        if (error is ErrorAlreadyExists or ErrorFileExists) return false;
        throw DecodeException.FileOperation(new Win32Exception(error).Message);
    }

    public static void MarkHidden(string path)
    {
        try { File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.Hidden); }
        catch (Exception exception) { throw DecodeException.FileOperation($"无法隐藏临时文件：{exception.Message}", exception); }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MoveFileEx(string existingFileName, string newFileName, uint flags);
}
