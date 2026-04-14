import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';

class ApiException implements Exception {
  ApiException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'ApiException($status): $body';
}

class ApiClient {
  ApiClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  String? token;

  Uri _uri(String path, {Map<String, String>? queryParams}) {
    final base = AppConfig.apiBase.replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$base$path');
    if (queryParams == null || queryParams.isEmpty) return uri;
    return uri.replace(queryParameters: queryParams);
  }

  Map<String, String> _headers({bool jsonBody = false}) {
    final h = <String, String>{};
    if (jsonBody) h['Content-Type'] = 'application/json';
    if (token != null && token!.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  Future<dynamic> getJson(String path, {Map<String, String>? queryParams}) async {
    final res = await _http.get(_uri(path, queryParams: queryParams), headers: _headers());
    return _decode(res);
  }

  Future<dynamic> postJson(String path, {Object? body}) async {
    final res = await _http.post(
      _uri(path),
      headers: _headers(jsonBody: true),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(res);
  }

  Future<dynamic> patchJson(String path, {required Object body}) async {
    final res = await _http.patch(
      _uri(path),
      headers: _headers(jsonBody: true),
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  Future<void> postEmpty(String path) async {
    final res = await _http.post(_uri(path), headers: _headers());
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
  }

  Future<dynamic> postMultipartBytes(
    String path, {
    required List<int> bytes,
    required String fileName,
    required Map<String, String> fields,
  }) async {
    final uri = _uri(path);
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_headers());
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
    );
    request.fields.addAll(fields);
    final streamed = await _http.send(request);
    final res = await http.Response.fromStream(streamed);
    return _decode(res);
  }

  Future<void> deletePath(String path) async {
    final res = await _http.delete(_uri(path), headers: _headers());
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
  }

  dynamic _decode(http.Response res) {
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, res.body);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body) as Object;
  }
}
