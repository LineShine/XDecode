# XDecode

XDecode 是一个原生 macOS 日志解密工具，统一处理 Tencent Mars Xlog、iOS Logan、MX FlatBuffers 日志，以及包含这些日志的 ZIP 压缩包。应用支持手动选择、拖放、打开方式、Finder 右键和文件夹自动监听，解密结果统一输出为可读的 `.log` 文件。

> [!WARNING]
> 单个 Xlog、MX 或 Logan 日志只有在完整解密并成功写入 `.log` 后，才会永久删除源文件。首次处理前应用会要求确认此策略。ZIP 批量处理始终保留源 ZIP。请先确认原始日志已有备份。

## 核心能力

| 格式 | 默认文件名规则 | 解码能力 | 密钥 |
| --- | --- | --- | --- |
| Xlog | `*.xlog` | 支持 `0x03...0x0D` 帧、无压缩、raw deflate、分块 deflate、Zstandard、损坏帧扫描和序号完整性检查 | 加密帧使用 secp256k1 ECDH 派生 TEA Key；私钥为 64 位 Hex |
| Logan | `yyyy-MM-dd` 或 `*.logan` | 解析 Logan 帧，AES-128-CBC 解密，兼容 PKCS#7/NoPadding，自动解压 zlib/gzip，并恢复未结束末帧中的完整日志行 | Key 和 IV 均至少 16 个 UTF-8 字节，实际使用前 16 字节；也会先尝试全零 Key/IV |
| MX | `*.mx` | 解析长度前缀和 FlatBuffers 条目，输出时间、级别、Tag 与消息 | 不需要密钥 |
| ZIP | `^[0-9]+_[0-9]+\.zip$` | 在保留目录结构及非日志文件的同时批量解密 Xlog、Logan 和 MX | 各条目沿用对应格式的匹配方案 |

应用还提供以下能力：

- 多套 Xlog 私钥和 Logan Key/IV 方案，可按文件名匹配并依次尝试。
- 多文件并行任务、多个递归监控文件夹，以及文件写入稳定后再自动处理。
- 30 天任务历史、macOS 通知、菜单栏最近任务和 Finder 中定位输出。
- App Sandbox、Security-Scoped Bookmark 和 macOS Keychain。密钥不会写入 `UserDefaults` 或历史记录。
- ZIP 路径穿越、重复路径、CRC、条目数量和解压大小校验。

## 使用方法

### 1. 配置文件名和密钥

打开“设置”：

1. Xlog 加密日志：新增“Xlog secp256k1 私钥”方案，填写方案名称、文件名匹配规则和 64 位 Hex 私钥。
2. Logan 加密日志：新增“Logan Key / IV”方案，填写文件名规则、AES Key 和 IV。Key/IV 超过 16 字节的部分不会参与解密。
3. MX：默认匹配 `*.mx`，可直接修改匹配规则。
4. ZIP：默认只接收形如 `123_456.zip` 的文件，可维护多条正则规则，任一匹配即可处理。

非正则规则支持 `*`、`?` 和 `yyyy-MM-dd` 模板，匹配不区分大小写，并要求覆盖完整文件名。以 `^` 开头的规则会按原始正则表达式处理。

Xlog 可以用随仓库提供的脚本生成密钥对：

```bash
python3 -m pip install cryptography
python3 script/xlog_gen_key.py
```

将脚本输出的私钥保存到 XDecode，将公钥配置到日志写入端的 `MixLogConfig.publicKey`。不要把生产私钥提交到仓库或写入 Python 脚本。

### 2. 提交日志

可以通过任一入口提交一个或多个文件：

- 拖入“解密日志”区域。
- 点击“选择文件”，或按 `Command-O`。
- 在 Finder 中选择“打开方式 -> XDecode”。
- 启用 Finder 扩展后，使用右键菜单“使用 XDecode 解密”。Finder 扩展当前覆盖用户主目录。
- 在“监控文件夹”中添加一个或多个目录并启用“自动解密”。监听是递归的，只处理启用监听后新增且符合规则的普通文件。

App Sandbox 第一次处理某个目录中的文件时，会要求授权日志所在文件夹。自动监听启用后，应用会注册为登录项；关闭自动解密会停止监听并注销登录项。

### 3. 查看结果

单文件输出位于源文件同级目录：

```text
sample.xlog -> sample.log
sample.mx   -> sample.log
2026-07-28  -> 2026-07-28.log
```

若输出已存在，会使用 `sample-1.log`、`sample-2.log`，并通过排他重命名避免并发任务覆盖文件。

ZIP 会在同级目录生成同名文件夹：

```text
123_456.zip
123_456/
  first.log
  nested/second.logan  # 解密失败时保留原始文件名和内容
  metadata.json        # 非日志条目原样保留
```

ZIP 中全部成功、部分成功或全部日志解密失败时都会生成输出目录；无法读取压缩包、安全校验失败或没有受支持日志时不生成目录。源 ZIP 在所有情况下均保留。

“历史记录”保留最近 30 天的任务，可以直接在 Finder 中定位输出；清空历史只删除记录，不删除日志文件。

## 完整性与安全策略

- 单文件必须完整成功：Xlog 存在失败帧、损坏区段或序号缺口时，即使恢复出部分文本，也不生成 `.log`，源文件保持不变。Logan 任意帧失败时同样拒绝整个文件。
- 单文件先在源目录写临时文件并同步到磁盘，再以不覆盖现有文件的方式发布；发布成功后才尝试删除源文件。
- 如果结果已生成但源文件删除失败，任务状态为“成功但有警告”，结果文件保留。
- ZIP 永不删除源包；解密失败的日志条目会原样写入输出目录。
- ZIP 最多允许 1,000 个条目、100 个日志；单条目解压后最大 512 MB，总解压大小最大 1 GB。
- ZIP 拒绝绝对路径、`..` 路径穿越、大小写不敏感的重复路径和 CRC 不匹配条目，并忽略 `__MACOSX`/AppleDouble 元数据。
- 自动监听对 ZIP 输出登记文件路径和 inode，避免新生成的目录被监听器再次解密；登记默认保留 7 天。

## 工程结构

```text
XDecode/
├── AGENTS.md                      # Codex AI Coding 工程指南
├── Package.swift                 # Swift Package、依赖和测试入口
├── Sources/XDecodeCore/          # 无 UI 的解码器、模型和文件发布协调器
├── XDecodeApp/                   # SwiftUI App、设置、监听、历史、通知、钥匙串
├── XDecodeFinder/                # Finder Sync 右键扩展
├── Tests/XDecodeCoreTests/       # 格式、完整性、并发输出和 ZIP 安全测试
├── Tests/XDecodeAppTests/        # 匹配、书签、监听、通知和抑制回环测试
├── script/                       # Python 协议参考与手工诊断脚本
└── XDecode.xcodeproj/            # macOS App 与 Finder Extension 工程
```

核心调用链如下：

```text
UI / Finder / FSEvents
        |
        v
AppModel -> AppSettings 文件名分类 -> DecodeRequest
        |                              |
        |                              +-> DecodeCoordinator -> Xlog/MX/Logan Decoder
        +--------------------------------> ZipDecodeCoordinator -> 逐条目 Decoder
                                               |
                                               v
                                  DecodeResult -> 历史 / 通知 / 菜单栏
```

主要模块：

- `Sources/XDecodeCore/Models.swift`：格式、请求、结果、状态、凭据和错误模型。
- `Sources/XDecodeCore/XlogDecoder.swift`：Xlog 帧恢复、ECDH/TEA 和 deflate/zstd 解压。
- `Sources/XDecodeCore/LoganDecoder.swift`：Logan framing、AES-CBC 和 zlib/gzip 解压。
- `Sources/XDecodeCore/MXDecoder.swift`：MX 长度前缀与 FlatBuffers 读取。
- `Sources/XDecodeCore/DecodeCoordinator.swift`：单文件事务式输出和源文件删除。
- `Sources/XDecodeCore/ZipDecodeCoordinator.swift`：ZIP 检查、分项处理和目录发布。
- `XDecodeApp/AppModel.swift`：入口汇总、权限、任务、密钥解析和结果分发。
- `XDecodeApp/AppSettings.swift`：文件名规则、方案元数据和监控目录书签。
- `XDecodeApp/FolderMonitor.swift`：基于 FSEvents 的递归新增文件检测。
- `XDecodeFinder/FinderSync.swift`：Finder 菜单和主 App 拉起。

## 构建与测试

要求：

- macOS 13 或更高版本。
- 支持 Swift 6.1 工具链的 Xcode。工程当前以 Swift 6 模式编译。
- 首次构建需要解析 Swift Package 依赖。

依赖包括：

- `SwiftZSTD 1.0.1`：Xlog Zstandard 解压。
- `swift-secp256k1 0.23.2`：Xlog secp256k1 ECDH。
- `ZIPFoundation 0.9.20`：ZIP 读取和 CRC 校验。
- 系统 `zlib`、`CommonCrypto`、`Security`、`ServiceManagement` 与 `UserNotifications`。

运行全部单元测试：

```bash
swift test
```

构建 Swift Package：

```bash
swift build
```

运行完整 macOS App 和 Finder 扩展：

1. 打开 `XDecode.xcodeproj`。
2. 根据本机开发者账号调整 Signing Team 和 App Group（当前为 `group.com.lingxiang.XDecode`）。主 App 与扩展必须使用同一个 App Group。
3. 选择共享的 `XDecode` Scheme 并运行。
4. 在系统设置中启用 XDecode Finder 扩展，验证右键入口。

Xcode 工程通过本地 Package 引用 `XDecodeCore`；解码器测试和 App 逻辑测试都由 `Package.swift` 管理，因此改动后以 `swift test` 为主要回归入口。

## Python 参考脚本

`script/` 不参与 App 构建，主要用于协议对照、生成 Xlog 密钥和脱离 UI 的手工排查：

- `xlog_gen_key.py`：生成 secp256k1 Xlog 密钥对。
- `xlog_crypt_log.py` / `xlog_nocrypt_log.py`：Xlog 参考解析器。
- `logan_decrypt_log.py` / `logan_decrypt_log_list.py`：Logan 单文件/批量参考解析器，需要 `pycryptodome`。
- `decode_mx.py`：MX 参考解析器。

部分 Xlog 脚本还依赖 `cryptography` 或 `zstandard`。Swift 实现及其测试才是 App 行为的最终依据；参考脚本可能采用不同的输出命名和容错策略。
