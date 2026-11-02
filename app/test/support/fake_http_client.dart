import 'dart:convert';

import 'package:http/http.dart' as http;

/// 按路径路由的假 HTTP client：记录收到的请求，由调用方决定每个路径的响应。
///
/// MemosClient 全程使用 http.Request，这里直接按类型取用即可。
/// 未登记的路径返回 404（用于验证"不该发生的请求"）。
class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this.routes);

  final Map<String, http.Response Function(http.Request request)> routes;

  /// 按发生顺序记录的请求，便于断言"打到了哪个端点、带没带令牌"。
  final List<http.Request> requests = <http.Request>[];

  List<String> get paths => requests.map((http.Request r) => r.url.path).toList(growable: false);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Request recorded = request is http.Request
        ? request
        : (http.Request(request.method, request.url)..headers.addAll(request.headers));
    requests.add(recorded);

    final http.Response Function(http.Request request)? handler = routes[recorded.url.path];
    final http.Response response =
        handler == null ? http.Response('404: ${recorded.url.path}', 404) : handler(recorded);

    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

/// 200 + JSON 的便捷构造。
http.Response jsonOk(Map<String, Object?> body) => http.Response(
      jsonEncode(body),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );

/// 错误响应（Connect/gRPC-gateway 的 JSON 形态）。
http.Response jsonError(int status, int code, String message) => http.Response(
      jsonEncode(<String, Object?>{'code': code, 'message': message}),
      status,
      headers: const <String, String>{'content-type': 'application/json'},
    );
