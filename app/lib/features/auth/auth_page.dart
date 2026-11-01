import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/local/account_store.dart';
import '../../state/providers.dart';
import '../../ui/tokens/memos_tokens.dart';

/// 登录页 —— 对齐官方 `SignIn` + `AuthPageLayout` + `PasswordSignInForm`。
///
/// 官方结构：
/// - 整页居中卡片：`w-90 max-w-full rounded-xl border bg-card p-7 shadow-sm`
///   （360px 宽、12px 圆角、28px 内边距）；
/// - 顶部 logo（`h-6` 圆）+ 实例名（`text-sm font-semibold`）；
/// - 标题 `Sign in`（`text-lg font-semibold`）+ 副标题 `Welcome back.`；
/// - 表单 `flex flex-col gap-4`：Username、Password、提交按钮 `Sign in`；
/// - 底部 "Don't have an account yet? **Sign up**"。
///
/// 本客户端额外要求：实例地址（官方 web 与服务端同源，客户端需要用户填）。
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// 本地保存的凭据已被实例拒绝（401），因此被退回登录页。
  ///
  /// 见 `providers.dart` 的 [_rejectedAccounts]：拿着失效令牌进 WebView 只会
  /// 看到官方登录页，而页面里的登录不会落盘，等于每次都要重来。
  bool _needsReauth = false;

  @override
  void initState() {
    super.initState();
    // 预填上一次用过的实例与用户名：重新登录时只需要再输一次密码。
    final AppServices? services = ref.read(appServicesProvider).value;
    final AccountRecord? last = services?.accounts.firstOrNull;
    if (last == null) return;
    _host.text = last.baseUrl;
    _username.text = last.username ?? '';
    _needsReauth = services?.rejectedAccountIds.contains(last.id) ?? false;
  }

  @override
  void dispose() {
    _host.dispose();
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String host = _host.text.trim();
    final String username = _username.text.trim();
    final String password = _password.text;
    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please fill in the instance address, username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AccountRecord account = await ref.read(sessionControllerProvider).signIn(
            baseUrl: host,
            username: username,
            password: password,
          );
      ref.read(activeAccountIdProvider.notifier).set(account.id);
      if (mounted) context.go('/');
    } catch (error) {
      setState(() => _error = _humanize(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanize(Object error) {
    final String text = error.toString();
    if (text.contains('SocketException') || text.contains('Connection')) {
      return 'Could not reach that address. Check the network and the instance URL.';
    }
    if (text.contains('authentication') || text.contains('401')) {
      return 'Incorrect username or password.';
    }
    if (text.contains('0.31.0')) return text;
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final MemosThemeTokens tokens = context.tokens;
    final AppServices? services = ref.watch(appServicesProvider).value;
    final List<AccountRecord> accounts = services?.accounts ?? const <AccountRecord>[];
    final Set<String> rejected = services?.rejectedAccountIds ?? const <String>{};

    return Scaffold(
      backgroundColor: tokens.background,
      // 全面屏：登录卡片居中，用 SafeArea 避开状态栏、挖孔与手势条。
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360), // w-90
              child: Container(
              padding: const EdgeInsets.all(28), // p-7
              decoration: BoxDecoration(
                color: tokens.card,
                borderRadius: BorderRadius.circular(MemosTokens.radiusXl),
                border: Border.all(color: tokens.border),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // logo + 实例名
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 24, // h-6
                        height: 24,
                        decoration: BoxDecoration(color: tokens.primary, shape: BoxShape.circle),
                        child: Icon(Icons.bolt, size: 14, color: tokens.primaryForeground),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Peli',
                        style: TextStyle(
                          fontSize: MemosTokens.textUi,
                          fontWeight: FontWeight.w600,
                          color: tokens.foreground,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Sign in',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Welcome back.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: MemosTokens.textUi, color: tokens.mutedForeground),
                  ),
                  if (_needsReauth) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'Your saved session is no longer valid on this instance. '
                      'Sign in again to get a new long-lived token.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: MemosTokens.text2xs, color: tokens.destructive),
                    ),
                  ],
                  const SizedBox(height: 20),
                  // 表单 gap-4
                  _field(
                    tokens,
                    controller: _host,
                    label: 'Instance address',
                    hint: 'https://memos.example.com',
                    keyboardType: TextInputType.url,
                    autofocus: true,
                  ),
                  const SizedBox(height: 16),
                  _field(tokens, controller: _username, label: 'Username'),
                  const SizedBox(height: 16),
                  _field(
                    tokens,
                    controller: _password,
                    label: 'Password',
                    obscure: _obscure,
                    focusNode: _passwordFocus,
                    onSubmitted: (_) => _submit(),
                    suffix: IconButton(
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        size: 16,
                      ),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(fontSize: MemosTokens.textUi, color: tokens.destructive),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.primary,
                      foregroundColor: tokens.primaryForeground,
                      minimumSize: const Size.fromHeight(MemosTokens.buttonHeightLg),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(MemosTokens.radiusMd),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in', style: TextStyle(fontSize: MemosTokens.textUi)),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'A long-lived access token (PAT) is created and kept in the device keystore '
                    'so you stay signed in.',
                    style: TextStyle(fontSize: MemosTokens.text2xs, color: tokens.mutedForeground),
                  ),
                  if (accounts.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 20),
                    Divider(height: 1, color: tokens.border),
                    const SizedBox(height: 12),
                    Text(
                      'Saved instances',
                      style: TextStyle(fontSize: MemosTokens.text2xs, color: tokens.mutedForeground),
                    ),
                    const SizedBox(height: 4),
                    for (final AccountRecord account in accounts)
                      TextButton(
                        onPressed: () {
                          if (rejected.contains(account.id)) {
                            // 凭据已知失效：进 WebView 只会落到官方登录页，
                            // 而那里的登录不落盘。改为填进表单，重新签发 PAT。
                            setState(() {
                              _host.text = account.baseUrl;
                              _username.text = account.username ?? '';
                              _needsReauth = true;
                              _error = null;
                            });
                            return;
                          }
                          ref.read(activeAccountIdProvider.notifier).set(account.id);
                          context.go('/');
                        },
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            account.title,
                            style: const TextStyle(fontSize: MemosTokens.textUi),
                          ),
                        ),
                      ),
                  ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    MemosThemeTokens tokens, {
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    bool autofocus = false,
    FocusNode? focusNode,
    ValueChanged<String>? onSubmitted,
    Widget? suffix,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: MemosTokens.text2xs, color: tokens.mutedForeground),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            autofocus: autofocus,
            focusNode: focusNode,
            onSubmitted: onSubmitted,
            style: const TextStyle(fontSize: MemosTokens.textUi),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: MemosTokens.textUi, color: tokens.mutedForeground),
              suffixIcon: suffix,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(MemosTokens.radiusMd),
                borderSide: BorderSide(color: tokens.input),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(MemosTokens.radiusMd),
                borderSide: BorderSide(color: tokens.input),
              ),
            ),
          ),
        ],
      );
}
