# Third-Party Notices

XDecode Windows 使用下列第三方组件。发布包必须保留各组件随包许可证。

| 组件 | 固定版本 | 用途 | 许可证 |
| --- | --- | --- | --- |
| BouncyCastle.Cryptography | 2.6.2 | secp256k1 ECDH | MIT |
| ZstdSharp.Port | 0.8.8 | Zstandard 解压 | MIT |
| zlib | 1.3.1 | raw deflate、zlib、gzip | zlib License |
| Microsoft.WindowsAppSDK | 2.3.1 | WinUI 3、生命周期、通知 | Microsoft Software License |
| xUnit.net v3 | 3.2.0 | 测试 | Apache-2.0 |
| Inno Setup | 7.0.2 | 生成 x64 单文件 `setup.exe` | [Inno Setup License](https://github.com/jrsoftware/issrc/blob/is-7_0_2/license.txt)；商业使用需按官方政策配置许可证 |

NuGet 与 vcpkg 恢复目录中的原始许可证文件是最终许可证文本来源。
Inno Setup 编译器不随仓库提交；CI 从官方固定 release 下载并验证 attestation 与发布者签名。
