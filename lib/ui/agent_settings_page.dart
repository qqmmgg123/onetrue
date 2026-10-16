import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_settings.dart';
import '../sync/sync_settings.dart';

class AgentSettingsPage extends StatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  final _groqApiKey = TextEditingController();
  final _asrBaseUrl = TextEditingController();
  final _asrApiKey = TextEditingController();
  final _asrModel = TextEditingController();
  final _supabaseUrl = TextEditingController();
  final _supabaseAnon = TextEditingController();
  final _ownerId = TextEditingController();
  bool _useLlm = false;
  bool _useCloudAsr = true;
  bool _syncEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = AgentSettings.instance;
    final sync = SyncSettings.instance;
    await s.load();
    await sync.load();
    if (!mounted) return;
    setState(() {
      _baseUrl.text = s.baseUrl;
      _apiKey.text = s.apiKey;
      _model.text = s.model;
      _groqApiKey.text = s.groqApiKey;
      _asrBaseUrl.text = s.asrBaseUrl;
      _asrApiKey.text = s.asrApiKey;
      _asrModel.text = s.asrModel;
      _useLlm = s.useLlm;
      _useCloudAsr = s.useCloudAsr;
      _syncEnabled = sync.enabled;
      _supabaseUrl.text = sync.supabaseUrl;
      _supabaseAnon.text = sync.anonKey;
      _ownerId.text = sync.ownerId;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _groqApiKey.dispose();
    _asrBaseUrl.dispose();
    _asrApiKey.dispose();
    _asrModel.dispose();
    _supabaseUrl.dispose();
    _supabaseAnon.dispose();
    _ownerId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话 / Agent 设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用大模型'),
                  subtitle: const Text('关闭时用本地说法解析，无需联网 Key'),
                  value: _useLlm,
                  onChanged: (v) => setState(() => _useLlm = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: '对话 API Base URL',
                    hintText: 'https://api.deepseek.com/v1',
                  ),
                ),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '对话模型名',
                    hintText: 'deepseek-chat',
                  ),
                ),
                TextField(
                  controller: _apiKey,
                  decoration: const InputDecoration(
                    labelText: '对话 API Key',
                    hintText: 'sk-...',
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                Text('语音输入', style: Theme.of(context).textTheme.titleSmall),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('云端语音转写（级联）'),
                  subtitle: const Text(
                    '优先 Groq Whisper（5秒）→ SenseVoice（5秒）→ 系统语音（若可用）',
                  ),
                  value: _useCloudAsr,
                  onChanged: (v) => setState(() => _useCloudAsr = v),
                ),
                TextField(
                  controller: _groqApiKey,
                  decoration: const InputDecoration(
                    labelText: 'Groq API Key（第一优先）',
                    hintText: 'console.groq.com 的 gsk-...',
                  ),
                  obscureText: true,
                ),
                TextField(
                  controller: _asrBaseUrl,
                  decoration: const InputDecoration(
                    labelText: 'SenseVoice Base URL（第二优先）',
                    hintText: 'https://api.siliconflow.cn/v1',
                  ),
                ),
                TextField(
                  controller: _asrModel,
                  decoration: const InputDecoration(
                    labelText: 'SenseVoice 模型名',
                    hintText: 'FunAudioLLM/SenseVoiceSmall',
                  ),
                ),
                TextField(
                  controller: _asrApiKey,
                  decoration: const InputDecoration(
                    labelText: '硅基流动 API Key',
                    hintText: 'sk-...',
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                Text(
                  '级联顺序：\n'
                  '1) Groq whisper-large-v3-turbo（≤5秒）\n'
                  '2) 硅基 SenseVoiceSmall（≤5秒）\n'
                  '3) 系统自带语音识别（非大模型；手机有才用）\n'
                  '任一步超时/额度不足/报错则试下一步。\n'
                  'Key 只存在本机。Groq 需能访问国际网络。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Text('数据同步（Supabase）',
                    style: Theme.of(context).textTheme.titleSmall),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启静默同步'),
                  subtitle: const Text(
                    '本地仍是主库；打开 App 后台推拉。当前同步：小区/房间/租户/租约/附加费',
                  ),
                  value: _syncEnabled,
                  onChanged: (v) => setState(() => _syncEnabled = v),
                ),
                TextField(
                  controller: _supabaseUrl,
                  decoration: const InputDecoration(
                    labelText: 'Supabase Project URL',
                    hintText: 'https://xxxx.supabase.co',
                  ),
                ),
                TextField(
                  controller: _supabaseAnon,
                  decoration: const InputDecoration(
                    labelText: 'anon public Key',
                    hintText: 'eyJ...',
                  ),
                  obscureText: true,
                ),
                TextField(
                  controller: _ownerId,
                  decoration: const InputDecoration(
                    labelText: '本机 owner_id（多端请保持一致）',
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _ownerId.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('owner_id 已复制')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制 owner_id'),
                  ),
                ),
                Text(
                  '在 Supabase SQL Editor 执行仓库里 supabase/schema.sql，'
                  '再填 URL 与 anon key。多台手机要共享数据时，把同一 owner_id 粘到每台。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () async {
                    await AgentSettings.instance.save(
                      baseUrl: _baseUrl.text,
                      apiKey: _apiKey.text,
                      model: _model.text,
                      useLlm: _useLlm,
                      useCloudAsr: _useCloudAsr,
                      groqApiKey: _groqApiKey.text,
                      asrBaseUrl: _asrBaseUrl.text,
                      asrModel: _asrModel.text,
                      asrApiKey: _asrApiKey.text,
                    );
                    await SyncSettings.instance.save(
                      enabled: _syncEnabled,
                      supabaseUrl: _supabaseUrl.text,
                      anonKey: _supabaseAnon.text,
                      ownerId: _ownerId.text,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已保存')),
                      );
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
    );
  }
}
