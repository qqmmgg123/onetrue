import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

import '../auth/auth_service.dart';
import '../data/app_database.dart';
import '../state/app_store.dart';
import 'busy.dart';
import '../util/user_facing_error.dart';

enum _AuthFlow { tabs, signupOtp, forgot, reset }

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
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _error;
  String? _info;
  bool _obscure = true;
  bool _obscureNew = true;
  _AuthFlow _flow = _AuthFlow.tabs;
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
    _newPassword.dispose();
    _confirmPassword.dispose();
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
      if (!mounted) return;
      final msg = userFacingError(e);
      final raw = e.toString().toLowerCase();
      if (raw.contains('email not confirmed') ||
          raw.contains('email address not confirmed') ||
          msg.contains('尚未验证')) {
        await _goVerifyExisting();
        return;
      }
      setState(() => _error = msg);
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
        _flow = _AuthFlow.signupOtp;
        _info = result.otpHint ?? '验证码已发送到邮箱，请查收后完成注册';
      });
      _startCooldown();
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Future<void> _goVerifyExisting() async {
    setState(() {
      _error = null;
      _info = null;
    });
    final e = _email.text.trim();
    if (e.isEmpty) {
      setState(() => _error = '请先填写邮箱');
      return;
    }
    try {
      await runBusy(
        context,
        message: '发送中…',
        task: () => AuthService.instance.beginEmailVerification(e),
      );
      if (!mounted) return;
      setState(() {
        _flow = _AuthFlow.signupOtp;
        _info = '验证码已发送到邮箱，请查收后完成验证';
      });
      _startCooldown();
    } catch (err) {
      if (mounted) {
        // 即便发送失败也进入验证页，方便输入旧验证码或稍后重发
        setState(() {
          _flow = _AuthFlow.signupOtp;
          _error = userFacingError(err);
          _info = '若此前已发过验证码，可直接输入；也可稍后重发';
        });
      }
    }
  }

  Future<void> _verifySignupOtp() async {
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
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Future<void> _resendSignupOtp() async {
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
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Future<void> _sendResetOtp() async {
    setState(() {
      _error = null;
      _info = null;
    });
    try {
      await runBusy(
        context,
        message: '发送中…',
        task: () => AuthService.instance.sendPasswordResetOtp(_email.text),
      );
      if (!mounted) return;
      setState(() {
        _flow = _AuthFlow.reset;
        _otp.clear();
        _newPassword.clear();
        _confirmPassword.clear();
        _info = '若该邮箱已注册，验证码将发送到邮箱';
      });
      _startCooldown();
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Future<void> _resendResetOtp() async {
    if (_cooldown > 0) return;
    setState(() => _error = null);
    try {
      await runBusy(
        context,
        message: '发送中…',
        task: () => AuthService.instance.sendPasswordResetOtp(_email.text),
      );
      if (!mounted) return;
      setState(() => _info = '验证码已重新发送');
      _startCooldown();
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Future<void> _submitReset() async {
    setState(() {
      _error = null;
      _info = null;
    });
    final p1 = _newPassword.text.trim();
    final p2 = _confirmPassword.text.trim();
    if (p1.length < 6) {
      setState(() => _error = '新密码至少 6 位');
      return;
    }
    if (p1 != p2) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    try {
      await runBusy(
        context,
        message: '正在重置…',
        task: () => AuthService.instance.resetPasswordWithOtp(
          email: _email.text,
          token: _otp.text,
          newPassword: p1,
        ),
      );
      if (!mounted) return;
      await _afterAuthSuccess();
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    }
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    required VoidCallback onToggle,
    List<String>? autofillHints,
    VoidCallback? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofillHints: autofillHints,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: obscure ? '显示密码' : '隐藏密码',
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
      onSubmitted: (_) => onSubmitted?.call(),
    );
  }

  Widget _messageBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_info != null) ...[
          const SizedBox(height: 12),
          Text(_info!, style: TextStyle(color: Colors.grey.shade700)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Colors.red.shade700)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_flow == _AuthFlow.signupOtp) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('验证邮箱'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _flow = _AuthFlow.tabs;
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
                hintText: '邮件中的验证码',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _verifySignupOtp(),
            ),
            _messageBlock(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _verifySignupOtp,
              child: const Text('完成验证'),
            ),
            TextButton(
              onPressed: _cooldown > 0 ? null : _resendSignupOtp,
              child: Text(
                _cooldown > 0 ? '$_cooldown 秒后可重发' : '重发验证码',
              ),
            ),
          ],
        ),
      );
    }

    if (_flow == _AuthFlow.forgot) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('忘记密码'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _flow = _AuthFlow.tabs;
              _error = null;
              _info = null;
            }),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '输入注册邮箱，我们将发送验证码用于重置密码。',
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
              onSubmitted: (_) => _sendResetOtp(),
            ),
            _messageBlock(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _sendResetOtp,
              child: const Text('发送验证码'),
            ),
          ],
        ),
      );
    }

    if (_flow == _AuthFlow.reset) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('重置密码'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() {
              _flow = _AuthFlow.forgot;
              _otp.clear();
              _newPassword.clear();
              _confirmPassword.clear();
              _error = null;
            }),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '验证码已发至 ${_email.text.trim()}。请输入验证码并设置新密码。',
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
                hintText: '邮件中的验证码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _passwordField(
              controller: _newPassword,
              label: '新密码',
              obscure: _obscureNew,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
              autofillHints: const [AutofillHints.newPassword],
            ),
            const SizedBox(height: 16),
            _passwordField(
              controller: _confirmPassword,
              label: '确认新密码',
              obscure: _obscureNew,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: _submitReset,
            ),
            _messageBlock(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitReset,
              child: const Text('确认重置'),
            ),
            TextButton(
              onPressed: _cooldown > 0 ? null : _resendResetOtp,
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
              _passwordField(
                controller: _password,
                label: '密码',
                obscure: _obscure,
                onToggle: () => setState(() => _obscure = !_obscure),
                autofillHints: const [AutofillHints.password],
                onSubmitted: _login,
              ),
              if (_error != null && _tabs.index == 0) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() {
                    _flow = _AuthFlow.forgot;
                    _error = null;
                    _info = null;
                    _otp.clear();
                    _newPassword.clear();
                    _confirmPassword.clear();
                  }),
                  child: const Text('忘记密码？'),
                ),
              ),
              const SizedBox(height: 8),
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
              _passwordField(
                controller: _password,
                label: '密码',
                obscure: _obscure,
                onToggle: () => setState(() => _obscure = !_obscure),
                autofillHints: const [AutofillHints.newPassword],
                onSubmitted: _register,
              ),
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
                onPressed: _goVerifyExisting,
                child: const Text('已注册未验证？去验证邮箱'),
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
