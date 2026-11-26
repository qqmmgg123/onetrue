import 'package:flutter/material.dart';

import '../social/social_api.dart';
import '../social/social_models.dart';
import 'memo_quill_preview.dart';
import 'note_quill.dart';

/// 备忘 L2 侧栏：谏言列表（对齐 Web MemoAdmonitionSide）
class AdmonitionSidePanel extends StatefulWidget {
  const AdmonitionSidePanel({super.key});

  @override
  State<AdmonitionSidePanel> createState() => _AdmonitionSidePanelState();
}

class _AdmonitionSidePanelState extends State<AdmonitionSidePanel> {
  List<AdmonitionItem> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SocialApi.instance.fetchAdmonitions();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Text(
            '谏言',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF6B6B6B),
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _loading
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 48),
                      Center(child: Text('加载中…')),
                    ],
                  )
                : _error != null
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text('加载失败', style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Text(_error!, style: const TextStyle(color: Color(0xFF888888))),
                        ],
                      )
                    : _items.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 48),
                              Center(
                                child: Text(
                                  '暂无谏言',
                                  style: TextStyle(color: Color(0xFF6B6B6B)),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                            itemCount: _items.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final n = _items[i];
                              final title = n.title.trim();
                              return Container(
                                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFEBEBEB),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    DefaultTextStyle(
                                      style: const TextStyle(
                                        fontSize: 13,
                                        height: 1.65,
                                        color: Color(0xFF1A1A1A),
                                      ),
                                      child: MemoQuillPreview(
                                        body: n.body,
                                        format: n.format.isEmpty
                                            ? kStoredQuill
                                            : n.format,
                                      ),
                                    ),
                                    if (title.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        '— $title',
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF6B6B6B),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
          ),
        ),
      ],
    );
  }
}
