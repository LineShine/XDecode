# XDecode Codex 工程指南

本文是 Codex 在本仓库中的工作约定。开始修改前先阅读 `README.md`，再按改动范围阅读对应源文件和测试。以 Swift 实现和测试为行为真相，`script/` 中的 Python 代码只用于协议参考。

## 工程目标

XDecode 是 macOS 13+ 的日志解密 App，包含三个边界清晰的部分：

- `XDecodeCore`：纯解码逻辑、请求/结果模型，以及单文件和 ZIP 的文件发布流程。
- `XDecodeApp`：SwiftUI、任务编排、权限、设置、Keychain、FSEvents、通知和历史。
- `XDecodeFinder`：Finder Sync 入口，只筛选文件并交给主 App，不实现解密。

保持解码器可独立测试。不要把 AppKit、SwiftUI、Keychain、书签或通知依赖引入 `XDecodeCore`。

## 常用命令

```bash
# 完整回归，首选
swift test

# 仅运行某个 Suite/测试类型
swift test --filter XlogDecoderSecurityTests
swift test --filter ZipDecodeCoordinatorTests

# Swift Package 编译检查
swift build

# 完整 App + Finder Extension 编译检查
xcodebuild -project XDecode.xcodeproj -scheme XDecode -configuration Debug build
```

Xcode 构建可能需要本机 Signing Team 和 App Group。仅改 `Sources/XDecodeCore`、`XDecodeApp` 或测试时，至少运行 `swift test`。涉及工程配置、Entitlements、Info.plist、Finder 扩展或打包时，再运行 `xcodebuild` 并说明签名环境。

不要依赖 Xcode Scheme 运行 Package 测试；当前测试目标由 `Package.swift` 管理。

## 模块地图

### `Sources/XDecodeCore`

- `Models.swift`：`LogFormat`、`DecodeRequest`、`DecodeResult`、`DecodeState`、凭据、协议和错误。
- `Binary.swift`：所有二进制越界检查与大小端读取。
- `CompressionUtilities.swift`：raw deflate、zlib/gzip、未结束流和 zstd。
- `XlogDecoder.swift`：Xlog framing、帧恢复、secp256k1 ECDH、TEA、完整性诊断。
- `LoganDecoder.swift`：Logan framing、AES-128-CBC、PKCS#7/NoPadding、未完成末帧恢复。
- `MXDecoder.swift`：MX 长度前缀和 FlatBuffers 字段读取。
- `DecodeCoordinator.swift`：单日志临时写入、排他发布、成功后删除源文件。
- `ZipDecodeCoordinator.swift`：ZIP 安全检查、逐条目解码、失败项保留和目录发布。

### `XDecodeApp`

- `AppModel.swift` 是统一编排入口；所有 UI/Finder/FSEvents 输入最终都进入 `enqueue`/`process`。
- `AppSettings.swift` 管理 UserDefaults 元数据、文件名规则和监控目录书签。
- `KeychainStore.swift` 只存 Xlog/Logan 密钥正文。
- `FolderMonitor.swift` 只报告新增普通文件；格式过滤由 `AppModel`/`AppSettings` 完成。
- `AutomaticDecodeSuppressionStore.swift` 防止监控器重新处理 ZIP 自己发布的输出。
- `HistoryStore.swift` 只保留 30 天 `DecodeResult`，不得写入密钥或日志正文。

### `XDecodeFinder`

`FinderSync.swift` 读取共享 App Group 的文件名设置并把选中 URL 交给主 App。这里复制了部分 `AppSettings` 匹配逻辑；修改默认规则、迁移键或通配符语义时，必须同步检查两处。

## 不可破坏的行为

### 单文件事务

1. 解码器只返回内存中的 `DecodedLog`，不写文件、不删除文件。
2. `DecodedLog.isComplete == false` 必须视为失败，不发布部分 `.log`。
3. 结果先写到源目录内的隐藏临时文件，执行 `synchronize()` 后再发布。
4. 发布使用 `renamex_np(..., RENAME_EXCL)`，不能静默覆盖现有文件；重名追加 `-1`、`-2`。
5. 只有完整结果发布成功后才能永久删除源日志。
6. 删除失败返回 `completedWithWarning`，不能删除已发布结果或把任务改为纯失败。
7. 任意失败必须清理临时文件、保留源日志，且不得留下半成品 `.log`。

修改这些行为时，必须覆盖 `DecodeCoordinatorTests` 的成功、部分结果、失败和并发命名场景。

### ZIP 批量事务

- 源 ZIP 永远保留，不复用单文件的删除策略，也不要求永久删除确认。
- 成功条目写 `.log`；失败条目以原路径、原文件名和原始内容保留。
- 非日志文件及目录结构原样保留；`__MACOSX` 和 `._*` 元数据除外。
- 部分成功和全部日志解密失败都发布输出目录；压缩包本身检查失败时不发布目录。
- 发布目录同样必须排他命名，不能覆盖已有目录。
- 在放宽任何限制前先做威胁分析。当前限制为 1,000 个条目、100 个日志、单条目 512 MB、总计 1 GB。
- 必须保留 Zip Slip、绝对路径、NUL、Windows 盘符、大小写重复路径、解压大小、CRC 和实际大小校验。
- ZIP 输出位于被监控目录时，必须先登记 suppression，再重命名 staging 目录，避免自动解密回环。

修改 ZIP 时运行 `ZipDecodeCoordinatorTests` 和 `AutomaticDecodeSuppressionStoreTests`，最后运行全部测试。

## 格式契约

### Xlog

- 支持 Magic `0x03...0x0D`；变更 Magic、Header 或 key length 时同步更新解析、恢复扫描和 fixture。
- 加密帧只使用匹配文件名的 Xlog profile。多个匹配私钥应依次尝试，并优先复用刚成功的方案。
- secp256k1 私钥必须是有效 32 字节标量；公钥输入是 64 字节 XY，ECDH 共享点取 `1..<17` 作为 16 字节 TEA Key。
- 损坏区段、失败帧或序号缺口都使结果不完整。可在诊断中报告已恢复帧，但协调器不能发布部分输出。
- raw deflate 的 `Z_SYNC_FLUSH` 兼容行为有专门测试，不要用普通的一次性解压替换。

### Logan

- 每帧为 `0x01 + 4 字节大端密文长度 + 密文`，帧间分隔符为 `0x00`，最后一帧可以没有分隔符。
- 每个候选先尝试 PKCS#7，再尝试 NoPadding；解压自动接受 zlib/gzip。
- 全零 Key/IV 是首个兼容候选。配置 Key/IV 至少 16 字节，只使用前 16 字节。
- 只允许在最后一个 NoPadding 帧恢复未结束压缩流，并裁剪到最后一个完整换行。
- 输出必须是非空 UTF-8；任何帧失败都拒绝整个文件。

### MX

- 文件和条目长度均为小端；条目是手工读取的 FlatBuffers Table。
- 单条不可解析记录当前会跳过；整个文件没有可输出记录时返回 `emptyOutput`。
- 时间戳单位是微秒，输出级别映射为 `D/I/W/E/F`。

## 文件名识别

默认规则：Xlog `*.xlog`，MX `*.mx`，Logan `yyyy-MM-dd`，ZIP `^[0-9]+_[0-9]+\.zip$`。

- 规则不区分大小写。
- 非 `^` 开头的规则会转成全文件名匹配，支持 `*`、`?`、`yyyy`、`MM`、`dd`。
- `^` 开头的规则直接作为正则，不额外补 `$`。
- `.logan` 扩展始终可分类为 Logan；无自定义 Logan profile 时才启用默认日期规则。
- ZIP 内条目使用同一套 App 设置分类，但禁止递归把 ZIP 当作日志条目。

新增格式或改变规则时，至少同步检查：

1. `LogFormat` 与 `StandardDecoderResolver`。
2. `AppSettings.logFormat(for:)`、默认值和迁移逻辑。
3. `UTType+Logs.swift`、`XDecodeApp/Info.plist` 和选择/拖放提示。
4. `XDecodeFinder/FinderSync.swift`。
5. ZIP entry resolver、通知文案和设置 UI。
6. Core/App 两组测试与 `README.md`。

## 并发和状态

- 工程按 Swift 6 并发规则编译。Core 的跨任务值保持 `Sendable`；文件协调器、历史、稳定性检查和 suppression 使用 actor。
- UI 状态、`AppModel`、`AppSettings`、FSEvents 控制器和通知中心留在 `@MainActor`。
- 不要用 `nonisolated(unsafe)` 绕过新问题；`FolderMonitor.stream` 是 Core Foundation 回调生命周期的局部例外。
- `activeSourcePaths` 防止同一路径并发重复处理，任何新增入口都必须经过 `AppModel.enqueue`。
- Security-scoped access 必须成对结束。异步任务的所有退出路径都要释放文件 URL 和授权目录访问。
- 自动监听启动时先快照已有文件，只处理之后新增的文件；不要改成启动后扫描并处理整个目录。

## 数据与安全

- 不得在源码、测试 fixture、README、日志、`UserDefaults`、通知或 `DecodeResult` 中加入真实私钥、AES Key/IV 或用户日志正文。
- `script/xlog_crypt_log.py` 含协议参考用常量，不能把它当生产密钥来源，也不要把用户提供的密钥写回脚本。
- Xlog/Logan 方案元数据放共享 `UserDefaults`，密钥正文只放对应 Keychain service。
- 主 App 与 Finder 扩展必须保持相同 App Group；改 Bundle ID/App Group 时同步工程、entitlements、UserDefaults suite 和容器访问。
- 文件授权通过 app-scoped security bookmark 持久化。不要扩大沙盒权限来规避书签流程。
- 二进制解析必须通过有边界检查的读取方法；对来自文件的长度做溢出和上限验证后才能分配内存。

## 测试策略

使用 Swift Testing（`import Testing`、`@Suite`、`@Test`、`#expect`），沿用现有风格。测试数据优先在内存中合成，文件测试使用唯一临时目录并在 `defer` 中清理。

按改动范围选择起步测试：

| 改动 | 重点测试 |
| --- | --- |
| Xlog framing/加密/压缩 | `DecoderFixtureTests`、`XlogDecoderSecurityTests`、`XlogSyncFlushTests` |
| Logan | `DecoderFixtureTests`、`DecoderValidationTests` |
| MX/二进制读取 | `DecoderFixtureTests`、`DecoderValidationTests` |
| 单文件发布/删除 | `DecodeCoordinatorTests` |
| ZIP | `ZipDecodeCoordinatorTests`、`AutomaticDecodeSuppressionStoreTests` |
| 匹配和设置 | `XlogSettingsTests` |
| 文件权限/监听 | `FolderAccessStoreTests`、`FolderMonitorTests` |
| 通知/菜单栏摘要 | `NotificationManagerTests` |

完成后仍应运行 `swift test`。若因签名、通知权限、Finder 扩展启用或系统设置无法自动验证，要在交付说明中明确剩余的手工验证项。

## 修改约定

- 保持改动局部，优先复用现有类型和错误模型；不要在 UI 中复制解码逻辑。
- 用户可见文案当前为简体中文，新增文案保持一致，并区分 `completed`、`partiallyCompleted`、`completedWithWarning`、`failed`。
- 保持源文件策略在界面、通知、README 和实现中一致，尤其不要把“部分解密”描述成单文件成功。
- 新增依赖前说明它解决的具体问题，并同时更新 `Package.swift`、lockfile、README 和许可证要求。
- 不修改或提交 `.DS_Store`、`xcuserdata`、`UserInterfaceState.xcuserstate`、本地 DerivedData 或真实日志样本。
- 工作区可能已有用户改动。先看 `git status`，不要还原与任务无关的修改。
- Python 脚本与 Swift 行为冲突时以 Swift 测试为准；只有任务明确涉及脚本时才同步修改它们。

## 完成检查

提交结果前确认：

1. 核心行为有对应成功、失败和边界测试。
2. `swift test` 通过，或已准确记录无法运行的原因。
3. 没有泄露密钥、日志正文或扩大的文件权限。
4. 源文件删除和 ZIP 保留策略没有回归。
5. App 与 Finder 的规则、App Group 和用户文案保持同步。
6. 架构或使用方式变化时已更新 `README.md` 和本文件。
