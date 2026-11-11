import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../ui/auth_page.dart';
import 'auth_service.dart';

/// 写操作门禁：游客弹窗引导注册/登录。
Future<bool> requireLandlord(BuildContext context, {String? message}) async {
  final store = context.read<AppStore>();
  if (store.isLandlord) return true;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要注册登录'),
      content: Text(
        message ?? '浏览市集和对话无需登录；写笔记、上架文章请先注册登录。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('继续浏览'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去注册/登录'),
        ),
      ],
    ),
  );
  if (go == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthPage()),
    );
    return AuthService.instance.isLandlord;
  }
  return false;
}
