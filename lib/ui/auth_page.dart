import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../data/app_database.dart';
import '../state/app_store.dart';
import 'busy.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.initialRegister = false});

  /// 保留参数以兼容旧入口；Email OTP 无注册/登录分栏。
  final bool initialRegister;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _email = TextEditingController();
  final _otp = TextEditingController();
  bool _codeSent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    setState(() => _error = null);
    final email = _email.text.trim();
    try {
      await runBusy(
        context,
        message: '正在发送验证码…',
        task: () => AuthService.instance.sendEmailOtp(email),
      );
      if (!mounted) return;
      setState(() => _codeSent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('验证码已发送，请查收邮箱')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _verify() async {
    setState(() => _error = null);
    final email = _email.text.trim();
    final token = _otp.text.trim();
    final store = context.read<AppStore>();
    final auth = AuthService.instance;
    try {
      final hadLocal = await AppDatabase.instance.hasLocalBusinessData();
      if (!mounted) return;

      await runBusy(
        context,
        message: '正在验证…',
        task: () => auth.verifyEmailOtp(email: email, token: token),
      );
      if (!mounted) return;

      var claim = false;
      if (hadLocal) {
        claim = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('本机已有本地数据'),
                content: const Text(
                  '是否将本机现有数据归属到当前账号并上传？\n'
                  '选「清空」则丢弃本机旧数据，从云端拉取该账号数据。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('清空本机'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('归属到本账号'),
                  ),
                ],
              ),
            ) ??
            false;
      }
      if (!mounted) return;

      await runBusy(
        context,
        message: '正在准备账号数据…',
        task: () => store.onLoggedIn(claimLocalData: claim),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _codeSent
                ? '输入邮箱收到的验证码完成登录'
                : '使用邮箱验证码登录后即可写笔记、上架文章并同步',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade700,
                ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _email,
            enabled: !_codeSent,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: '邮箱',
              hintText: 'you@example.com',
              border: OutlineInputBorder(),
            ),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _otp,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                labelText: '验证码',
                hintText: '邮件中的 6–8 位码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 24),
          if (!_codeSent)
            FilledButton(
              onPressed: _sendCode,
              child: const Text('发送验证码'),
            )
          else ...[
            FilledButton(
              onPressed: _verify,
              child: const Text('验证并登录'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _codeSent = false;
                _otp.clear();
                _error = null;
              }),
              child: const Text('更换邮箱'),
            ),
            TextButton(
              onPressed: _sendCode,
              child: const Text('重新发送验证码'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('以后再说，先逛逛'),
          ),
          const SizedBox(height: 12),
          Text(
            '验证码由 Supabase Auth 发送。请在控制台开启 Email OTP。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                ),
          ),
        ],
      ),
    );
  }
}