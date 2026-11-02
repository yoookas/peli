# Peli

[usememos/memos](https://github.com/usememos/memos) 的 Android 客户端（`peli.lcyk.cc`）。

**主界面就是官方 Web 前端本身**：内嵌 WebView 加载你自己的实例，因此界面与官方 100% 一致
（地图、统计热力图、评论、反应、Views、Inbox 等全部功能直接可用，无需逐个复刻）。
Flutter / 原生侧只做官方网页**做不到**的事 —— 也就是本文档的主体：本地化功能。

| | |
|---|---|
| 服务端 | memos **0.31.0 及以上**，含 **26.10+**（两代 REST 路由自动适配 + Personal Access Token） |
| 平台 | Android（minSdk 24 / targetSdk 36，edge-to-edge） |
| 架构 | **只发布 arm64-v8a**（2019 年后的设备；配置与原因见 `app/android/gradle.properties`） |
| 工具链 | Flutter 3.44.9 / Dart 3.12.2 / NDK 28.2.13676358 |

---

## 1. 界面构成

| 界面 | 由谁渲染 | 说明 |
|---|---|---|
| 主界面 `/` | **官方 Web 前端**（WebView） | 全屏无外壳：没有标题栏、模式切换、悬浮按钮 |
| 首次配置 `/setup` | 原生 Flutter | 实例地址 + 用户名 + 密码，仅未登录时出现 |
| 启动 / 失败态 | 原生 Flutter | 读取凭据的进度；安全存储不可用时给出明确失败提示 |

---

## 2. 本地化功能清单

### 2.1 会话与凭据（免登录）

| 功能 | 做法 |
|---|---|
| 原生登录 | 填实例地址 + 用户名 + 密码 → `SignIn` → 立刻 `CreatePersonalAccessToken` 换取**长效 PAT**（26.10 起短效令牌只有 15 分钟且与账号密码哈希绑定，退回短期 token 等于必然掉线，因此失败会打 `[auth]` 日志） |
| 路由适配 | 0.31.x 的 REST 前缀是 `/api/v1`，26.10 起改为 `/api`（旧路径返回 **410 Gone**）。首次请求自动探测并缓存前缀，两代服务端都能登录 |
| 版本守门 | 登录时读实例 profile，版本 `< 0.31.0` 直接拒绝并说明原因 |
| 凭据自检 | 冷启动时用 `GET /api/auth/me` 校验最近账号的 PAT：**只有服务端明确 401** 才回登录页重新签发，断网/超时一律放行（否则一次断网就把人踢下线） |
| 凭据落盘 | 实例地址与 PAT 存进**平台安全存储**的单个条目（`accounts.v1`）；Android 上由 Keystore 包裹的 AES-GCM 加密，冷启动只读这一条 |
| 免登录注入 | 页面脚本执行前**覆写 `localStorage`** 的 `getItem`/`setItem`/`removeItem`：`getItem` 返回内存副本，`setItem` 直接丢弃 → 前端无感拿到明文，**磁盘上没有明文令牌** |
| 过期时间 | 故意写成 100 年后。PAT 默认永不过期；若让它"看起来过期"，前端会走 HttpOnly cookie 刷新流程，而 WebView 里没有 cookie，会 401 跳登录页 |
| 多实例 | 多个实例/账号并存，按 `last_used_at` **自动恢复上次使用的账号**；登录页列出已保存实例可一键切换 |
| 自检 | 每次注入后用**覆写前存下的原生方法**直读磁盘校验，输出 `SECURITY diskToken=none memToken=true frontendSees=ok` |

### 2.2 附件图片：能显示、不重复下载、不落明文

官方前端有两条独立鉴权通道：Connect RPC 走 `Authorization: Bearer`，而附件字节
（`/file/...`）走的是**元素自身发起的请求** —— 浏览器不会给 `<img>` 附自定义请求头，
该端点又只认 Bearer 头或服务端签发的 refresh-token cookie，WebView 里两者都没有，
于是"正文能显示、图片全碎"。

| 功能 | 做法 |
|---|---|
| 取字节 | 同源 `fetch` 带 Bearer 取回字节 → 换成 blob URL 赋给 `<img>` |
| 消掉注定失败的请求 | 在元素发请求**之前**摘掉 `src`，字节到手再赋值（否则每张图要发两次请求） |
| 跨页面缓存 | 字节以 **AES-GCM 密文**存进 IndexedDB（`{data: base64, v: 1}`），跨页面加载命中时零网络；缓存键含 `?thumbnail=true` 等查询串 |
| 密钥分离 | 图片密钥是 Keystore 保护的条目，**只经内存**交给页面（`window.__memosImageKey`），密文与密钥分开放 |
| 滚动性能 | 已解密 Blob 进内存 LRU（24 张），滚动零开销；解密只在首次显示发生 |
| 不进 HTTP 缓存 | 取字节时 `cache: 'no-store'`，避免明文图片落进 Chromium 的 HTTP 磁盘缓存 |
| 常驻接管 | `MutationObserver` 监听插入与 `src` 属性变化，React 复用节点也能重新接管；`navigator.storage.persist()` 申请持久化配额 |
| 降级策略 | WebView 过旧、没有 `crypto.subtle` 时**不缓存**（而不是退回明文缓存） |

### 2.3 附件视频 / 音频：原生流式播放

`<video src="/file/...">` 与 `<img>` 同病：元素请求带不上凭据，私有附件必然 401。
旧方案是"整段下载完再换 blob URL"，代价是**必须下完才出声**、网格里一进页面就全量下载。

| 功能 | 做法 |
|---|---|
| 流式代理 | Dart 侧在 `127.0.0.1` 起一个 HTTP 代理，JS 把 `src`/`poster` 重写成 `http://127.0.0.1:<port>/mp-<secret>/file/...`；代理补 `Authorization: Bearer` 后转发 |
| 边下边播 | 代理透传 `Range`/`If-Range` 与 `206`/`Content-Range`/`Accept-Ranges`，字节即到即转（不攒缓冲）→ 交给 Chromium 媒体引擎，**首帧只需元数据 + 首段缓冲**，进度条可拖动 |
| 恢复 preload 语义 | 请求由元素自己发起，`preload="none"`/`metadata` 重新生效，不再一进页面偷跑流量 |
| 封面抓帧 | 元素挂 `crossOrigin="anonymous"`，代理返回 `Access-Control-Allow-*` 并处理 OPTIONS 预检 → 官方 `VideoPoster` 的 canvas 抓首帧不被跨域污染 |
| 安全边界 | 只绑回环地址、路径必须带每次启动随机的前缀、只放行 `/file/` 开头（防止被当成访问其它接口的跳板）、PAT 只发给用户自己的实例 |
| 不落明文 | 服务端的 `Cache-Control: private, no-store` 原样透传，明文视频不进 Chromium 磁盘缓存 |
| 兜底 | 若某种 WebView 策略仍拦下回环请求（加载前 `error` 且 `readyState === 0`），对该元素**一次性退回**旧的整段下载路径 —— 最差回到旧体验，不会播不了 |

### 2.4 文件进入应用

| 功能 | 做法 |
|---|---|
| 接管 `<input type="file">` | 相册 / 拍照（`image_picker`）与任意文件（`file_picker`）两条路，按 `accept` 与 `multiple` 自动分流 |
| 交付用 `content://` | 文件先复制到 `getCacheDir()/webview_uploads/`，经自建 FileProvider 转成 `content://` URI 再交给 WebView —— `file://` 在现代 WebView 上默认不可跨进程访问 |
| 系统分享（单张 / 多张） | `ACTION_SEND` / `ACTION_SEND_MULTIPLE` → 复制到缓存 → 读成字节 → base64 注入页面 → 用 `DataTransfer` 构造 `File` 写入 `<input type="file">.files` 并派发 `change`，前端走完整上传流程；编辑器没打开时挂 `MutationObserver` 等输入框出现 |
| 保留原始文件名 | 缓存文件名带时间戳前缀防重名，但上传时用**原始文件名**（服务端会校验） |
| 媒体权限 | 读取分享进来的图片需要 `READ_MEDIA_IMAGES`（Android 13+）/ `READ_EXTERNAL_STORAGE`；缺权限时申请一次并自动重试，避免"分享进来了但文件是空的" |

### 2.5 WebView 与系统集成

| 功能 | 做法 |
|---|---|
| 返回键 | 网页历史优先，已经在网页首页时再按一次才退出应用 |
| 全面屏 | `SystemUiMode.edgeToEdge` + SafeArea；内容延伸到状态栏/手势条，`layoutInDisplayCutoutMode=shortEdges` 覆盖部分 OEM 的运行期重置 |
| 系统栏配色 | 读页面的 `<html data-theme>`，同步状态栏/导航栏图标明暗 |
| 定位与麦克风 | 网页的 `geolocation` 与 `getUserMedia({audio})` 都要过**内外两道**关卡：系统运行时权限（实时检查、按需申请）+ WebChromeClient 放行回调（插件默认 deny） |
| 离线感知 | `connectivity_plus` 监听网络，断网时给出明确的覆盖提示，恢复后自动重载 |
| 明文清理 | 进入后台即清理 `webview_uploads/` 里的明文交付副本（HTTP 缓存侧则靠 `no-store` 从源头挡住，不再事后 clearCache） |
| 页面可观测 | `setOnConsoleMessage` 把网页控制台转发到 logcat（`[page:*]` 前缀）—— 页面内的失败只在这里留痕 |

### 2.6 本地数据：凭据只存一个条目

当前架构下本地只持久化一件事：**实例地址 + 长效 PAT**。界面与业务数据都在官方前端，
因此不需要在本地保存 memo、附件或同步状态。

| 功能 | 做法 |
|---|---|
| 存储位置 | 整份账号列表序列化成 JSON，存进平台安全存储的单个键 `accounts.v1` |
| 加密 | Android 由 Keystore 保护：RSA-OAEP 包裹密钥 + AES-GCM 加密内容，密钥不可导出、不随备份走 |
| 为什么不用数据库 | 只有一行数据，却要在每次冷启动加载 libsqlcipher.so、打开库、读 DEK、解页 —— 这段工作整段压在首帧关键路径上，而额外保护很有限（DEK 本身也在 Keystore 里，同一把根锁）。移除后启动不再加载任何原生库 |
| 写入串行化 | 读-改-写串成一条链，避免 `markAccountUsed` 与登录时的写入互相覆盖 |
| 容错 | 条目缺失或损坏一律视为"未登录"，不会把应用卡在启动阶段 |
| 旧库清理 | 启动时**后台**删除旧版本残留的 `memos.db*` 与 `memos_db_key_v1`（幂等、不 await，绝不阻塞首帧；删不掉就下次再试） |
| 备份策略 | `allowBackup=false`，并在 `data_extraction_rules.xml` 排除云备份/设备迁移（Keystore 密钥不随备份走） |
| 账号记忆 | 记录最后使用时间，冷启动**自动恢复**上次使用的账号；登录页可切换已保存实例 |

### 2.7 视觉与诊断

| 功能 | 做法 |
|---|---|
| 像素级主题 | 官方令牌以 **oklch** 定义，这里按 CSS Color 4 算法精确转 sRGB（oklch → oklab → LMS → 线性 sRGB → gamma），不做"目测近似"；圆角、字号、控件尺寸按官方值装配 Material 3 主题 |
| 无白闪 | WebView 背景色取当前主题令牌，冷启动不闪白 |
| 隐藏诊断入口 | **长按顶部状态栏区域 3 秒**把页面状态写进 logcat（主题、图片加载数、`mediaProxy=on/off`、`videosProxied=N`、令牌是否只在内存） |
| 启动打点 | `[bootstrap]` 与 `[perf] boot` 逐阶段计时，可定位"卡在哪一步" |
| 启动兜底 | 启动链路每一步都有超时，把"静默挂起"变成明确的失败提示 |

---

## 3. 本地数据保护范围（如实说明）

"不动官方前端"是硬约束，因此保护范围由**哪些存储由本应用读写、哪些由前端读写**决定。

| 数据 | 处理 |
|---|---|
| 登录令牌 | 明文**永不落盘**（`localStorage` 覆写，`setItem` 丢弃）；磁盘上只有平台安全存储里的密文 |
| 图片缓存 | AES-GCM 密文存 IndexedDB；密钥由 Keystore 保护、只经内存交给页面 |
| 附件视频 | 不落盘（服务端 `no-store` 原样透传）；兜底路径只放内存 |
| 文件交付临时文件 | 位于应用缓存目录，**进入后台即清理** |
| Chromium HTTP 缓存 | 靠 `cache: 'no-store'` 从源头阻止明文进盘 |
| 编辑器草稿 | ⚠️ 仍为明文：官方 `cacheService.loadDraft()` 是**同步 API**，不改前端无法包成异步解密 |
| 截屏 / 最近任务预览 | 未设 `FLAG_SECURE`（允许截图）。它不影响磁盘上的任何字节，代价是预览含明文内容 |

---

## 4. 测试与验证

```bash
cd packages/memos_api && dart test         # 10 项：登录请求构造 / PAT 换取 / 版本守门 / 错误映射
cd app                && flutter test      # 37 项：主题令牌 / 启动绑定 / 加密与密钥 / 媒体流式代理
```

真机集成测试（一次只跑一个文件）：

```bash
cd app
flutter test integration_test/encryption_e2e_test.dart -d <deviceId>  # 2 项：设备上落盘为密文 + 密钥稳定可读
flutter test integration_test/key_loss_test.dart       -d <deviceId>  # 1 项：密钥丢失时拒绝启动且不破坏数据
flutter test integration_test/bootstrap_probe_test.dart -d <deviceId> # 启动链路分步计时
flutter test integration_test/edge_to_edge_test.dart   -d <deviceId>  # 2 项：全面屏内边距
```

发布产物静态校验（无需真机）：

```bash
cd app && dart run tool/verify_apk_encryption.dart build/app/outputs/flutter-apk/app-release.apk
# 检查包内确实带 flutter_secure_storage、已彻底移除 libsqlcipher.so 与 sqflite 依赖、
# 原生库以 STORED 方式打包且 ELF 段对齐 ≥ 16 KB、asset 里没有明文数据库文件
```

`flutter analyze`（app）与 `dart analyze`（memos_api）均无告警。

---

## 5. 构建与安装

```bash
cd app
flutter pub get
flutter build apk --release     # 产物：build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

发布签名从 `app/android/key.properties` 读取（缺失时回退 debug 签名）：

```properties
storePassword=...
keyPassword=...
keyAlias=peli
storeFile=peli-release.jks
```

> `storeFile` 是**相对 `app/android/app/` 的路径**，且必须指向真实存在的库：把库改名或
> 删除后忘了同步这里，构建会直接失败（`null cannot be cast to non-null type kotlin.String`
> 或找不到 keystore）。

> **本地日常开发只需要 debug 包**：`flutter build apk --debug`（或 `flutter run`）不碰发布
> 签名，`key.properties` 里口令对不对都不影响它。
> release 包优先由 CI 产出（打 tag）；本地要出 release 包则必须把口令填对 —— 口令不符时
> 会**直接构建失败**，这是刻意的：宁可失败，也不要静默产出一个 debug 签名的"release"包。
>
> 另外注意：debug 包与 release 包**签名不同**，两者无法互相覆盖安装
> （`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），换签名安装前要先卸载。

> 产物只包含 **arm64-v8a** 的原生库。`flutter build` 默认会按 `target-platform` 带上
> armeabi-v7a 与 x86_64（并且会**清掉** `build.gradle.kts` 里写的 `abiFilters`），
> 这里用 `disable-abi-filtering=true` 收紧到 arm64；CI 另外显式传
> `--target-platform android-arm64` 并断言产物 ABI，细节见 `app/android/gradle.properties`。

国内网络可先设置镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

### 打 tag 自动发版（GitHub Actions）

推一个版本 tag 就会自动：跑测试与静态检查 → 编译 release APK → 校验产物（加密链路 +
签名非 debug）→ 发布到 GitHub Release 并附上 APK。

```bash
git tag v0.1.0
git push origin v0.1.0        # 触发 .github/workflows/release.yml
```

也可以在 Actions 页面手动触发（`workflow_dispatch`），便于首次验证流水线。

版本号映射：tag `v1.2.3` → `versionName=1.2.3`，`versionCode` 用 workflow 的 run number
（单调递增，覆盖安装不会被系统拒绝）。

**首次使用需要在仓库里配置 4 个 secrets**（签名材料刻意不进仓库，
`key.properties` 与 `*.jks` 都在 `.gitignore` 里）。缺任何一个，流水线会**明确报错退出**，
而不是静默产出 debug 签名的包：

| Secret | 内容 |
|---|---|
| `KEYSTORE_BASE64` | 发布签名库 `app/android/app/peli-release.jks` 的 base64 |
| `KEYSTORE_PASSWORD` | `key.properties` 里的 `storePassword` |
| `KEY_ALIAS` | `keyAlias`（当前是 `peli`） |
| `KEY_PASSWORD` | `keyPassword` |

生成 `KEYSTORE_BASE64`（注意用**单行**输出，不要换行）：

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('app/android/app/peli-release.jks'))
```

```bash
# Linux / macOS
base64 -w0 app/android/app/peli-release.jks
```

配置位置：仓库 Settings → Secrets and variables → Actions → New repository secret。

> ⚠️ **本地与 CI 必须使用同一把签名库**：本地构建读 `app/android/key.properties`，
> CI 从 secrets 还原。两边不是同一把钥匙时，本地包与 CI 包**互相无法覆盖安装**
> （`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），用户只能卸载重装。

> 换了签名库或口令时记得同步更新 secrets。发版时**不需要**为了改版本号去动
> `pubspec.yaml`：CI 用 tag 覆盖 `versionName`，用 run number 覆盖 `versionCode`；
> `pubspec.yaml` 里的 `version:` 只影响本地构建。

### MIUI / HyperOS 设备侧要求

| 现象 | 需要打开 |
|---|---|
| `adb devices` 看不到设备 | USB 调试 |
| `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED` | USB 安装（会被系统定期收回） |
| `adb shell input` 报 `INJECT_EVENTS` | 无法远程注入触摸，界面操作需手动 |

> 排查提示：`adb shell screencap` 对含 WebView 的窗口会返回空白帧，这不是应用白屏；
> 取证请用隐藏诊断入口 + `adb logcat -s flutter`。

---

## 6. 目录结构

```
memos_flutter/                     # Dart workspace（pubspec.yaml 声明两个成员包）
├── packages/
│   └── memos_api/                 纯 Dart：登录 / 换 PAT / 实例版本所需的 API 客户端
└── app/
    ├── lib/
    │   ├── data/local/            平台安全存储：账号条目与会话机密（图片缓存密钥）
    │   ├── features/
    │   │   ├── web/               主界面外壳：令牌注入、图片加密缓存、媒体流式代理、文件选择、分享
    │   │   └── auth/              首次配置（实例地址 + 账号密码 → 长效 PAT）
    │   ├── state/providers.dart   启动流程与 Riverpod 装配
    │   └── ui/tokens/             官方 oklch 令牌 + 精确色空间转换
    ├── android/app/src/main/kotlin/.../MainActivity.kt   分享接收、content:// 转换、运行时权限
    ├── integration_test/          真机验证
    └── tool/verify_apk_encryption.dart
```

---

## 7. 已知缺口

| 缺口 | 说明 |
|---|---|
| 编辑器草稿 | 官方前端的草稿缓存是**同步 API**，无法包成异步解密，因此草稿仍是明文（见 §3） |
| 无法在应用内退出登录 / 移除实例 | 没有设置界面也没有对应手势；只能清除应用数据（会一并清掉密钥与已保存实例） |
| 主界面必须联网 | 界面由官方前端渲染，断网时只有提示；本地没有可离线浏览的数据副本 |
