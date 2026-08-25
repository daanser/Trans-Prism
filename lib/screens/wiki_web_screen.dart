import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../models/wiki_config.dart';
import '../services/wiki_race_service.dart';
import '../services/wiki_sync_service.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/wiki_browser_bar.dart';

/// 内嵌完整 Wiki 站点（与 Next-MtF-wiki 部署的在线版一致）
class WikiWebScreen extends StatefulWidget {
  final String wikiId;
  final String title;

  const WikiWebScreen({
    super.key,
    required this.wikiId,
    required this.title,
  });

  @override
  State<WikiWebScreen> createState() => _WikiWebScreenState();
}

class _WikiWebScreenState extends State<WikiWebScreen> {
  final WikiSyncService _sync = WikiSyncService.instance;
  WebViewController? _controller;
  bool _isInitializing = true;
  String? _errorMessage;

  /// 浏览器式底栏可后退 / 可前进状态
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    try {
      final config = WikiCatalog.require(widget.wikiId);
      final snapshot = await _sync.resolveForOpen(widget.wikiId);
      final preferLocal = snapshot.strategy == WikiCacheStrategy.preferLocal;

      // ── 竞速模式：mtf / miomtf 同时探测 chengxi.moe 镜像与官方源，
      //    哪个先打开就访问哪个（对抗 GFW 干扰）；其余 wiki 直接用官方源。
      final targetUrl = await WikiRaceService.instance
          .resolveBestUrl(widget.wikiId, config.webUrl);
      debugPrint('[${widget.wikiId}] WikiWebScreen 实际加载: $targetUrl');
      if (!mounted) return;

      late final PlatformWebViewControllerCreationParams params;
      if (WebViewPlatform.instance is WebKitWebViewPlatform) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      final controller = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted);
      _attachNavDelegate(controller, snapshot);

      await controller.loadRequest(
        Uri.parse(targetUrl),
        headers: preferLocal ? const {} : const {'Cache-Control': 'no-cache'},
      );

      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  Future<void> _onPageFinished(WikiSyncSnapshot snapshot) async {
    if (snapshot.strategy == WikiCacheStrategy.preferRemote &&
        snapshot.remoteFingerprint != null) {
      await _sync.markContentCached(widget.wikiId, snapshot.remoteFingerprint!);
    }
  }

  /// 同步浏览器式底栏的可后退 / 可前进状态
  Future<void> _syncNavState(WebViewController controller) async {
    if (!mounted) return;
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();
    if (!mounted) return;
    if (back != _canGoBack || forward != _canGoForward) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  /// 为 WebView 挂载统一导航委托（同步底栏状态；主框架失败清竞速缓存）
  void _attachNavDelegate(
    WebViewController controller,
    WikiSyncSnapshot snapshot,
  ) {
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => _syncNavState(controller),
        onPageFinished: (_) {
          _onPageFinished(snapshot);
          _syncNavState(controller);
        },
        onWebResourceError: (error) {
          if (!mounted) return;
          if (error.isForMainFrame != true) return;
          // 主框架加载失败：清除竞速缓存，重试时重新探测换入口
          unawaited(WikiRaceService.instance.invalidate(widget.wikiId));
          _syncNavState(controller);
          setState(() {
            _errorMessage = error.description;
          });
        },
      ),
    );
  }

  Future<void> _retryWithNetwork() async {
    final config = WikiCatalog.require(widget.wikiId);
    final controller = _controller;
    if (controller == null) return;

    setState(() => _errorMessage = null);
    // 重试时重新竞速：优先 chengxi.moe 镜像，官方源兜底
    final targetUrl = await WikiRaceService.instance
        .resolveBestUrl(widget.wikiId, config.webUrl);
    if (!mounted || controller != _controller) return;
    await controller.loadRequest(
      Uri.parse(targetUrl),
      headers: const {'Cache-Control': 'no-cache'},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        // 页面内导航（后退/前进）统一在底部浏览器式细条，右上角不放
      ),
      body: _buildBody(),
      // ── 浏览器式底部导航细条：后退 / 刷新 / 前进 ──
      bottomNavigationBar: WikiBrowserBar(
        controller: _controller,
        canGoBack: _canGoBack,
        canGoForward: _canGoForward,
      ),
    );
  }

  Widget _buildBody() {
    if (_isInitializing) {
      return const LoadingIndicator(
        subtitle: '正在打开 Wiki',
        icon: Icons.menu_book_rounded,
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _retryWithNetwork,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const Center(child: Text('WebView 未就绪'));
    }

    return WebViewWidget(controller: controller);
  }
}
