import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_settings.dart';
import '../agent/llm_providers.dart';
import '../config/baked_env.dart';
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
  final _zhipuKey = TextEditingController();
  final _zhipuBase = TextEditingController();
  final _zhipuChatModel = TextEditingController();
  final _baiduLlmKey = TextEditingController();
  final _baiduLlmBase = TextEditingController();
  final _baiduLlmModel = TextEditingController();
  final _siliconChatModel = TextEditingController();
  final _oneApiBase = TextEditingController();
  final _oneApiKey = TextEditingController();
  final _oneApiModel = TextEditingController();
  final _groqApiKey = TextEditingController();
  final _asrBaseUrl = TextEditingController();
  final _asrApiKey = TextEditingController();
  final _asrModel = TextEditingController();
  final _databaseUrl = TextEditingController();
  final _ownerId = TextEditingController();
  String _llmProvider = LlmProviderId.auto;
  bool _useLlm = false;
  bool _useCloudAsr = true;
  bool _syncEnabled = false;
  bool _loading = true;
  bool _bundled = false;
  bool _showDeepseek = false;

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
      _bundled = BakedEnv.hasBundle;
      _llmProvider = s.llmProvider;
      _baseUrl.text = s.baseUrl;
      _apiKey.text = s.apiKey;
      _model.text = s.model;
      _zhipuKey.text = s.zhipuApiKey;
      _zhipuBase.text = s.zhipuBaseUrl;
      _zhipuChatModel.text = s.zhipuChatModel;
      _baiduLlmKey.text = s.baiduLlmApiKey;
      _baiduLlmBase.text = s.baiduLlmBaseUrl;
      _baiduLlmModel.text = s.baiduLlmModel;
      _siliconChatModel.text = s.siliconChatModel;
      _oneApiBase.text = s.oneApiBaseUrl;
      _oneApiKey.text = s.oneApiKey;
      _oneApiModel.text = s.oneApiModel;
      _groqApiKey.text = s.groqApiKey;
      _asrBaseUrl.text = s.asrBaseUrl;
      _asrApiKey.text = s.asrApiKey;
      _asrModel.text = s.asrModel;
      _useLlm = s.useLlm;
      _useCloudAsr = s.useCloudAsr;
      _syncEnabled = sync.enabled;
      _databaseUrl.text = sync.databaseUrl;
      _ownerId.text = sync.ownerId;
      _showDeepseek = s.llmProvider == LlmProviderId.deepseek;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _zhipuKey.dispose();
    _zhipuBase.dispose();
    _zhipuChatModel.dispose();
    _baiduLlmKey.dispose();
    _baiduLlmBase.dispose();
    _baiduLlmModel.dispose();
    _siliconChatModel.dispose();
    _oneApiBase.dispose();
    _oneApiKey.dispose();
    _oneApiModel.dispose();
    _groqApiKey.dispose();
    _asrBaseUrl.dispose();
    _asrApiKey.dispose();
    _asrModel.dispose();
    _databaseUrl.dispose();
    _ownerId.dispose();
    super.dispose();
  }

  String get _providerHint {
    switch (_llmProvider) {
      case LlmProviderId.auto:
        return BakedEnv.hasOneApi || _oneApiBase.text.trim().isNotEmpty
            ? '已配 One API 时只走网关；否则智谱 → 百度 → 硅基自动切换'
            : '自动：智谱 → 百度 → 硅基（失败才换下一家）';
      case LlmProviderId.zhipu:
        return '仅用智谱 glm-4-flash（免费档，工具调用较稳）';
      case LlmProviderId.baidu:
        return '仅用百度千帆（需 BAIDU_LLM_API_KEY）';
      case LlmProviderId.silicon:
        return '仅用硅基流动（复用 ASR_API_KEY）';
      case LlmProviderId.oneapi:
        return '仅用自建 One API / New API 网关';
      case LlmProviderId.deepseek:
        return 'DeepSeek 按量付费';
      default:
        return '';
    }
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
                if (_bundled) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '服务商配置已随安装包内置（打包时来自 supabase/env.local）。\n'
                        '同步数据库：Neon（直连 Postgres）。手机上只需开关与选择对话厂商。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用大模型'),
                  subtitle: Text(
                    _bundled && BakedEnv.hasAnyChatLlmKey
                        ? '已内置对话 Key（免费级联或网关）'
                        : '关闭时用本地说法解析，无需联网 Key',
                  ),
                  value: _useLlm,
                  onChanged: (v) => setState(() => _useLlm = v),
                ),
                const SizedBox(height: 8),
                Text('对话模型', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  value: LlmProviderId.visibleChoices.contains(_llmProvider) ||
                          _llmProvider == LlmProviderId.deepseek
                      ? _llmProvider
                      : LlmProviderId.auto,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    ...LlmProviderId.visibleChoices.map(
                      (id) => DropdownMenuItem(
                        value: id,
                        child: Text(LlmProviderId.label(id)),
                      ),
                    ),
                    if (_showDeepseek)
                      DropdownMenuItem(
                        value: LlmProviderId.deepseek,
                        child: Text(LlmProviderId.label(LlmProviderId.deepseek)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _llmProvider = v);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 8),
                  child: Text(
                    _providerHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade700,
                        ),
                  ),
                ),
                if (!_bundled) ...[
                  if (_llmProvider == LlmProviderId.zhipu ||
                      _llmProvider == LlmProviderId.auto) ...[
                    TextField(
                      controller: _zhipuKey,
                      decoration: const InputDecoration(
                        labelText: '智谱 API Key',
                        hintText: 'https://open.bigmodel.cn',
                      ),
                      obscureText: true,
                    ),
                    TextField(
                      controller: _zhipuChatModel,
                      decoration: const InputDecoration(
                        labelText: '智谱对话模型',
                        hintText: 'glm-4-flash',
                      ),
                    ),
                  ],
                  if (_llmProvider == LlmProviderId.baidu ||
                      _llmProvider == LlmProviderId.auto) ...[
                    TextField(
                      controller: _baiduLlmKey,
                      decoration: const InputDecoration(
                        labelText: '百度千帆 API Key（对话）',
                        hintText: 'Bearer，与 ASR 的 AK/SK 不同',
                      ),
                      obscureText: true,
                    ),
                    TextField(
                      controller: _baiduLlmModel,
                      decoration: const InputDecoration(
                        labelText: '百度对话模型',
                        hintText: 'ernie-speed-8k',
                      ),
                    ),
                  ],
                  if (_llmProvider == LlmProviderId.silicon ||
                      _llmProvider == LlmProviderId.auto) ...[
                    TextField(
                      controller: _asrApiKey,
                      decoration: const InputDecoration(
                        labelText: '硅基 API Key（对话/ASR 共用）',
                      ),
                      obscureText: true,
                    ),
                    TextField(
                      controller: _siliconChatModel,
                      decoration: const InputDecoration(
                        labelText: '硅基对话模型',
                        hintText: 'Qwen/Qwen2.5-7B-Instruct',
                      ),
                    ),
                  ],
                  if (_llmProvider == LlmProviderId.oneapi ||
                      _llmProvider == LlmProviderId.auto) ...[
                    TextField(
                      controller: _oneApiBase,
                      decoration: const InputDecoration(
                        labelText: 'One API Base URL',
                        hintText: 'https://your-host/v1',
                      ),
                    ),
                    TextField(
                      controller: _oneApiKey,
                      decoration: const InputDecoration(
                        labelText: 'One API Key',
                      ),
                      obscureText: true,
                    ),
                    TextField(
                      controller: _oneApiModel,
                      decoration: const InputDecoration(
                        labelText: 'One API 模型（可空=网关默认）',
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ExpansionTile(
                    initiallyExpanded: _showDeepseek,
                    title: const Text('高级 · DeepSeek（付费）'),
                    subtitle: const Text('默认隐藏；需要时再启用'),
                    onExpansionChanged: (open) {
                      setState(() {
                        _showDeepseek = open;
                        if (open && _llmProvider != LlmProviderId.deepseek) {
                          // 展开不自动切换；用户可在下拉里选 DeepSeek
                        }
                      });
                    },
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('使用 DeepSeek 对话'),
                        value: _llmProvider == LlmProviderId.deepseek,
                        onChanged: (v) {
                          setState(() {
                            _llmProvider = v
                                ? LlmProviderId.deepseek
                                : LlmProviderId.auto;
                            _showDeepseek = true;
                          });
                        },
                      ),
                      TextField(
                        controller: _baseUrl,
                        decoration: const InputDecoration(
                          labelText: 'DeepSeek Base URL',
                          hintText: 'https://api.deepseek.com/v1',
                        ),
                      ),
                      TextField(
                        controller: _model,
                        decoration: const InputDecoration(
                          labelText: 'DeepSeek 模型',
                          hintText: 'deepseek-chat',
                        ),
                      ),
                      TextField(
                        controller: _apiKey,
                        decoration: const InputDecoration(
                          labelText: 'DeepSeek API Key',
                        ),
                        obscureText: true,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Text('语音输入', style: Theme.of(context).textTheme.titleSmall),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('云端语音转写（级联）'),
                  subtitle: Text(
                    _bundled
                        ? '百度→Groq→SenseVoice；失败后再离线 Vosk / 系统语音。'
                        : '开启后按百度→Groq→硅基顺序尝试',
                  ),
                  value: _useCloudAsr,
                  onChanged: (v) => setState(() => _useCloudAsr = v),
                ),
                if (!_bundled) ...[
                  TextField(
                    controller: _groqApiKey,
                    decoration: const InputDecoration(
                      labelText: 'Groq API Key（语音）',
                    ),
                    obscureText: true,
                  ),
                  TextField(
                    controller: _asrBaseUrl,
                    decoration: const InputDecoration(
                      labelText: '硅基 ASR Base URL',
                      hintText: 'https://api.siliconflow.cn/v1',
                    ),
                  ),
                  TextField(
                    controller: _asrModel,
                    decoration: const InputDecoration(
                      labelText: 'SenseVoice 模型',
                      hintText: 'FunAudioLLM/SenseVoiceSmall',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text('Neon 同步', style: Theme.of(context).textTheme.titleSmall),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用云端同步'),
                  value: _syncEnabled,
                  onChanged: (v) => setState(() => _syncEnabled = v),
                ),
                if (!BakedEnv.hasSyncDb)
                  TextField(
                    controller: _databaseUrl,
                    decoration: const InputDecoration(
                      labelText: 'Neon DATABASE_URL',
                      hintText:
                          'postgresql://user:pass@ep-xxx.region.aws.neon.tech/neondb?sslmode=require',
                    ),
                    obscureText: true,
                    maxLines: 2,
                  ),
                TextField(
                  controller: _ownerId,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'owner_id（登录账号自动绑定）',
                    helperText: '多端用同一手机号登录即可同步；游客无 owner',
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _ownerId.text.trim().isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: _ownerId.text),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('owner_id 已复制')),
                            );
                          },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制 owner_id'),
                  ),
                ),
                if (!_bundled)
                  Text(
                    '开发调试可在此填写 DATABASE_URL；正式打包请写 supabase/env.local 后用 build_apk.ps1。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () async {
                    await AgentSettings.instance.save(
                      llmProvider: _llmProvider,
                      baseUrl: _baseUrl.text,
                      apiKey: _apiKey.text,
                      model: _model.text,
                      useLlm: _useLlm,
                      useCloudAsr: _useCloudAsr,
                      groqApiKey: _groqApiKey.text,
                      asrBaseUrl: _asrBaseUrl.text,
                      asrModel: _asrModel.text,
                      asrApiKey: _asrApiKey.text,
                      siliconChatModel: _siliconChatModel.text,
                      zhipuApiKey: _zhipuKey.text,
                      zhipuBaseUrl: _zhipuBase.text,
                      zhipuChatModel: _zhipuChatModel.text,
                      baiduLlmApiKey: _baiduLlmKey.text,
                      baiduLlmBaseUrl: _baiduLlmBase.text,
                      baiduLlmModel: _baiduLlmModel.text,
                      oneApiBaseUrl: _oneApiBase.text,
                      oneApiKey: _oneApiKey.text,
                      oneApiModel: _oneApiModel.text,
                    );
                    await SyncSettings.instance.save(
                      enabled: _syncEnabled &&
                          SyncSettings.instance.ownerId.trim().isNotEmpty,
                      databaseUrl: _databaseUrl.text,
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
