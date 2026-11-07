import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

class _AuthPageState extends State<AuthPage> {
  late bool _register;
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _register = widget.initialRegister;
  }

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final phone = _phone.text.trim();
    final password = _password.text;
    if (_register && password != _confirm.text) {
      setState(() => _error = '两次密码不一致');
      return;
    }
    final store = context.read<AppStore>();
    final auth = AuthService.instance;
    try {
      final hadLocal = await AppDatabase.instance.hasLocalBusinessData();
      if (!mounted) return;

      await runBusy(
        context,
        message: _register ? '正在注册…' : '正在登录…',
        task: () async {
          if (_register) {
            await auth.register(phone: phone, password: password);
          } else {
            await auth.login(phone: phone, password: password);
          }
        },
      );
      if (!mounted) return;

      var claim = false;
      if (hadLocal) {
        claim = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('本机已有房源数据'),
                content: const Text(
                  '是否将本机现有物业/租约归属到当前账号并上传？\n'
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
        title: Text(_register ? '注册房东' : '登录'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _register ? '手机号注册后即可管理自己的房源与账单' : '使用注册时的手机号与密码登录',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade700,
                ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: '手机号',
              hintText: '11 位手机号',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              hintText: '至少 6 位',
              border: OutlineInputBorder(),
            ),
          ),
          if (_register) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '确认密码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submit,
            child: Text(_register ? '注册' : '登录'),
          ),
          TextButton(
            onPressed: () => setState(() {
              _register = !_register;
              _error = null;
            }),
            child: Text(_register ? '已有账号？去登录' : '没有账号？去注册'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('以后再说，先逛逛'),
          ),
          const SizedBox(height: 12),
          Text(
            '后续将支持短信验证码 / 微信登录。当前为测试版：密码直连云端校验。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                ),
          ),
        ],
      ),
    );
  }
}
