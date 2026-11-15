import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

import '../auth/auth_service.dart';
import '../data/app_database.dart';
import '../state/app_store.dart';
import 'busy.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.initialRegister = false});

  final bool initialRegister;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  final _otp = TextEditingController();
  String? _error;
  String? _info;
  bool _obscure = true;
  bool _awaitingOtp = false;
  int _cooldown = 0;
  Timer? _coolTimer;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialRegister ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _coolTimer?.cancel();
    _tabs.dispose();
    _email.dispose();
    _password.dispose();
    _nickname.dispose();
    _otp.dispose();
    super.dispose();
  }

  void _startCooldown([int sec = 60]) {
    _coolTimer?.cancel();
    setState(() => _cooldown = sec);
    _coolTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown -= 1);
      }
    });
  }

  Future<void> _afterAuthSuccess() async {
    final store = context.read<AppStore>();
    final hadLocal = await AppDatabase.instance.hasLocalBusinessData();
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
  }

  Future<void> _login() async {
    setState(() {
      _error = null;
      _info = null;
    });
    final auth = AuthService.instance;
    try {
      await runBusy(
        context,
        message: '正在登录…',
        task: () => auth.signInWithPassword(
          email: _email.text,
          password: _password.text,
        ),
      );
      if (!mounted) return;
      await _afterAuthSuccess();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _register() async {
    setState(() {
      _error = null;
      _info = null;
    });
    final nick = _nickname.text.trim();
    if (nick.isEmpty) {
      setState(() => _error = '请填写昵称');
      return;
    }
    if (_password.text.trim().length < 6) {
      setState(() => _error = '密码至少 6 位');
      return;
    }
    final auth = AuthService.instance;
    try {
      final result = await runBusy(
        context,
        message: '正在注册…',
        task: () => auth.signUpWithPassword(
          email: _email.text,
          password: _password.text,
          nickname: nick,
        ),
      );
      if (!mounted) return;
      if (result.sessionReady) {
        await _afterAuthSuccess();
        return;
      }
      setState(() {
        _awaitingOtp = true;
        _info = '验证码已发送到邮箱，请查收后完成注册';
      });
      _startCooldown();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _verifyOtp() async {
    setState(() {
      _error = null;
    });
    final auth = AuthService.instance;
    try {
      await runBusy(
        context,
        message: '正在验证…',
        task: () => auth.verifyEmailOtp(
          email: _email.text,
          token: _otp.text,
          nickname: _nickname.text,
          type: OtpType.signup,
        ),
      );
      if (!mounted) return;
      await _afterAuthSuccess();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _resendOtp() async {
    if (_cooldown > 0) return;
    setState(() => _error = null);
    try {
      await runBusy(
        context,
        message: '发送中…',
        task: () => AuthService.instance.resendSignupOtp(_email.text),
      );
      if (!mounted) return;
      setState(() => _info = '验证码已重新发送');
      _startCooldown();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Widget _passwordField({required bool isLogin}) {
    return TextField(
      controller: _password,
      obscureText: _obscure,
      autofillHints: isLogin
          ? const [AutofillHints.password]
          : const [AutofillHints.newPassword],
      decoration: InputDecoration(
        labelText: '密码',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _obscure ? '显示密码' : '隐藏密码',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
      onSubmitted: (_) {
        if (isLogin) {
          _login();
        } else {
          _register();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_awaitingOtp) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('验证邮箱'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _awaitingOtp = false;
              _otp.clear();
              _error = null;
            }),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '验证码已发至 ${_email.text.trim()}。\n'
              '国内邮箱若收不到，请在 Supabase 配置阿里云邮件推送 / 腾讯云 SES 作为自定义 SMTP。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade700,
                  ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _otp,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                labelText: '验证码',
                hintText: '6 位验证码',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _verifyOtp(),
            ),
            if (_info != null) ...[
              const SizedBox(height: 12),
              Text(_info!, style: TextStyle(color: Colors.grey.shade700)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _verifyOtp,
              child: const Text('完成注册'),
            ),
            TextButton(
              onPressed: _cooldown > 0 ? null : _resendOtp,
              child: Text(
                _cooldown > 0 ? '$_cooldown 秒后可重发' : '重发验证码',
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '登录'),
            Tab(text: '注册'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '使用已注册的邮箱与密码登录。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade700,
                    ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _passwordField(isLogin: true),
              if (_error != null && _tabs.index == 0) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _login,
                child: const Text('登录'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('以后再说，先逛逛'),
              ),
            ],
          ),
          ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '注册后需验证邮箱。请配置国内可达的 SMTP（阿里云邮件推送 / 腾讯云 SES），'
                '短信通道可后续接入阿里云短信。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade700,
                    ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nickname,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  hintText: '展示在陋室与评点',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _passwordField(isLogin: false),
              if (_error != null && _tabs.index == 1) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _register,
                child: const Text('注册'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('以后再说，先逛逛'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
