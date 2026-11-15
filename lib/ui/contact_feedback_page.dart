import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/baked_env.dart';

const _supportEmail = 'support@tihu.app';

class _FeedbackItem {
  _FeedbackItem({
    required this.id,
    required this.body,
    required this.contact,
    required this.createdAt,
  });

  final String id;
  final String body;
  final String contact;
  final DateTime createdAt;

  factory _FeedbackItem.fromMap(Map<String, dynamic> m) {
    final raw = m['created_at'];
    return _FeedbackItem(
      id: '${m['id'] ?? ''}',
      body: '${m['body'] ?? ''}',
      contact: '${m['contact'] ?? ''}',
      createdAt: DateTime.tryParse('$raw')?.toLocal() ?? DateTime.now(),
    );
  }
}

/// 联系与反馈：邮箱 + 提交反馈 / 历史列表（Supabase feedback 表 + RLS）。
class ContactFeedbackPage extends StatefulWidget {
  const ContactFeedbackPage({super.key});

  @override
  State<ContactFeedbackPage> createState() => _ContactFeedbackPageState();
}

class _ContactFeedbackPageState extends State<ContactFeedbackPage> {
  bool _feedbackView = false;

  @override
  Widget build(BuildContext context) {
    if (_feedbackView) {
      return _FeedbackComposePage(
        onBack: () => setState(() => _feedbackView = false),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('联系与反馈')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            '使用问题、账号与上架相关，可通过下方方式联系我们，或提交应用内反馈。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('邮箱'),
            subtitle: const Text(_supportEmail),
            trailing: IconButton(
              tooltip: '复制',
              icon: const Icon(Icons.copy_outlined, size: 20),
              onPressed: () async {
                await Clipboard.setData(
                  const ClipboardData(text: _supportEmail),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制邮箱')),
                );
              },
            ),
          ),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('提交反馈'),
            subtitle: const Text('意见与问题'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _feedbackView = true),
          ),
        ],
      ),
    );
  }
}

class _FeedbackComposePage extends StatefulWidget {
  const _FeedbackComposePage({required this.onBack});

  final VoidCallback onBack;

  @override
  State<_FeedbackComposePage> createState() => _FeedbackComposePageState();
}

class _FeedbackComposePageState extends State<_FeedbackComposePage> {
  final _bodyCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<_FeedbackItem> _items = const [];

  SupabaseClient get _client => Supabase.instance.client;
  String? get _uid => _client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _bodyCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!BakedEnv.hasSupabase || _uid == null) {
      setState(() {
        _loading = false;
        _items = const [];
        _error = _uid == null ? '请先登录后再提交反馈' : null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _client
          .from('feedback')
          .select('id, body, contact, created_at')
          .eq('user_id', _uid!)
          .order('created_at', ascending: false)
          .limit(100);
      final list = <_FeedbackItem>[];
      for (final r in (rows as List)) {
        list.add(_FeedbackItem.fromMap(Map<String, dynamic>.from(r as Map)));
      }
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _submit() async {
    final text = _bodyCtrl.text.trim();
    if (text.isEmpty) return;
    if (_uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final row = await _client
          .from('feedback')
          .insert({
            'user_id': _uid,
            'body': text,
            'contact': _contactCtrl.text.trim(),
          })
          .select('id, body, contact, created_at')
          .single();
      final item = _FeedbackItem.fromMap(Map<String, dynamic>.from(row as Map));
      if (!mounted) return;
      setState(() {
        _bodyCtrl.clear();
        _items = [item, ..._items];
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交反馈')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交失败：$e')),
      );
    }
  }

  String _fmt(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的反馈'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            '描述问题或建议，我们会尽快查看。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _bodyCtrl,
            maxLines: 5,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: '反馈内容',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contactCtrl,
            decoration: const InputDecoration(
              labelText: '联系方式（可选）',
              hintText: '邮箱 / 微信号等',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _bodyCtrl.text.trim().isEmpty ? null : _submit,
            child: Text(_busy ? '提交中…' : '提交反馈'),
          ),
          const SizedBox(height: 28),
          Text('已提交', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
          else if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('还没有反馈记录'),
            )
          else
            ..._items.map(
              (it) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        _fmt(it.createdAt),
                        if (it.contact.isNotEmpty) it.contact,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(it.body),
                    const Divider(height: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
