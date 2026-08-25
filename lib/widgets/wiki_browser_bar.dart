import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 浏览器式底部导航细条：后退 / 刷新 / 前进
///
/// 与浏览器底栏一致：返回上级（可后退时高亮）、前进到下级（可前进时
/// 高亮）、刷新。右上方不再放置返回按钮，避免「页面内后退」与「退出
/// 页面」混淆。
///
/// [canGoBack] / [canGoForward] 由宿主根据 WebViewController 的
/// 历史栈状态驱动；[onRefresh] 缺省为 controller.reload()。
class WikiBrowserBar extends StatelessWidget {
  final WebViewController? controller;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback? onRefresh;

  const WikiBrowserBar({
    super.key,
    required this.controller,
    required this.canGoBack,
    required this.canGoForward,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabledColor =
        isDark ? const Color(0xFFEDEDF0) : const Color(0xFF333333);
    final disabledColor =
        isDark ? const Color(0xFF4A4A52) : const Color(0xFFC4C4C8);
    final bg = isDark ? const Color(0xFF191920) : const Color(0xFFFAFAF7);
    final borderColor =
        isDark ? const Color(0xFF333338) : const Color(0xFFE5E5E5);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: borderColor, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: '后退',
                icon: const Icon(Icons.arrow_back_rounded),
                color: canGoBack ? enabledColor : disabledColor,
                onPressed: canGoBack
                    ? () async {
                        await controller?.goBack();
                      }
                    : null,
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded),
                color: enabledColor,
                onPressed: onRefresh ?? controller?.reload,
              ),
              IconButton(
                tooltip: '前进',
                icon: const Icon(Icons.arrow_forward_rounded),
                color: canGoForward ? enabledColor : disabledColor,
                onPressed: canGoForward
                    ? () async {
                        await controller?.goForward();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}