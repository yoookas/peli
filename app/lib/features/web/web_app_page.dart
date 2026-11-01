import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../data/local/account_store.dart';
import '../../data/local/secret_store.dart';
import '../../state/providers.dart';
import '../../ui/tokens/memos_tokens.dart';
import 'media_proxy.dart';

/// 应用主界面 —— 就是官方 Web 前端本身。
///
/// Flutter 侧没有任何可见外壳（没有标题栏、模式切换、悬浮按钮），只做几件
/// 用户看不见的事：
/// 1. **注入登录凭据**（免登录）
/// 2. **修补附件图片**（`<img>` 带不上 Authorization 头，且服务端禁止缓存）
/// 3. **代理附件视频**（回环流式代理补凭据，`<video>` 边下边播，见 `MediaStreamProxy`）
/// 4. **接管文件选择**（Android WebView 不会自己处理 `<input type="file">`）
/// 5. **接收系统分享**（把分享的图片注入编辑器，与手动选文件行为一致）
/// 6. 让系统返回键优先走网页历史
class WebAppPage extends ConsumerStatefulWidget {
  const WebAppPage({super.key});

  @override
  ConsumerState<WebAppPage> createState() => WebAppPageState();
}

class WebAppPageState extends ConsumerState<WebAppPage> with WidgetsBindingObserver {
  WebViewController? _controller;

  /// 供外壳做返回键判断。
  WebViewController? get controller => _controller;

  /// 附件视频的回环流式代理（`<video>` 带不上 Authorization 头，见其文档）。
  ///
  /// 随页面状态同生命周期：`_boot` 里启动、`dispose` 里关闭。启动失败不致命 ——
  /// JS 侧拿不到 `window.__memosMediaProxy` 时自动退回"整段下载 → blob"路径。
  final MediaStreamProxy _mediaProxy = MediaStreamProxy();

  bool _loading = true;
  String? _error;
  bool _offline = false;

  /// 页面开始加载的时刻（仅用于性能打点）。
  DateTime? _pageStartedAt;

  /// 与原生（`MainActivity.kt`）的通道：分享接收 + 路径转 content URI。
  static const MethodChannel _shareChannel = MethodChannel('app.memos/share');


  /// 待注入页面的分享文件（字节形式）。
  ///
  /// 为什么存字节而不是路径：见 [_AttachmentImagePatcher.buildShareInjectionScript]。
  List<Map<String, Object?>> _pendingShareFiles = const <Map<String, Object?>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 控制器必须**同步**创建，让首帧就能插入 WebViewWidget。
    // 之前用 addPostFrameCallback 延迟创建，首帧渲染空占位、下一帧才插入 WebView，
    // 导致平台视图生命周期错乱（日志报 `attempted to call on a destroyed WebView`），
    // 界面卡在加载指示器上。
    _boot();
    _watchConnectivity();
    _listenForShares();
  }

  @override
  void dispose() {
    _shareChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _mediaProxy.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // WebView 的暂停/恢复由平台侧跟随 Activity 自动处理（插件未暴露 pause/resume）。
    if (state == AppLifecycleState.resumed) {
      final AccountRecord? account = ref.read(activeAccountProvider);
      if (account == null) return;
      unawaited(_injectSessionSecrets(account));
      _scheduleImagePatching();
      return;
    }
    // 进入后台即清理**明文**缓存。
    //
    // 为什么要清理：
    // - Chromium 的 HTTP 磁盘缓存会把图片以**明文**存下来 —— 那是加密覆盖不到的
    //   一条路（我们加密的是自己的 IndexedDB 缓存，管不到它）；
    // - 文件选择交付用的 `webview_uploads/` 里是**明文**副本。
    //
    // 这样做安全但会牺牲一部分离线体验：回到前台后图片需要重新下载。
    // 这是刻意的取舍 —— 需求明确要求"其余缓存清理"。
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_purgePlaintextCaches());
    }
  }

  /// 清理一切以明文形式落盘的缓存。
  ///
  /// 两类目标：
  /// 1. `webview_uploads/`：文件选择交付给渲染进程的**明文副本**（整个目录清空）；
  /// 2. 缓存目录根下的 `shared_*`：系统分享进来、由跳板/主界面复制的**明文图片**
  ///    （前缀须与 Kotlin 侧 `ShareFiles.PREFIX` 一致）。
  ///
  /// 为什么分享副本也要清：Dart 在"排队给编辑器"时就把字节读进内存了，文件之后
  /// 不再需要；留着只会在磁盘上多一份明文媒体，与"本地不残留明文"的策略冲突。
  ///
  /// **不调用 clearCache()**：明文图片/视频已被 `cache: 'no-store'` 挡在 HTTP 缓存
  /// 之外，所以不存在"事后要清"的东西；而清空整个 HTTP 缓存会把前端 bundle 一起
  /// 清掉，导致每次回前台都要重下整个 SPA（实测冷缓存下 HTML 就 3.9 秒）。
  /// 用户数据（API 响应）的缓存由官方前端自己管理，不归我们动。
  Future<void> _purgePlaintextCaches() async {
    int removed = 0;

    // 1) 文件选择的交付目录：整目录清空。
    try {
      final Directory dir = await _webviewUploadDir();
      if (await dir.exists()) {
        await for (final FileSystemEntity entity in dir.list()) {
          try {
            await entity.delete(recursive: true);
            removed++;
          } catch (_) {
            // 单个文件删不掉就跳过
          }
        }
      }
    } catch (_) {
      // 目录不可用时忽略
    }

    // 2) 分享进来的明文副本：只认 `shared_` 前缀，别动引擎/插件的缓存文件。
    try {
      final Directory cache = await getApplicationCacheDirectory();
      removed += await purgeSharedFiles(cache);
    } catch (_) {
      // 同上
    }

    // ignore: avoid_print
    print('[perf] purge plaintext caches: removed $removed file(s) at ${DateTime.now().toIso8601String()}');
  }

  // ---------------------------------------------------------------------------
  // 系统分享
  // ---------------------------------------------------------------------------

  void _listenForShares() {
    _shareChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onShared') return;
      await _acceptShare(call.arguments);
    });
    unawaited(_consumeInitialShare());
  }

  Future<void> _consumeInitialShare() async {
    try {
      final Object? payload = await _shareChannel.invokeMethod<Object?>('getInitialShare');
      await _acceptShare(payload);
    } catch (_) {
      // 非 Android 或通道不可用：忽略。
    }
  }

  /// 处理分享进来的图片：把**字节**注入页面，让前端像处理手动选中的文件一样处理它。
  ///
  /// ## 为什么注入字节而不是路径
  ///
  /// 给 `<input type="file">` 赋 `files` 在浏览器里是禁止的，但用 `DataTransfer`
  /// 构造 `File` 是允许的。而字节已经在 JS 内存里，**渲染进程根本不需要读磁盘** ——
  /// 彻底绕开 `file://` / `content://` 的跨进程访问问题。
  ///
  /// ## 与手动选文件行为一致
  ///
  /// 图片进入编辑器的**附件列表**，由前端自己上传、自己插入正文引用。
  /// 这样就统一了两条入口的行为（手动选文件 / 系统分享）。
  ///
  /// ## 用户操作
  ///
  /// **分享后打开编辑器即可，不需要再点「+」**：官方 `InsertMenu` 里那两个
  /// `<input type="file">`（`className="hidden"`）是**随编辑器一起挂载**的，注入脚本挂的
  /// MutationObserver 会在它们出现时自动把文件交给输入框（不弹系统选择器）。
  ///
  /// 因此这里**不弹任何提示**：用户能看到的反馈就是附件出现在编辑器里 ——
  /// 之前那条"打开编辑器后点「+」"的 SnackBar 既不必要，也与实际交互不符。
  Future<void> _acceptShare(Object? payload) async {
    if (payload is! Map) return;
    final List<String> paths = <String>[
      for (final Object? item in (payload['paths'] as List<Object?>? ?? <Object?>[]))
        if (item is String) item,
    ];
    final List<String> names = <String>[
      for (final Object? item in (payload['names'] as List<Object?>? ?? <Object?>[]))
        if (item is String) item,
    ];
    if (paths.isEmpty || !mounted) return;

    final List<Map<String, Object?>> files = <Map<String, Object?>>[];
    for (int i = 0; i < paths.length; i++) {
      try {
        final File file = File(paths[i]);
        if (!await file.exists()) continue;
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final String name =
            i < names.length && names[i].isNotEmpty ? names[i] : p.basename(paths[i]);
        files.add(<String, Object?>{
          'name': name,
          'mimeType': guessMimeType(name),
          'base64': base64Encode(bytes),
        });
      } catch (error) {
        // ignore: avoid_print
        print('[share] read failed for ${paths[i]}: $error');
      }
    }
    if (files.isEmpty) return;

    _pendingShareFiles = files;
    // ignore: avoid_print
    print('[share] queued ${files.length} file(s) for the editor');
    // 编辑器已打开时立刻生效；否则等输入框随编辑器挂载时注入。
    await _injectPendingShareIntoPage();
  }

  Future<void> _injectPendingShareIntoPage() async {
    final WebViewController? controller = _controller;
    if (controller == null || _pendingShareFiles.isEmpty) return;
    // 注入完就清空，避免重复注入同一张图。
    final List<Map<String, Object?>> files = _pendingShareFiles;
    _pendingShareFiles = const <Map<String, Object?>>[];
    try {
      await controller.runJavaScript(
        _AttachmentImagePatcher.buildShareInjectionScript(files),
      );
    } catch (error) {
      // ignore: avoid_print
      print('[share] inject failed: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // 启动与凭据
  // ---------------------------------------------------------------------------

  void _watchConnectivity() {
    Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final bool offline =
          results.isEmpty || results.every((ConnectivityResult r) => r == ConnectivityResult.none);
      if (!mounted) return;
      setState(() => _offline = offline);
      if (!offline) {
        setState(() {
          _loading = true;
          _error = null;
        });
        _controller?.reload();
      }
    });
  }

  Future<void> _boot() async {
    final Stopwatch sw = Stopwatch()..start();
    void mark(String label) {
      // ignore: avoid_print
      print('[perf] boot $label @${sw.elapsedMilliseconds}ms');
    }
    mark('enter');
    final AccountRecord? account = ref.read(activeAccountProvider);
    if (account == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '尚未配置实例';
        });
      }
      return;
    }

    // 媒体流式代理：必须在页面加载**之前**就绪，JS 补丁注入时才拿得到地址。
    // 失败不致命 —— JS 侧会自动退回"整段下载 → blob"的旧路径。
    try {
      await _mediaProxy.start();
      _configureMediaProxy(account);
      mark('mediaProxyReady');
    } catch (error) {
      // ignore: avoid_print
      print('[media-proxy] start failed: $error');
    }

    mark('beforeController');
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(context.tokens.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          // onPageStarted 在首帧前触发 —— 令牌必须在这时写入
          onPageStarted: (String url) {
            _pageStartedAt = DateTime.now();
            // ignore: avoid_print
            print('[perf] onPageStarted $url');
            _injectSessionSecrets(account);
          },
          onPageFinished: (String url) {
            final int ms = _pageStartedAt == null
                ? -1
                : DateTime.now().difference(_pageStartedAt!).inMilliseconds;
            // ignore: avoid_print
            print('[perf] onPageFinished in ${ms}ms $url');
            if (mounted) setState(() => _loading = false);
            _injectSessionSecrets(account);
            _scheduleImagePatching();
            _syncSystemBarsWithPage();
            // 页面重建后若还有待注入的分享，补一次
            unawaited(_injectPendingShareIntoPage());
          },
          onWebResourceError: (WebResourceError error) {
            if (!mounted) return;
            // 只有主文档失败才算错误；子资源失败不该整页报错。
            if (error.isForMainFrame != true) return;
            setState(() {
              _loading = false;
              _error = '页面加载失败：${error.description}';
            });
          },
        ),
      )
      // 页面控制台转发：文件选择/分享注入的失败只会在页面里留痕，
      // logcat 默认看不到，这是唯一可观测的窗口。
      ..setOnConsoleMessage((JavaScriptConsoleMessage message) {
        final String text = message.message;
        if (text.contains('[memos]') || message.level == JavaScriptLogLevel.error) {
          // ignore: avoid_print
          print('[page:${message.level.name}] $text');
        }
      });

    mark('beforeFileSelector');
    await _installFileSelector(controller);
    mark('afterFileSelector');

    // 定位与麦克风：WebView 的**内层**放行。
    await _installPermissionHandlers(controller);
    mark('afterPermissionHandlers');

    // 会话机密通道：页面需要密钥来解密图片缓存。
    //
    // 密钥由 `SessionSecrets`（Keystore 保护的条目）生成/读取，**只在内存里**交给
    // 页面 —— 密文与密钥放在同一个地方等于没加密。
    await controller.addJavaScriptChannel(
      'MemosSecurity',
      onMessageReceived: (JavaScriptMessage message) async {
        try {
          final String base64Key = await _imageCacheKeyBase64(account);
          await controller.runJavaScript(
            'window.__memosImageKey = ${jsonEncode(base64Key)};',
          );
        } catch (error) {
          // ignore: avoid_print
          print('[security] image key delivery failed: $error');
        }
      },
    );

    mark('beforeLoadRequest');
    controller.loadRequest(Uri.parse(account.baseUrl));
    _controller = controller;
    mark('afterLoadRequest');
  }

  /// 图片缓存密钥的 base64（懒加载并缓存，避免重复读安全存储）。
  String? _cachedImageKey;

  Future<String> _imageCacheKeyBase64(AccountRecord account) async {
    final String? cached = _cachedImageKey;
    if (cached != null) return cached;
    final String key = await SessionSecrets(accountId: account.id).imageCacheKeyBase64();
    _cachedImageKey = key;
    return key;
  }

  /// 把媒体代理指向当前账号的实例与令牌（幂等，可随会话注入重复调用）。
  void _configureMediaProxy(AccountRecord account) {
    final Uri? upstream = Uri.tryParse(account.baseUrl);
    if (upstream == null || upstream.host.isEmpty) return;
    _mediaProxy.configure(upstream: upstream, token: account.accessToken);
  }

  /// 把会话机密以**内存覆写**的方式交给页面（令牌 + 图片缓存密钥）。
  ///
  /// ## 为什么不直接 `localStorage.setItem`（曾经的做法）
  ///
  /// 直接把令牌写进 `localStorage` 意味着**磁盘上有明文令牌** —— 拿到设备的人
  /// 可以读出来，等价于拿到完整账号。而我们同时又把同一个令牌加密存进了
  /// 平台安全存储，等于同一个机密在磁盘上有明文和密文两份，加密形同虚设。
  ///
  /// ## 现在的做法
  ///
  /// 覆写 `localStorage` 的两个方法，让前端**完全无感**地拿到明文：
  ///
  /// ```js
  /// getItem('memos_access_token')     → 返回内存里的明文
  /// setItem('memos_access_token', …)  → 丢弃（永不落盘）
  /// removeItem('memos_access_token')  → 清空内存副本
  /// ```
  ///
  /// 依据官方 `web/src/auth-state.ts` 的**实际用法**核对过：它只 `getItem` 这两个键，
  /// 不枚举 `localStorage`、不依赖 `storage` 事件，因此覆写对它是透明的。
  ///
  /// 顺带擦掉磁盘上可能残留的旧明文（旧版本写过）。
  ///
  /// 结果：明文只存在于进程内存；磁盘上只有 Keystore 保护的密文。
  Future<void> _injectSessionSecrets(AccountRecord account) async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    final String token = account.accessToken;
    if (token.isEmpty) return;

    // 媒体代理始终指向当前账号（切换账号/令牌变化后随本方法一起刷新）。
    _configureMediaProxy(account);
    final String mediaProxyBase = _mediaProxy.baseUrl;

    // 过期时间故意设为 100 年后：PAT 默认永不过期（`expiresInDays: 0`）。
    // 若让它"看起来过期"，前端会走 HttpOnly cookie 刷新流程，
    // 而 WebView 里没有 cookie，会 401 并跳登录页。
    final DateTime farFuture = DateTime.now().toUtc().add(const Duration(days: 36500));
    final String script = '''
(function () {
  try {
    var TOKEN_KEY = 'memos_access_token';
    var EXPIRES_KEY = 'memos_token_expires_at';

    // 先擦掉磁盘上可能残留的旧明文（升级路径）
    try { localStorage.removeItem(TOKEN_KEY); } catch (e) {}
    try { localStorage.removeItem(EXPIRES_KEY); } catch (e) {}

    if (!window.__memosSecretOverride) {
      window.__memosSecretOverride = { mem: {} };
      var mem = window.__memosSecretOverride.mem;
      var raw = window.localStorage;
      var proto = Object.getPrototypeOf(raw) || Storage.prototype;

      // 必须在覆写**之前**把原生方法存起来。
      //
      // 若之后再用 `Storage.prototype.getItem` 去"绕过覆写读磁盘"，会重新进入
      // 我们的覆写 -> 覆写内部再调原生 -> 无限递归（实测触发
      // `RangeError: Maximum call stack size exceeded`，并把 React Router 一起带崩）。
      // 存成 `window.__memosNativeStorage` 之后，自检读的就是**真实磁盘值**。
      window.__memosNativeStorage = {
        getItem: proto.getItem,
        setItem: proto.setItem,
        removeItem: proto.removeItem
      };
      var nativeGet = window.__memosNativeStorage.getItem;
      var nativeSet = window.__memosNativeStorage.setItem;
      var nativeRemove = window.__memosNativeStorage.removeItem;

      proto.getItem = function (key) {
        if (Object.prototype.hasOwnProperty.call(mem, key)) return mem[key];
        return nativeGet.call(this, key);
      };
      proto.setItem = function (key, value) {
        // 机密键**永不落盘**：只留在内存副本里
        if (key === TOKEN_KEY || key === EXPIRES_KEY) {
          mem[key] = String(value);
          return;
        }
        return nativeSet.call(this, key, value);
      };
      proto.removeItem = function (key) {
        if (Object.prototype.hasOwnProperty.call(mem, key)) {
          delete mem[key];
          return;
        }
        return nativeRemove.call(this, key);
      };
      console.log('[memos] session secret override installed');
    }

    // 灌入本次会话的明文（仅内存）
    window.__memosSecretOverride.mem[TOKEN_KEY] = ${jsonEncode(token)};
    window.__memosSecretOverride.mem[EXPIRES_KEY] = ${jsonEncode(farFuture.toIso8601String())};

    // 媒体流式代理地址（含随机前缀，令牌由 Dart 侧在代理内部附加，
    // 页面只见前缀不见 PAT）。空串 = 代理不可用，页面脚本自动退回
    // "整段下载 → blob"路径。
    window.__memosMediaProxy = ${jsonEncode(mediaProxyBase)};

    // 自检：用**存下来的原生方法**读真实磁盘值。
    // 若这里报出明文，说明覆写没生效 —— 必须立刻可见，而不是被掩盖。
    var diskToken = null;
    try {
      var native = window.__memosNativeStorage;
      diskToken = native.getItem.call(localStorage, TOKEN_KEY);
      var diskExpiry = native.getItem.call(localStorage, EXPIRES_KEY);
      if (diskExpiry) diskToken = (diskToken || '') + '|expiry';
    } catch (e) {
      diskToken = 'probe-error';
    }

    console.log('[memos] SECURITY diskToken=' + (diskToken ? String(diskToken).slice(0, 24) : 'none') +
      ' memToken=' + !!(window.__memosSecretOverride.mem[TOKEN_KEY]) +
      ' frontendSees=' + (localStorage.getItem(TOKEN_KEY) ? 'ok' : 'EMPTY!!'));
    return 'ok';
  } catch (e) {
    return 'error:' + e;
  }
})();
''';
    try {
      await controller.runJavaScriptReturningResult(script);
    } catch (_) {
      // 注入失败不阻塞浏览：用户可在网页内手动登录一次。
    }
  }

  /// 同步状态栏/导航栏图标明暗（官方用 `<html data-theme="...">` 切主题）。
  Future<void> _syncSystemBarsWithPage() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      final Object result = await controller.runJavaScriptReturningResult(
        "document.documentElement.getAttribute('data-theme') || ''",
      );
      final String theme = result.toString().replaceAll('"', '');
      final bool dark = theme.contains('dark');
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
          systemStatusBarContrastEnforced: false,
        ),
      );
    } catch (_) {
      // 读不到就保持当前样式。
    }
  }

  // ---------------------------------------------------------------------------
  // 文件选择
  // ---------------------------------------------------------------------------

  /// 接管网页的文件选择请求（官方编辑器的「上传附件 / 插入图片 / 拍照」都走它）。
  ///
  /// ## 交付方式：`content://` 而不是 `file://`
  ///
  /// 选择结果要交给 Chromium 的**沙箱渲染进程**读取，而 `file://` 在现代 WebView
  /// 上默认不可跨进程访问（`setAllowFileAccess` 对 targetSdk 30+ 默认为 false），
  /// 必须走 Android 为跨进程文件访问设计的 `content://`（FileProvider）。
  ///
  /// 三段式：
  /// ```
  /// 系统选择器选中的文件
  ///   → 复制到 getCacheDir()/webview_uploads/   （FileProvider 声明了这个目录）
  ///   → 经本应用自建 FileProvider 生成 content:// URI
  ///   → 交给 WebView 渲染进程
  /// ```
  ///
  /// ⚠️ 目录必须是 `getCacheDir()` 下的 `webview_uploads/`：
  /// `res/xml/webview_file_paths.xml` 声明的是 `<cache-path path="webview_uploads/"/>`，
  /// 它对应 `getCacheDir()`，**不包含** `getCodeCacheDir()`（`code_cache`）。
  /// 放错目录时 `FileProvider.getUriForFile` 会抛 `IllegalArgumentException`。
  Future<void> _installFileSelector(WebViewController controller) async {
    if (controller.platform is! AndroidWebViewController) return;
    final AndroidWebViewController android = controller.platform as AndroidWebViewController;

    await android.setOnShowFileSelector((FileSelectorParams params) async {
      final bool wantsImage =
          params.acceptTypes.any((String type) => type.startsWith('image/'));
      final bool multiple = params.mode == FileSelectorMode.openMultiple;

      final List<String> staged = <String>[];

      if (params.isCaptureEnabled && wantsImage) {
        final XFile? shot = await ImagePicker().pickImage(source: ImageSource.camera);
        if (shot != null) {
          final String? path = await _stageFileForWebView(shot.path, p.basename(shot.path));
          if (path != null) staged.add(path);
        }
      } else if (wantsImage && !multiple) {
        final ImageSource? source = await _askImageSource();
        if (source != null) {
          final XFile? file = await ImagePicker().pickImage(source: source, imageQuality: 92);
          if (file != null) {
            final String? path = await _stageFileForWebView(file.path, p.basename(file.path));
            if (path != null) staged.add(path);
          }
        }
      } else {
        final FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: multiple,
          // 不依赖 result.path：Android 上它可能是 content:// URI，
          // 取字节自己落盘才能拿到可控路径。
          withData: true,
        );
        if (result != null) {
          for (final PlatformFile file in result.files) {
            final Uint8List? bytes = file.bytes;
            if (bytes == null) continue;
            final String? path = await _stageUploadBytes(bytes, file.name);
            if (path != null) staged.add(path);
          }
        }
      }

      if (staged.isEmpty) return const <String>[];

      final List<String> uris = await _toContentUris(staged);
      // ignore: avoid_print
      print('[picker] return ${uris.length} content uri(s): $uris');
      return uris;
    });
  }

  // ---------------------------------------------------------------------------
  // 定位与麦克风
  // ---------------------------------------------------------------------------
  //
  // 网页调用 `navigator.geolocation` / `getUserMedia` 时，WebView 有**内外两道**关卡：
  //
  // | 关卡 | 归属 | 不做会怎样 |
  // |---|---|---|
  // | 系统运行时权限 | 本应用（Android 权限模型） | 底层拿不到数据 |
  // | WebView 放行回调 | `WebChromeClient` | **默认拒绝**，网页拿到一个无说明的错误 |
  //
  // 两道都必须过。而且这里**不能**只在启动时申请一次：用户可能在设置里撤销，
  // 也可能首次拒绝后想再给 —— 所以每次网页提出请求时都实时检查系统权限。

  /// 安装网页权限请求的处理回调。
  Future<void> _installPermissionHandlers(WebViewController controller) async {
    if (controller.platform is! AndroidWebViewController) return;
    final AndroidWebViewController android = controller.platform as AndroidWebViewController;

    // ---- 麦克风：getUserMedia({audio:true}) ----
    //
    // 插件默认对 onPermissionRequest 是 **deny**
    //（`AndroidWebViewPermissionRequest` 未注册回调时直接 request.deny()），
    // 所以不接管就完全录不了音 —— 且网页只会收到一个 NotAllowedError。
    await android.setOnPlatformPermissionRequest(
      (PlatformWebViewPermissionRequest request) async {
        final bool wantsAudio =
            request.types.contains(WebViewPermissionResourceType.microphone);
        if (!wantsAudio) {
          // 摄像头等本应用未声明的能力：明确拒绝，而不是含糊放行。
          await request.deny();
          return;
        }
        final bool granted = await _ensureSystemPermission(
          const <String>['android.permission.RECORD_AUDIO'],
          requestCode: 2001,
        );
        // ignore: avoid_print
        print('[perm] getUserMedia audio -> ${granted ? 'grant' : 'deny'}');
        if (granted) {
          await request.grant();
        } else {
          await request.deny();
        }
      },
    );

    // ---- 定位：navigator.geolocation.getCurrentPosition ----
    //
    // 定位走的是另一条通路（GeolocationPermissions，不属于 onPermissionRequest）。
    // 两个都要设：不开 setGeolocationEnabled 则 WebView 层直接禁用；
    // 不设 prompt 回调则永远不授权。
    await android.setGeolocationEnabled(true);
    await android.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (GeolocationPermissionsRequestParams params) async {
        final bool granted = await _ensureSystemPermission(
          const <String>[
            'android.permission.ACCESS_FINE_LOCATION',
            'android.permission.ACCESS_COARSE_LOCATION',
          ],
          requestCode: 2002,
        );
        // ignore: avoid_print
        print('[perm] geolocation ${params.origin} -> ${granted ? 'allow' : 'deny'}');
        // retain=true：记住选择，避免每次取位置都弹一次系统框
        return GeolocationPermissionsResponse(allow: granted, retain: true);
      },
      onHidePrompt: () {
        // 网页取消请求：无需处理（系统权限框已弹出时用户仍可作答）。
      },
    );
  }

  /// 确保一组系统权限已授予；缺哪个就申请哪个。
  ///
  /// 返回**全部**授予才为 true。已授予时不会弹框（原生侧直接短路返回），
  /// 因此可以在每次网页请求时放心调用。
  Future<bool> _ensureSystemPermission(
    List<String> permissions, {
    required int requestCode,
  }) async {
    try {
      final Map<Object?, Object?>? result =
          await _shareChannel.invokeMethod<Map<Object?, Object?>>(
        'requestPermissions',
        <String, Object?>{
          'permissions': permissions,
          'requestCode': requestCode,
        },
      );
      if (result == null || result.isEmpty) return false;
      return result.values.every((Object? granted) => granted == true);
    } catch (error) {
      // ignore: avoid_print
      print('[perm] request failed: $error');
      return false;
    }
  }
  /// 询问图片来源（相册 / 拍照）—— 对应官方 InsertMenu 的两个入口。
  Future<ImageSource?> _askImageSource() async {
    if (!mounted) return null;
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _stageUploadBytes(Uint8List bytes, String name) async {
    try {
      final Directory dir = await _webviewUploadDir();
      final File target = File(
        p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$name'),
      );
      await target.writeAsBytes(bytes, flush: true);
      return target.path;
    } catch (error) {
      // ignore: avoid_print
      print('[picker] stage bytes failed for $name: $error');
      return null;
    }
  }

  Future<String?> _stageFileForWebView(String sourcePath, String name) async {
    try {
      final Directory dir = await _webviewUploadDir();
      if (p.isWithin(dir.path, sourcePath)) return sourcePath;
      final File source = File(sourcePath);
      if (!await source.exists()) {
        // ignore: avoid_print
        print('[picker] source missing: $sourcePath');
        return null;
      }
      final File target = File(
        p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$name'),
      );
      await source.copy(target.path);
      return target.path;
    } catch (error) {
      // ignore: avoid_print
      print('[picker] stage file failed for $sourcePath: $error');
      return null;
    }
  }

  /// 取得（必要时创建）WebView 交付目录。
  ///
  /// 必须是 `getCacheDir()/webview_uploads/`，与 `res/xml/webview_file_paths.xml`
  /// 的 `<cache-path path="webview_uploads/"/>` 对应。
  Future<Directory> _webviewUploadDir() async {
    final Directory base = await getApplicationCacheDirectory();
    final Directory dir = Directory(p.join(base.path, 'webview_uploads'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 让原生侧把文件路径转成 `content://` URI。
  Future<List<String>> _toContentUris(List<String> paths) async {
    try {
      final List<Object?>? result = await _shareChannel.invokeMethod<List<Object?>>(
        'toContentUris',
        <String, Object?>{'paths': paths},
      );
      return <String>[
        for (final Object? item in result ?? const <Object?>[])
          if (item is String) item,
      ];
    } catch (error) {
      // ignore: avoid_print
      print('[picker] toContentUris failed: $error');
      return const <String>[];
    }
  }

  // ---------------------------------------------------------------------------
  // 附件图片修补
  // ---------------------------------------------------------------------------

  void _scheduleImagePatching() {
    unawaited(_patchAttachmentImages());
    for (final int seconds in <int>[1, 3, 8]) {
      Future<void>.delayed(Duration(seconds: seconds), () async {
        if (mounted) await _patchAttachmentImages();
      });
    }
  }

  Future<void> _patchAttachmentImages() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(_AttachmentImagePatcher.script);
    } catch (_) {
      // 修补失败只影响图片显示，不影响其他功能。
    }
  }

  /// 把网页当前状态写进 logcat（隐藏诊断入口：长按状态栏 3 秒）。
  Future<void> dumpPageState() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    const String script = r'''
(function () {
  var list = document.querySelectorAll('img');
  var loaded = 0, broken = 0;
  for (var i = 0; i < list.length; i++) {
    if (list[i].complete && list[i].naturalWidth > 0) loaded++; else broken++;
  }
  // 安全状态：令牌是否只存在于内存覆写层（磁盘上应当没有）
  var diskToken = null;
  try { diskToken = Storage.prototype.getItem.call(localStorage, 'memos_access_token'); } catch (e) {}
  var overrideInstalled = !!(window.__memosSecretOverride && window.__memosSecretOverride.mem);
  var memHasToken = !!(window.__memosSecretOverride &&
    window.__memosSecretOverride.mem['memos_access_token']);

  return 'MEMOS_STATE theme=' + (document.documentElement.getAttribute('data-theme') || 'none') +
    ' imgs=' + list.length + ' loaded=' + loaded + ' broken=' + broken +
    ' fileInputs=' + document.querySelectorAll('input[type=file]').length +
    ' mediaProxy=' + (window.__memosMediaProxy ? 'on' : 'off') +
    ' videosProxied=' + document.querySelectorAll('video[src^="http://127.0.0.1:"]').length +
    ' | SECURITY diskToken=' + (diskToken ? 'PLAINTEXT_ON_DISK!!' : 'none') +
    ' override=' + overrideInstalled +
    ' memToken=' + memHasToken +
    ' imageKey=' + (window.__memosImageKey ? 'set' : 'missing');
})();
''';
    try {
      final Object result = await controller.runJavaScriptReturningResult(script);
      // ignore: avoid_print
      print(result.toString());
    } catch (error) {
      // ignore: avoid_print
      print('MEMOS_STATE error=$error');
    }
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final MemosThemeTokens tokens = context.tokens;

    return Stack(
      children: <Widget>[
        if (_controller != null)
          WebViewWidget(controller: _controller!)
        else
          const SizedBox.shrink(),
        // 加载指示器必须**看得见**：它的颜色不能靠主题默认值（默认色与页面背景
        // 几乎同色，实测白屏期间完全看不到指示器，用户以为卡死了）。
        if (_loading && !_offline)
          ColoredBox(
            color: tokens.background,
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: tokens.mutedForeground,
                ),
              ),
            ),
          ),
        if (_offline || _error != null)
          ColoredBox(
            color: tokens.background,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      _offline ? Icons.cloud_off_outlined : Icons.error_outline,
                      size: 40,
                      color: tokens.mutedForeground,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _offline ? '离线' : '无法加载页面',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _offline ? 'Peli 需要联网才能使用。' : (_error ?? ''),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: MemosTokens.textUi, color: tokens.mutedForeground),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: reload,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 无壳宿主：全屏 WebView + 系统返回键接管。
///
/// 返回键策略（对齐原生应用习惯）：
/// 1. 网页里还有历史 → 后退一页；
/// 2. 已在网页首页 → 再按一次退出应用。
///
/// 不用 `PopScope` 的默认行为：需要"先问网页再决定是否退出"，
/// 而 `PopScope` 只能阻断、不能条件放行。
class WebViewHost extends ConsumerStatefulWidget {
  const WebViewHost({super.key});

  @override
  ConsumerState<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends ConsumerState<WebViewHost> {
  final GlobalKey<WebAppPageState> _pageKey = GlobalKey<WebAppPageState>();

  /// 隐藏诊断入口：长按顶部状态栏区域 3 秒，把页面状态写进 logcat。
  ///
  /// 做成隐藏手势而不是可见按钮，是为了保持"界面与官方完全一致"。
  int? _pressStart;

  void _onLongPressStart() => _pressStart = DateTime.now().millisecondsSinceEpoch;

  void _onLongPressEnd() {
    final int? start = _pressStart;
    _pressStart = null;
    if (start == null) return;
    if (DateTime.now().millisecondsSinceEpoch - start < 2500) return;
    _pageKey.currentState?.dumpPageState();
  }

  Future<bool> _onBack() async {
    final WebViewController? controller = _pageKey.currentState?.controller;
    if (controller == null) return false;
    try {
      if (await controller.canGoBack()) {
        await controller.goBack();
        return true;
      }
    } catch (_) {
      // 交给系统默认行为
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final MemosThemeTokens tokens = context.tokens;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final bool handled = await _onBack();
        if (!handled && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: tokens.background,
        body: Stack(
          children: <Widget>[
            // 顶部让位给状态栏 / 刘海。
            //
            // 官方 `web/index.html` 的 viewport 没有 `viewport-fit=cover`，页面也不用
            // `env(safe-area-inset-*)` —— 它被设计成在浏览器视口里运行，铺到状态栏
            // 下面会让顶栏与通知栏重叠。底部**不**让位：官方自己的底部导航本就贴着
            // 视口底边，延伸到手势条下方才是它设计的观感。
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: WebAppPage(key: _pageKey),
            ),
            // 仅覆盖状态栏高度的透明手势区（视觉上完全不可见）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: (_) => _onLongPressStart(),
                onLongPressEnd: (_) => _onLongPressEnd(),
                onLongPressCancel: () => _pressStart = null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件修补脚本：图片（加密缓存）+ 视频/音频（流式代理重写）+ 分享注入。
///
/// ## 为什么必须修补附件
///
/// 官方前端有**两条独立鉴权通道**：
/// - **Connect RPC**（`/memos.api.v1.*`）→ 走 `Authorization: Bearer`，
///   把 PAT 写进 localStorage 就够了；
/// - **附件字节**（`/file/...`）→ 普通 `<img>/<video> src=...` 请求，
///   **浏览器不会给元素请求附自定义请求头**，而该端点只认 Bearer 头或服务端
///   签发的 refresh-token cookie（`fileserver.go:getCurrentUser`），WebView
///   里两者都没有。
///
/// 于是"正文能显示、图片全碎"。`webview_flutter` 的 `WebResourceResponse` 只暴露
/// `statusCode`（无法从 Dart 注入响应体或改请求头），平台级拦截不可行；
/// 因此用纯 JS：同源 `fetch` 带 Bearer 取字节，换成 blob URL 赋给 `<img>`。
///
/// 视频不能用同一招：整段下载完才能播（见脚本内"视频/音频"部分的注释），
/// 改为把 src 重写到应用内回环代理（`media_proxy.dart`），由代理补凭据、
/// 透传 Range —— 恢复 Chromium 原生的边下边播。
///
/// ## 为什么还要自己缓存
///
/// 实测服务端对附件返回 `Cache-Control: private, no-store`（带不带
/// `?thumbnail=true` 都一样），浏览器/WebView **每次进页面都重新下载**。
/// 因此把字节存进 IndexedDB（二进制友好、跨页面加载持久），命中时零网络。
class _AttachmentImagePatcher {
  const _AttachmentImagePatcher._();

  /// 修补脚本（幂等）：图片走加密缓存，视频/音频重写到流式代理。
  static const String script = r'''
(function () {
  var DB_NAME = 'memos-media-cache';
  var STORE = 'blobs';
  // 视频专用 store：仅用于清理历史明文缓存（视频不写盘：流式代理路径透传
  // 服务端的 no-store，blob 兜底路径只放内存 —— 见下方视频部分）
  var VID_STORE = 'media-videos';
  var MARK = 'data-memos-patched';
  var TOKEN_KEY = 'memos_access_token';

  function token() {
    try { return localStorage.getItem(TOKEN_KEY) || ''; } catch (e) { return ''; }
  }

  function isAttachment(url) {
    return typeof url === 'string' && url.indexOf('/file/') !== -1;
  }

  // 缓存键：同源下同一路径 + 查询（thumbnail/motion 选择器要区分开）。
  function cacheKey(url) {
    try {
      var u = new URL(url, location.href);
      return location.origin + u.pathname + u.search;
    } catch (e) { return url; }
  }

  var dbPromise = null;
  function openDb() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise(function (resolve) {
      var req;
      // 版本 2：新增媒体 store。
      //
      // 注意：视频**不写盘**（见下方视频部分的理由），这个 store 只用于清理
      // 历史版本可能留下的明文缓存。仍必须建出来，否则对它开事务会抛
      // `NotFoundError`。
      try { req = indexedDB.open(DB_NAME, 2); } catch (e) { resolve(null); return; }
      req.onupgradeneeded = function () {
        var db = req.result;
        if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
        if (!db.objectStoreNames.contains(VID_STORE)) db.createObjectStore(VID_STORE);
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { resolve(null); };
    });
    return dbPromise;
  }

  function cacheGet(key) {
    return openDb().then(function (db) {
      if (!db) return null;
      return new Promise(function (resolve) {
        try {
          var tx = db.transaction(STORE, 'readonly');
          var req = tx.objectStore(STORE).get(key);
          req.onsuccess = function () { resolve(req.result || null); };
          req.onerror = function () { resolve(null); };
        } catch (e) { resolve(null); }
      });
    });
  }

  function cachePut(key, blob) {
    return openDb().then(function (db) {
      if (!db) return;
      try {
        var tx = db.transaction(STORE, 'readwrite');
        tx.objectStore(STORE).put(blob, key);
      } catch (e) { /* 配额满或隐私模式：忽略，退化为不缓存 */ }
    });
  }

  // ---------------------------------------------------------------------------
  // 密钥获取（只在内存里，不落 WebView 存储）
  // ---------------------------------------------------------------------------
  //
  // 图片密文存在 IndexedDB，密钥由原生侧从 Keystore 保护的条目读出后注入
  // （`window.__memosImageKey`）。密文与密钥分开放，加密才有意义。
  var keyPromise = null;
  function imageKey() {
    if (keyPromise) return keyPromise;
    keyPromise = new Promise(function (resolve) {
      if (window.__memosImageKey) { resolve(window.__memosImageKey); return; }
      if (!window.MemosSecurity) { resolve(''); return; }
      var tries = 0;
      var timer = setInterval(function () {
        if (window.__memosImageKey) { clearInterval(timer); resolve(window.__memosImageKey); return; }
        if (++tries > 60) { clearInterval(timer); resolve(''); }
      }, 50);
      try { window.MemosSecurity.postMessage('imageKey'); } catch (e) { resolve(''); }
    });
    return keyPromise;
  }

  // ---------------------------------------------------------------------------
  // 内存 LRU —— 性能关键
  // ---------------------------------------------------------------------------
  //
  // 每次显示都解密会拖慢滚动（AES-GCM 解一个 3MB 图约几毫秒，但滚动时会连续触发）。
  // 因此把已解密的 Blob 按"最近使用"缓存在内存里，滚动时零开销。
  // 上限 24 张：足够覆盖一屏多，内存可控（Blob 只持有引用，解码缓存由浏览器管）。
  var MEM_LIMIT = 24;
  var memOrder = [];
  // 只放**已解密的 Blob**。在途请求另放 `inflight`（只放 Promise）——
  // 两者混放曾导致解密路径拿到 Promise 而非密文字符串。
  var memBlobs = {};
  var inflight = {};

  function memGet(key) {
    if (!Object.prototype.hasOwnProperty.call(memBlobs, key)) return null;
    var idx = memOrder.indexOf(key);
    if (idx >= 0) { memOrder.splice(idx, 1); memOrder.push(key); }
    return memBlobs[key];
  }

  function memPut(key, blob) {
    memBlobs[key] = blob;
    memOrder.push(key);
    while (memOrder.length > MEM_LIMIT) {
      var old = memOrder.shift();
      if (old !== key) delete memBlobs[old];
    }
  }

  function withTimeout(promise, ms) {
    return new Promise(function (resolve, reject) {
      var t = setTimeout(function () { reject(new Error('timeout')); }, ms);
      promise.then(function (v) { clearTimeout(t); resolve(v); },
                   function (e) { clearTimeout(t); reject(e); });
    });
  }

  // ---------------------------------------------------------------------------
  // 加密读写
  // ---------------------------------------------------------------------------
  function decryptBytes(b64, keyB64) {
    if (!window.crypto || !window.crypto.subtle || !keyB64) {
      return Promise.reject(new Error('no-webcrypto'));
    }
    var raw = atob(b64);
    var buf = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
    if (buf.length < 13) return Promise.reject(new Error('short'));
    var iv = buf.slice(0, 12);
    var body = buf.slice(12);
    var keyRaw = atob(keyB64);
    var keyBuf = new Uint8Array(keyRaw.length);
    for (var k = 0; k < keyRaw.length; k++) keyBuf[k] = keyRaw.charCodeAt(k);
    return crypto.subtle.importKey('raw', keyBuf, { name: 'AES-GCM' }, false, ['decrypt'])
      .then(function (key) {
        return crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv }, key, body);
      })
      .then(function (plain) { return new Blob([plain]); });
  }

  function encryptBytes(arrayBuffer, keyB64) {
    if (!window.crypto || !window.crypto.subtle || !keyB64) {
      return Promise.reject(new Error('no-webcrypto'));
    }
    var iv = crypto.getRandomValues(new Uint8Array(12));
    var keyRaw = atob(keyB64);
    var keyBuf = new Uint8Array(keyRaw.length);
    for (var k = 0; k < keyRaw.length; k++) keyBuf[k] = keyRaw.charCodeAt(k);
    return crypto.subtle.importKey('raw', keyBuf, { name: 'AES-GCM' }, false, ['encrypt'])
      .then(function (key) {
        return crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv }, key, arrayBuffer);
      })
      .then(function (sealed) {
        var out = new Uint8Array(12 + sealed.byteLength);
        out.set(iv, 0);
        out.set(new Uint8Array(sealed), 12);
        var s = '';
        for (var i = 0; i < out.length; i++) s += String.fromCharCode(out[i]);
        return btoa(s);
      });
  }

  // 加载：三层，层与层**只传 Blob**，不混放 Promise。
  //
  // 曾经把在途的 Promise 和已完成的 Blob 放在同一个 map 里，导致解密路径拿到
  // 了 Promise 而不是密文字符串，报
  // `Failed to execute 'atob' on 'Window': The string to be decoded is not correctly encoded`。

  function load(src) {
    var key = cacheKey(src);

    var hit = memGet(key);
    if (hit) return Promise.resolve(hit);

    if (Object.prototype.hasOwnProperty.call(inflight, key)) return inflight[key];

    var job = readFromDisk(key).then(function (blob) {
      if (blob) {
        memPut(key, blob);
        delete inflight[key];
        return blob;
      }
      return fetchAndStore(src, key);
    }).catch(function (e) {
      delete inflight[key];
      throw e;
    });

    inflight[key] = job;
    return job;
  }

  /// 从 IndexedDB 读取并解密；未命中或解密失败返回 null（由上层重新下载）。
  function readFromDisk(key) {
    return Promise.all([cacheGet(key), imageKey()]).then(function (r) {
      var record = r[0];
      var keyB64 = r[1];

      // 必须是"带 data 字段的对象"：旧版本存的是裸 Blob，直接丢弃重新下载。
      if (!record || typeof record !== 'object' || typeof record.data !== 'string') {
        return null;
      }
      return withTimeout(decryptBytes(record.data, keyB64), 5000).then(
        function (blob) { return blob; },
        function (err) {
          console.log('[memos] decrypt failed for ' + key.slice(-24) + ': ' + err);
          return null;
        }
      );
    });
  }

  /// 下载 → 立即放入内存 → 异步加密落盘。
  function fetchAndStore(src, key) {
    return fetch(src, {
      headers: { 'Authorization': 'Bearer ' + token() },
      credentials: 'same-origin',
      // 关键：不让明文图片进 Chromium 的 HTTP 磁盘缓存。
      //
      // 字节由我们自己的加密 IndexedDB 缓存持有（见 cachePutEncrypted），
      // HTTP 缓存只会多留一份明文。曾经的做法是"进后台 clearCache() 清掉"，
      // 但那会连前端 bundle 一起清 —— 每次回前台都要重下整个 SPA（实测冷缓存
      // 下 HTML 就要 3.9 秒）。**不让它进来**比**事后清掉**正确得多。
      cache: 'no-store'
    }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.arrayBuffer();
    }).then(function (buf) {
      var blob = new Blob([buf]);
      memPut(key, blob);
      delete inflight[key];
      // 落盘不阻塞显示
      cachePutEncrypted(key, buf);
      return blob;
    });
  }  /// 加密后写入 IndexedDB（`{data: base64, v: 1}`）。
  ///
  /// 加密不可用（如 WebView 过旧、无 crypto.subtle）时**不缓存**，
  /// 而不是退回明文缓存 —— 宁可每次重新下载，也不在磁盘上留明文。
  function cachePutEncrypted(key, arrayBuffer) {
    return imageKey().then(function (keyB64) {
      return encryptBytes(arrayBuffer, keyB64);
    }).then(function (b64) {
      return cachePut(key, { data: b64, v: 1 });
    }).catch(function (err) {
      console.log('[memos] cache skip ' + key.slice(-24) + ': ' + err);
    });
  }
  function patch(img) {
    if (!img || img.getAttribute(MARK)) return;
    var src = img.getAttribute('src') || '';
    if (!isAttachment(src)) return;
    if (src.indexOf('blob:') === 0) return;

    // 关键：**立刻摘掉 src**，阻止浏览器用这个地址发一次注定失败的请求。
    // 不摘的话每张图要发两次请求（原生请求无 Authorization 头 → 失败，
    // 再由这里 fetch）—— 这是"比浏览器里直接用还慢"的主因，且会先闪一下碎图。
    img.setAttribute(MARK, '1');
    img.removeAttribute('src');
    if (!img.style.minHeight) img.style.minHeight = '1px';

    load(src).then(function (blob) {
      img.src = URL.createObjectURL(blob);
      img.removeAttribute(MARK);
    }).catch(function (e) {
      img.setAttribute('data-memos-error', String(e && e.message ? e.message : e));
      console.log('[memos] img fail ' + src.slice(0, 60) + ' :: ' + (e && e.message ? e.message : e));
    });
  }

  function sweep(root) {
    var list = (root || document).querySelectorAll('img[src*="/file/"]');
    for (var i = 0; i < list.length; i++) patch(list[i]);
  }

  // ---------------------------------------------------------------------------
  // 视频/音频：经应用内回环代理，恢复**原生流式播放**（边下边播）
  // ---------------------------------------------------------------------------
  //
  // `<video src="/file/...">`（官方 `AttachmentCard.tsx:35`、`PreviewImageDialog.tsx:193`）
  // 和 `<img>` 一样是**元素自身发起的请求**，带不上自定义头。服务端 file 端点
  // 只认 `Authorization: Bearer`（Access Token / PAT）或服务端签发的
  // refresh-token cookie（`fileserver.go:getCurrentUser`），WebView 里两者都
  // 没有 —— 私有附件必然 401。
  //
  // 历史方案是"带 Bearer fetch 整段下载 → blob URL"：能播，但必须等**整个
  // 文件**下载完才出声，且网格里的视频一进页面就全量下载（`preload` 语义全丢）。
  // 服务端其实一直支持流式（LOCAL → `http.ServeFile`、数据库 →
  // `http.ServeContent`、S3 → 透传单段 Range，全部原生 206/Content-Range），
  // 缺的只是"让元素请求带上凭据"这一步。
  //
  // 现在的做法：Dart 侧在 127.0.0.1 上运行流式代理（`media_proxy.dart` 的
  // `MediaStreamProxy`），这里把 src/poster 重写成
  // `http://127.0.0.1:<port>/mp-<secret>/file/...`；代理补 Bearer 头转发、
  // 原样透传 Range/206，之后完全交给 Chromium 媒体引擎 —— 边下边播、拖动
  // 进度条、`preload="none"` 懒加载语义全部恢复。
  //
  // 配套细节：
  // - 元素挂 `crossOrigin="anonymous"`：官方 `VideoPoster.tsx` 用 canvas 抓
  //   首帧做封面，代理地址跨源，不进 CORS 模式会污染 canvas；代理会回
  //   `Access-Control-Allow-*` 头并处理 OPTIONS 预检（cors 模式带 Range 的
  //   请求会先预检）。
  // - 回环地址是"潜在可信源"：https 页面加载 http://127.0.0.1 子资源不算
  //   混合内容；Android 明文策略已在 network_security_config.xml 放行。
  // - 私有附件的 `Cache-Control: private, no-store` 原样透传 → 明文视频不会
  //   进 Chromium HTTP 磁盘缓存（"视频不落盘"的约束不变）。
  //
  // 兜底：若某种 WebView 策略拦下回环请求（表现为**加载前**的 error 事件），
  // 对该元素一次性退回旧的"整段下载 → blob"路径（loadVideo）—— 最差回到
  // 旧体验，不会播不了。

  var vidMem = {};
  var vidOrder = [];
  var vidInflight = {};
  var VID_MEM_LIMIT = 3;

  function vidCached(key) {
    if (Object.prototype.hasOwnProperty.call(vidMem, key)) return vidMem[key];
    return null;
  }

  function vidRemember(key, blob) {
    vidMem[key] = blob;
    vidOrder.push(key);
    while (vidOrder.length > VID_MEM_LIMIT) {
      var old = vidOrder.shift();
      if (old !== key) delete vidMem[old];
    }
  }

  /// 落盘缓存（历史遗留清理用）：只删不写。
  function vidPurgeDisk(key) {
    try {
      var req = indexedDB.open('memos-media-cache', 1);
      req.onsuccess = function () {
        try {
          var tx = req.result.transaction(VID_STORE, 'readwrite');
          tx.objectStore(VID_STORE).delete(key);
        } catch (e) {}
      };
    } catch (e) {}
  }

  /// 兜底路径：带 Bearer 整段下载（代理不可用/被拦时才走）。
  /// 视频**不写盘**：动辄几十 MB，base64 进 IndexedDB 再膨胀 33% 且有配额
  /// 风险，只放内存（同会话重播即时）。
  function loadVideo(url) {
    var key = cacheKey(url);
    var hit = vidCached(key);
    if (hit) return Promise.resolve(hit);
    if (Object.prototype.hasOwnProperty.call(vidInflight, key)) return vidInflight[key];

    var job = fetch(url, {
      headers: { 'Authorization': 'Bearer ' + token() },
      credentials: 'same-origin',
      // 同图片：明文视频不进 HTTP 磁盘缓存（本来也不写 IndexedDB），
      // 这样就不必靠"清空整个缓存"来兜底。
      cache: 'no-store'
    }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.blob();
    }).then(function (blob) {
      vidRemember(key, blob);
      delete vidInflight[key];
      vidPurgeDisk(key);   // 清掉可能存在的旧版明文缓存
      return blob;
    }).catch(function (e) {
      delete vidInflight[key];
      throw e;
    });

    vidInflight[key] = job;
    return job;
  }

  function isRewritten(url) {
    if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) return true;
    var base = window.__memosMediaProxy || '';
    return base !== '' && url.indexOf(base) === 0;
  }

  /// 返回 url 对应的代理地址；不可代理（代理未注入/跨源/非 /file/）返回 ''。
  function proxyFor(url) {
    var base = window.__memosMediaProxy || '';
    if (!base) return '';
    try {
      var u = new URL(url, location.href);
      if (u.origin !== location.origin) return '';
      if (u.pathname.indexOf('/file/') !== 0) return '';
      // hash 必须保留：官方 VideoPoster 用 `#t=0.001` 定位抓帧位置
      //（媒体片段只在客户端生效，不会发给代理）。
      return base + u.pathname + u.search + u.hash;
    } catch (e) { return ''; }
  }

  /// 兜底路径：整段下载后换成 blob URL（代理不可用/被拦时）。
  function blobifyMedia(el, attr, url) {
    // 立刻摘掉，避免元素用无鉴权头的地址发一次注定失败的请求
    el.removeAttribute(attr);
    loadVideo(url).then(function (blob) {
      if (attr === 'poster') {
        el.setAttribute('poster', URL.createObjectURL(blob));
      } else {
        // 恢复播放状态：换 src 后需要显式 load 才会真正开始
        var wasPlaying = !el.paused && !el.ended;
        // blob 与页面同源，别带着 CORS 模式加载
        el.removeAttribute('crossorigin');
        el.setAttribute('src', URL.createObjectURL(blob));
        try { el.load(); } catch (e) {}
        if (wasPlaying) { try { el.play(); } catch (e) {} }
      }
    }).catch(function (e) {
      el.setAttribute('data-memos-error', String(e && e.message ? e.message : e));
      console.log('[memos] media fail ' + url.slice(0, 50) + ' :: ' + (e && e.message ? e.message : e));
    });
  }

  function patchMedia(el) {
    if (!el || (el.tagName !== 'VIDEO' && el.tagName !== 'AUDIO')) return;
    var attrs = ['src', 'poster'];
    for (var i = 0; i < attrs.length; i++) {
      (function (attr) {
        var url = el.getAttribute(attr) || '';
        if (!isAttachment(url) || isRewritten(url)) return;

        var proxied = proxyFor(url);
        if (!proxied) {
          // 代理未注入/不适用：直接走兜底（整段下载）
          blobifyMedia(el, attr, url);
          return;
        }
        if (attr === 'poster') {
          el.setAttribute('poster', proxied);
          return;
        }
        if (el.__memosBlobTriedFor === url) return;   // 该地址兜底也试过了，不再折腾
        // 同一元素换新 src 时，撤掉上一轮的回退监听
        if (el.__memosProxyErr) {
          el.removeEventListener('error', el.__memosProxyErr);
          el.__memosProxyErr = null;
        }
        var onError = function () {
          el.removeEventListener('error', onError);
          el.__memosProxyErr = null;
          // 只兜"**开始加载前**就被拦"（策略拦截/代理异常 → readyState 停在 0）。
          // 已经出过数据后的 error（解码失败/播到一半断流）不适合换 blob：
          // 前者 blob 同样解不了，后者交给播放器重试或用户再点一次。
          if (el.readyState > 0) return;
          if (el.__memosBlobTriedFor === url) return;
          el.__memosBlobTriedFor = url;
          console.log('[memos] media proxy blocked, blob fallback: ' + url.slice(0, 60));
          blobifyMedia(el, 'src', url);
        };
        el.__memosProxyErr = onError;
        el.addEventListener('error', onError);
        // crossOrigin 必须在 src 生效**之前**设置，canvas 抓帧才不被跨域污染。
        // 顺序说明：直接覆写 src（而不是先摘再设）—— 覆写只是重启加载算法，
        // 摘空 src 反而会让元素进入 NETWORK_NO_SOURCE 并可能触发多余的 error。
        el.setAttribute('crossorigin', 'anonymous');
        el.setAttribute('src', proxied);
      })(attrs[i]);
    }
  }

  function sweepMedia(root) {
    var list = (root || document).querySelectorAll(
      'video[src*="/file/"], video[poster*="/file/"], audio[src*="/file/"]');
    for (var i = 0; i < list.length; i++) patchMedia(list[i]);
  }
  function installObserver() {
    if (window.__memosPatcherInstalled) return;
    window.__memosPatcherInstalled = true;
    new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var rec = records[i];
        if (rec.type === 'attributes') {
          // React 复用节点、只改 src/poster 属性时 childList 观察不到。
          // 值守卫（isAttachment/isRewritten/MARK）保证不会自我循环。
          var t = rec.target;
          if (t && t.nodeType === 1) {
            if (t.tagName === 'IMG') patch(t);
            else patchMedia(t);
          }
          continue;
        }
        var nodes = rec.addedNodes;
        for (var j = 0; j < nodes.length; j++) {
          var node = nodes[j];
          if (!node || node.nodeType !== 1) continue;
          if (node.tagName === 'IMG') patch(node);
          else if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO') patchMedia(node);
          else { sweep(node); sweepMedia(node); }
        }
      }
    }).observe(document.documentElement || document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'poster']
    });
  }

  try {
    if (navigator.storage && navigator.storage.persist) navigator.storage.persist();
  } catch (e) { /* ignore */ }

  installObserver();
  sweep(document);
  sweepMedia(document);
  if (document.readyState !== 'loading') {
    setTimeout(function () { sweep(document); }, 0);
  } else {
    document.addEventListener('DOMContentLoaded', function () { sweep(document); });
  }
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // 视频事件探针（诊断）：定位播放失败在哪一步
  // ---------------------------------------------------------------------------
  //
  // 只在 `video` 上挂监听，把关键事件与状态打到控制台。要区分的情况：
  // - 没有 VIDEO_EV 日志        → 我们的 patchMedia 根本没碰到这个元素
  // - VIDEO_EV error            → 数据拿到了但解码/格式不行（error.code 有说明）
  // - metadata 有 duration=0    → blob 损坏或不完整
  // - canplay 但 playing 没来    → 自动播放策略拦下（需要用户手势）
  // - stalled/waiting 卡住       → 一直没数据
  function attachVideoProbe(v) {
    if (!v || v.__memosProbed) return;
    v.__memosProbed = true;
    var url = (v.getAttribute('src') || v.currentSrc || '').slice(0, 34);
    console.log('[memos] VIDEO_EV attach ' + url);
    var events = ['loadstart', 'loadedmetadata', 'loadeddata', 'canplay',
                  'canplaythrough', 'playing', 'pause', 'waiting', 'stalled',
                  'suspend', 'abort', 'emptied', 'error', 'ended'];
    events.forEach(function (name) {
      v.addEventListener(name, function () {
        console.log('[memos] VIDEO_EV ' + name +
          ' rs=' + v.readyState + ' ns=' + v.networkState +
          ' dur=' + (isFinite(v.duration) ? v.duration.toFixed(1) : String(v.duration)) +
          ' t=' + v.currentTime.toFixed(1) +
          ' w=' + v.videoWidth + 'x' + v.videoHeight +
          ' paused=' + v.paused +
          ' err=' + (v.error ? (v.error.code + ':' + (v.error.message || '')) : 'none'));
      });
    });
  }

  var mo = new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var nodes = records[i].addedNodes;
      for (var j = 0; j < nodes.length; j++) {
        var n = nodes[j];
        if (!n || n.nodeType !== 1) continue;
        if (n.tagName === 'VIDEO') attachVideoProbe(n);
        else if (n.querySelectorAll) {
          var vs = n.querySelectorAll('video');
          for (var k = 0; k < vs.length; k++) attachVideoProbe(vs[k]);
        }
      }
    }
  });
  mo.observe(document.documentElement || document, { childList: true, subtree: true });
  var initial = document.querySelectorAll('video');
  for (var m = 0; m < initial.length; m++) attachVideoProbe(initial[m]);
  return 'patched:' + document.querySelectorAll('img[data-memos-patched]').length;
})();
''';

  /// 生成"把分享的文件注入页面"的脚本。
  ///
  /// [files] 是 `{name, mimeType, base64}` 列表。
  ///
  /// 为什么注入**字节**而不是路径：给 `<input type="file">` 赋 `files` 在浏览器里
  /// 是禁止的，但用 `DataTransfer` + `File` 构造是允许的；而字节已在 JS 内存里，
  /// **渲染进程完全不需要读磁盘** —— 彻底绕开文件选择器那条路的跨进程访问问题。
  ///
  /// 脚本做两件事：
  /// 1. 存进 `window.__memosShareFiles`（惰性解码，避免大图卡顿）；
  /// 2. 若此刻已有文件输入框（编辑器已打开），立即注入并派发 `change`；
  ///    否则挂 `MutationObserver`，等输入框随编辑器挂载时注入（无需点「+」）。
  static String buildShareInjectionScript(List<Map<String, Object?>> files) {
    final String payload = jsonEncode(files);
    return '''
(function () {
  var incoming = $payload;
  if (!incoming || !incoming.length) return 'no-files';

  function decode(b64) {
    var raw = atob(b64);
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  function build() {
    var dt = new DataTransfer();
    for (var i = 0; i < incoming.length; i++) {
      var item = incoming[i];
      dt.items.add(new File([decode(item.base64)], item.name, { type: item.mimeType }));
    }
    return dt.files;
  }

  window.__memosShareFiles = incoming;

  function inject(input) {
    if (!input || input.tagName !== 'INPUT' || input.type !== 'file') return false;
    if (!window.__memosShareFiles || !window.__memosShareFiles.length) return false;
    try {
      input.files = build();
      window.__memosShareFiles = null;   // 一次性
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    } catch (e) {
      console.log('[memos] share inject failed: ' + e);
      return false;
    }
  }

  // 1) 编辑器已打开：立刻注入
  var existing = document.querySelectorAll('input[type=file]');
  for (var i = 0; i < existing.length; i++) {
    if (inject(existing[i])) return 'injected';
  }

  // 2) 否则等输入框出现（编辑器挂载时，两个 hidden input 随之出现）
  if (!window.__memosShareWatcher) {
    window.__memosShareWatcher = true;
    new MutationObserver(function () {
      var list = document.querySelectorAll('input[type=file]');
      for (var j = 0; j < list.length; j++) {
        if (inject(list[j])) return;
      }
    }).observe(document.documentElement || document, { childList: true, subtree: true });
  }
  return 'pending';
})();
''';
  }
}

/// 分享进来的明文临时文件前缀。
///
/// **必须与 Kotlin 侧 `ShareFiles.PREFIX` 保持一致**：跳板（`ShareReceiverActivity`）
/// 与主界面用它给"复制到缓存目录的分享文件"命名，这里的清理逻辑据此识别并删除。
const String sharedFilePrefix = 'shared_';

/// 删除 [dir] 里以 [prefix] 开头的文件，返回实际删除的数量。
///
/// 只删文件、不递归进子目录（文件选择的交付目录另有整目录清理），也不碰其它缓存 ——
/// 缓存目录里还有引擎与插件自己的东西。
///
/// 抽成顶层函数的理由：这条清理属于"本地不残留明文媒体"的硬约束，值得有主机可跑的
/// 回归测试（见 `test/share_cleanup_test.dart`），而不是只能在真机上碰运气验证。
Future<int> purgeSharedFiles(Directory dir, {String prefix = sharedFilePrefix}) async {
  if (!await dir.exists()) return 0;
  int removed = 0;
  await for (final FileSystemEntity entity in dir.list()) {
    if (entity is! File) continue;
    if (!p.basename(entity.path).startsWith(prefix)) continue;
    try {
      await entity.delete();
      removed++;
    } catch (_) {
      // 单个文件删不掉就跳过（例如被别的进程占用）
    }
  }
  return removed;
}

/// 极简 MIME 猜测：只覆盖上传场景会用到的类型。
String guessMimeType(String filename) {
  final String ext = filename.toLowerCase().split('.').last;
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    case 'mp4':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'pdf':
      return 'application/pdf';
    default:
      return 'application/octet-stream';
  }
}
