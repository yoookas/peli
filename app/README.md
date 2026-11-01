# peli

Peli 的 Flutter 应用包（`peli.lcyk.cc`）—— [usememos/memos](https://github.com/usememos/memos) 的 Android 客户端。

**功能清单、架构说明、构建方式与已知缺口请看仓库根目录的 [`../README.md`](../README.md)。**

## 这个包负责什么

| 目录 | 职责 |
|---|---|
| `lib/features/web/` | 主界面外壳：官方 Web 前端的令牌注入、附件图片加密缓存、视频流式代理、文件选择接管、系统分享注入 |
| `lib/features/auth/` | 首次配置（实例地址 + 账号密码 → 长效 PAT） |
| `lib/data/local/` | 平台安全存储：账号条目（`accounts.v1`）与会话机密（图片缓存密钥），Keystore 适配 |
| `lib/state/` | 启动流程（读安全存储、载入账号）与 Riverpod 装配 |
| `lib/ui/tokens/` | 官方 oklch 设计令牌与精确色彩空间转换 |

登录所需的协议客户端在同仓库的 `packages/memos_api`（纯 Dart、可独立测试）。
界面本体是官方 Web 前端，本包不实现任何 memo 列表 / 编辑器界面。

## 常用命令

```bash
flutter pub get
flutter analyze
flutter test                                  # 单元测试
flutter build apk --release                   # 产物：build/app/outputs/flutter-apk/app-release.apk
dart run tool/verify_apk_encryption.dart      # 校验发布产物里的加密链路
flutter test integration_test/<name>.dart -d <deviceId>   # 真机集成测试，一次一个文件
```
