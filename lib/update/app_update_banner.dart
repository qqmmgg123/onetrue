import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import 'app_update_service.dart';

/// 挂在壳层：仅在「确实有更新要下/要装」时弹窗；无更新时静默，不闪窗。
class AppUpdateHost extends StatefulWidget {
  const AppUpdateHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends State<AppUpdateHost> {
  final _svc = AppUpdateService.instance;
  var _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _svc.phase.addListener(_onPhase);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        // 后台静默检查；无更新不会弹窗
        _svc.bootstrap();
      });
    });
  }

  @override
  void dispose() {
    _svc.phase.removeListener(_onPhase);
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    final phase = _svc.phase.value;
    // 不要在 checking 弹窗：每次启动都会检查，无更新时会造成闪一下又关
    if (phase == AppUpdatePhase.ready ||
        phase == AppUpdatePhase.downloading ||
        phase == AppUpdatePhase.failed) {
      _ensureDialog();
    } else if (phase == AppUpdatePhase.idle && _dialogOpen) {
      // 下载过程中若变 idle，由 dialog 内部 pop
    }
  }

  void _ensureDialog() {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return WillPopScope(
          onWillPop: () async {
            final force = _svc.readyInfo?.force ?? false;
            final phase = _svc.phase.value;
            // 强制更新且已就绪/下载中：禁止返回关闭
            if (force &&
                (phase == AppUpdatePhase.ready ||
                    phase == AppUpdatePhase.downloading)) {
              return false;
            }
            return phase != AppUpdatePhase.downloading;
          },
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _svc.phase,
              _svc.progress,
              _svc.message,
            ]),
            builder: (_, __) {
              final phase = _svc.phase.value;
              final info = _svc.readyInfo;
              final notes = (info?.changelog ?? '').trim();
              final force = info?.force ?? true;

              if (phase == AppUpdatePhase.idle ||
                  phase == AppUpdatePhase.checking) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (ctx.mounted) Navigator.of(ctx).pop();
                });
              }

              return AlertDialog(
                title: Text(
                  phase == AppUpdatePhase.ready
                      ? '发现新版本 ${info?.versionName ?? ''}'
                      : phase == AppUpdatePhase.failed
                          ? '更新失败'
                          : '正在下载更新',
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (phase == AppUpdatePhase.downloading) ...[
                      LinearProgressIndicator(value: _svc.progress.value),
                      const SizedBox(height: 12),
                      Text(
                        _svc.message.value.isEmpty
                            ? '下载中…'
                            : _svc.message.value,
                      ),
                    ],
                    if (phase == AppUpdatePhase.ready) ...[
                      if (notes.isNotEmpty)
                        Text(notes, style: const TextStyle(height: 1.45))
                      else
                        const Text('请安装新版本以继续使用。'),
                      if (force) ...[
                        const SizedBox(height: 12),
                        Text(
                          '当前为必要更新，需安装后才能继续使用。',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                    if (phase == AppUpdatePhase.failed)
                      Text(
                        _svc.message.value.isEmpty
                            ? '更新失败'
                            : _svc.message.value,
                      ),
                  ],
                ),
                actions: [
                  if (phase == AppUpdatePhase.ready) ...[
                    if (!force)
                      TextButton(
                        onPressed: () async {
                          await _svc.skipReady();
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                        child: const Text('稍后'),
                      ),
                    FilledButton(
                      onPressed: () async {
                        final r = await _svc.installReady();
                        if (!ctx.mounted) return;
                        if (r.type != ResultType.done) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                r.message.trim().isEmpty
                                    ? '无法打开安装器，请到系统设置允许「安装未知应用」'
                                    : '安装失败：${r.message}',
                              ),
                            ),
                          );
                        }
                      },
                      child: const Text('立即安装'),
                    ),
                  ] else if (phase == AppUpdatePhase.failed) ...[
                    TextButton(
                      onPressed: () => _svc.bootstrap(manual: true),
                      child: const Text('重试'),
                    ),
                    if (!force)
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('关闭'),
                      ),
                  ],
                ],
              );
            },
          ),
        );
      },
    ).whenComplete(() {
      _dialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> runManualUpdateCheck(BuildContext context) async {
  final svc = AppUpdateService.instance;
  if (!svc.hasManifest) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('未配置更新源：请在 env.local 配置七牛/R2，或 APP_UPDATE_MANIFEST_URL'),
      ),
    );
    return;
  }
  await svc.bootstrap(manual: true);
  if (!context.mounted) return;
  if (svc.phase.value == AppUpdatePhase.idle) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          svc.message.value.isEmpty ? '已是最新版本' : svc.message.value,
        ),
      ),
    );
  }
}
