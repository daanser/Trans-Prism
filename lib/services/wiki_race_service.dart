import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 竞速模式（Race Mode）—— 对抗 GFW 干扰的 Wiki 入口选择服务。
///
/// 原理：同一 Wiki 同时探测「chengxi.moe 反代镜像」与「官方源地址」，
/// 谁先返回可用的 2xx/3xx 响应就用谁（哪个先打开就访问哪个）。
///
/// 记忆策略（按网络环境半永久缓存）：
/// - 竞速按「网络环境指纹」（本地 IP 集合的 SHA-256 哈希）区分网络；
/// - 同一网络下竞速成功后，记录哪个入口胜出，后续直接复用；
/// - 换网络（指纹不同）时自动重新竞速；
/// - 最多保留 50 条网络记录、每条 7 天过期，超限按最后使用时间淘汰最旧；
/// - 记录经 [FlutterSecureStorage] 本地加密存储，**IP 原文不上传、
///   只存单向哈希指纹**，隐私安全。
class WikiRaceService {
  WikiRaceService._();

  static final WikiRaceService instance = WikiRaceService._();

  /// 竞速候选：key = wikiType（离线阅读器）或 wikiId（WiKiWebScreen），
  /// value = 候选 URL 列表（镜像在前，官方源兜底）。
  ///
  /// - mtf：官方 `mtf.wiki` 主域常被 GFW 干扰，镜像 `mtf.chengxi.moe`
  ///   走 CF 反代直连上游同源内容；
  /// - miomtfwiki / miomtf：`kitsumio.github.io` GitHub Pages 在国内不稳，
  ///   镜像 `mio.chengxi.moe`（CF Worker 保留 /MioMtFWiki 前缀透传）。
  static const Map<String, List<String>> candidateUrls = {
    'mtf': [
      'https://mtf.chengxi.moe/zh-cn/',
      'https://mtf.wiki/zh-cn/',
    ],
    'miomtfwiki': [
      'https://mio.chengxi.moe/MioMtFWiki/',
      'https://kitsumio.github.io/MioMtFWiki/',
    ],
    'miomtf': [
      'https://mio.chengxi.moe/MioMtFWiki/',
      'https://kitsumio.github.io/MioMtFWiki/',
    ],
  };

  /// 单次探测超时（connect + receive）
  static const Duration _probeTimeout = Duration(seconds: 4);

  /// 竞速整体等待的额外余量（覆盖 DNS/重定向等开销）
  static const Duration _raceSlack = Duration(seconds: 2);

  /// 每个网络环境的记录保留时长：7 天
  static const Duration _recordTtl = Duration(days: 7);

  /// 最多保留的网络记录条数：50
  static const int _maxNetworkRecords = 50;

  /// 竞速专用 Dio（只关心状态码，不下载正文）
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: _probeTimeout,
      receiveTimeout: _probeTimeout,
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (code) => code != null && code >= 200 && code < 400,
    ),
  );

  /// 本地加密存储（Android Keystore / iOS Keychain 级加密）
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _storageKey = 'wiki_race_network_cache_v1';

  // ── 内存态（启动后从加密存储恢复） ──
  /// 网络指纹 → wikiKey → 胜出 URL
  final Map<String, Map<String, String>> _netCache = {};

  /// 网络指纹 → wikiKey → 记录时间
  final Map<String, Map<String, DateTime>> _netTs = {};

  /// 网络指纹 → 最后使用时间戳（用于超限淘汰最旧）
  final Map<String, int> _netLastUsed = {};

  bool _loaded = false;

  /// 持久化写队列（避免并发写互相覆盖）
  Future<void> _pendingPersist = Future.value();

  /// 网络指纹计算去重（同帧内多个 wiki 并行打开只算一次）
  Future<String?>? _fingerprintFuture;

  // ==================== 对外 API ====================

  /// 解析某 wiki 的竞速胜出 URL。
  ///
  /// [key] 取 wikiType 或 wikiId；[primary] 为官方源（兜底）。
  /// 同网络命中缓存直接复用；换网络或未命中则竞速，成功后按网络记忆。
  Future<String> resolveBestUrl(String key, String primary) async {
    final candidates = candidateUrls[key];
    if (candidates == null || candidates.isEmpty) return primary;

    await _ensureLoaded();
    final fp = await _networkFingerprint();

    // 同网络命中：直接复用上次胜出入口
    if (fp != null) {
      final url = _netCache[fp]?[key];
      if (url != null) {
        _netLastUsed[fp] = DateTime.now().millisecondsSinceEpoch;
        debugPrint('[WikiRace] $key 命中网络缓存 → $url');
        return url;
      }
    }

    if (fp == null) {
      debugPrint('[WikiRace] $key 无法识别网络指纹，仅本次竞速');
    }

    // 未命中 / 换网络 → 并发竞速
    final winner = await _race(key, candidates) ?? primary;

    // 竞速成功后按当前网络记忆（记录哪个快）
    if (fp != null) {
      _netCache.putIfAbsent(fp, () => {})[key] = winner;
      _netTs.putIfAbsent(fp, () => {})[key] = DateTime.now();
      _netLastUsed[fp] = DateTime.now().millisecondsSinceEpoch;
      _evictNetworks();
      _schedulePersist();
    } else {
      debugPrint('[WikiRace] $key 无指纹，本次胜出: $winner（不持久化）');
    }
    return winner;
  }

  /// 清除某 wiki 在「当前网络」下的竞速记录
  /// （WebView 主框架加载失败时调用，让 retry 真正重新竞速）。
  Future<void> invalidate(String key) async {
    await _ensureLoaded();
    final fp = await _networkFingerprint();
    if (fp == null) return;
    final removed = _netCache[fp]?.remove(key) != null;
    _netTs[fp]?.remove(key);
    if (removed) {
      _schedulePersist();
      debugPrint('[WikiRace] $key 已清除当前网络缓存');
    }
  }

  // ==================== 网络环境指纹 ====================

  /// 当前网络环境指纹：本地非回环 IPv4 列表排序后做 SHA-256，
  /// 取前 16 位十六进制。单向哈希，**无法反推 IP，也不会上传**。
  Future<String?> _networkFingerprint() {
    return _fingerprintFuture ??= _computeFingerprint().then((v) {
      _fingerprintFuture = null; // 每次调用重新识别（网络可能变化）
      return v;
    });
  }

  Future<String?> _computeFingerprint() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final ips = <String>[
        for (final i in interfaces)
          for (final addr in i.addresses)
            if (addr.address.isNotEmpty) addr.address,
      ]..sort();
      if (ips.isEmpty) return null;
      final digest = sha256.convert(utf8.encode(ips.join('|')));
      return digest.toString().substring(0, 16);
    } catch (e) {
      debugPrint('[WikiRace] 网络指纹计算失败: $e');
      return null;
    }
  }

  // ==================== 持久化（加密存储） ====================

  /// 启动后从加密存储恢复记忆（懒加载，只用一次）
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null || raw.isEmpty) return;

      final map = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      for (final entry in map.entries) {
        final net = entry.key;
        final entries = entry.value;
        if (entries is! Map<String, dynamic>) continue;

        final urls = <String, String>{};
        final ts = <String, DateTime>{};
        int lastUsed = 0;
        entries.forEach((wiki, v) {
          if (v is Map<String, dynamic>) {
            final url = v['url'] as String?;
            final t = v['ts'] as int?;
            if (url != null && t != null) {
              final dt = DateTime.fromMillisecondsSinceEpoch(t);
              if (now.difference(dt) < _recordTtl) {
                urls[wiki] = url;
                ts[wiki] = dt;
                if (t > lastUsed) lastUsed = t;
              }
            }
          }
        });
        if (urls.isNotEmpty) {
          _netCache[net] = urls;
          _netTs[net] = ts;
          _netLastUsed[net] = lastUsed;
        }
      }
      _evictNetworks();
    } catch (e) {
      debugPrint('[WikiRace] 读取加密缓存失败: $e');
    }
  }

  /// 串行化持久化写
  void _schedulePersist() {
    final prev = _pendingPersist.catchError((_) {});
    _pendingPersist = prev.then((_) => _persist());
  }

  Future<void> _persist() async {
    try {
      final out = <String, dynamic>{};
      _netCache.forEach((net, urls) {
        final entries = <String, dynamic>{};
        final ts = _netTs[net];
        urls.forEach((wiki, url) {
          final t = ts?[wiki]?.millisecondsSinceEpoch;
          if (t != null) {
            entries[wiki] = {'url': url, 'ts': t};
          }
        });
        if (entries.isNotEmpty) out[net] = entries;
      });
      await _storage.write(key: _storageKey, value: jsonEncode(out));
    } catch (e) {
      debugPrint('[WikiRace] 写入加密缓存失败: $e');
    }
  }

  /// 超过 [maxNetworkRecords] 时按最后使用时间淘汰最旧的网络
  void _evictNetworks() {
    while (_netLastUsed.length > _maxNetworkRecords) {
      String? oldestNet;
      int? oldestTs;
      _netLastUsed.forEach((net, ts) {
        final currentOldest = oldestTs;
        if (currentOldest == null || ts < currentOldest) {
          oldestTs = ts;
          oldestNet = net;
        }
      });
      if (oldestNet == null) break;
      _netCache.remove(oldestNet);
      _netTs.remove(oldestNet);
      _netLastUsed.remove(oldestNet);
    }
  }

  // ==================== 竞速核心 ====================

  /// 并发探测所有候选，返回第一个 2xx/3xx 成功的 URL；
  /// 全部失败或整体超时返回 null。
  Future<String?> _race(String key, List<String> urls) async {
    final completer = Completer<String?>();
    var pending = urls.length;

    for (final url in urls) {
      unawaited(_probe(url).then((ok) {
        if (completer.isCompleted) return;
        if (ok) {
          debugPrint('[WikiRace] $key 候选可达 → $url');
          completer.complete(url);
          return;
        }
        debugPrint('[WikiRace] $key 候选不可达/超时 → $url');
        pending -= 1;
        if (pending == 0) {
          completer.complete(null);
        }
      }));
    }

    return completer.future.timeout(
      _probeTimeout + _raceSlack,
      onTimeout: () => null,
    );
  }

  /// 单点探测：HEAD 请求，2xx/3xx 视为可访问。
  Future<bool> _probe(String url) async {
    try {
      final resp = await _dio.head<dynamic>(url);
      final code = resp.statusCode;
      return code != null && code >= 200 && code < 400;
    } catch (_) {
      return false;
    }
  }
}