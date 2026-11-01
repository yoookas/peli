import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'state/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 全面屏（edge-to-edge）：让内容铺满整块屏幕（含状态栏/导航栏/挖孔区域）。
  //
  // Android 15+ 已强制这种模式，这里显式调用是为了：
  // - 覆盖 Android 14 及以下（本应用 minSdk 24）；
  // - 统一行为，避免不同 OEM（MIUI/HyperOS 等）表现不一致。
  // 实际的内边距由各页面的 SafeArea 负责，背景色则一直延伸到底。
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );

  runApp(const ProviderScope(child: AppBootstrap()));
}

/// 启动包装：读取凭据期间显示明确的进度/失败态，避免白屏或静默降级。
class AppBootstrap extends ConsumerWidget {
  const AppBootstrap({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<AppServices> services = ref.watch(appServicesProvider);
    return services.when(
      loading: () => const _BootScreen(message: '正在打开本地加密数据库…'),
      error: (Object error, StackTrace stack) => _BootFailure(error: error),
      data: (AppServices value) => const MemosApp(),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(message),
              ],
            ),
          ),
        ),
      );
}

class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text('无法打开本地加密数据', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 12),
                  Text('$error', textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
}
