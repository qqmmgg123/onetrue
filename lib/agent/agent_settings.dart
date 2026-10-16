import 'package:shared_preferences/shared_preferences.dart';

class AgentSettings {
  AgentSettings._();
  static final AgentSettings instance = AgentSettings._();

  static const _kBaseUrl = 'agent_base_url';
  static const _kApiKey = 'agent_api_key';
  static const _kModel = 'agent_model';
  static const _kUseLlm = 'agent_use_llm';
  static const _kUseCloudAsr = 'agent_use_cloud_asr';
  static const _kAsrModel = 'agent_asr_model';
  static const _kAsrBaseUrl = 'agent_asr_base_url';
  static const _kAsrApiKey = 'agent_asr_api_key';
  static const _kGroqApiKey = 'agent_groq_api_key';
  static const _kGroqBaseUrl = 'agent_groq_base_url';
  static const _kGroqAsrModel = 'agent_groq_asr_model';

  String baseUrl = 'https://api.deepseek.com/v1';
  String apiKey = '';
  String model = 'deepseek-chat';
  bool useLlm = false;

  /// 开启后按住说话走云端级联：Groq → SenseVoice →（下次）系统语音。
  bool useCloudAsr = true;

  /// 硅基流动 SenseVoice（第二优先）
  String asrModel = 'FunAudioLLM/SenseVoiceSmall';
  String asrBaseUrl = 'https://api.siliconflow.cn/v1';
  String asrApiKey = '';

  /// Groq Whisper（第一优先）
  String groqApiKey = '';
  String groqBaseUrl = 'https://api.groq.com/openai/v1';
  String groqAsrModel = 'whisper-large-v3-turbo';

  bool get hasLlm => useLlm && apiKey.trim().isNotEmpty;

  String get effectiveAsrBaseUrl {
    final v = asrBaseUrl.trim();
    if (v.isNotEmpty) return v;
    return baseUrl;
  }

  String get effectiveAsrApiKey {
    final v = asrApiKey.trim();
    if (v.isNotEmpty) return v;
    return apiKey.trim();
  }

  bool get hasGroqAsr =>
      useCloudAsr && groqApiKey.trim().isNotEmpty;

  bool get hasSenseVoiceAsr =>
      useCloudAsr && effectiveAsrApiKey.isNotEmpty;

  bool get hasCloudAsr => hasGroqAsr || hasSenseVoiceAsr;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_kBaseUrl) ?? baseUrl;
    apiKey = prefs.getString(_kApiKey) ?? '';
    model = prefs.getString(_kModel) ?? model;
    useLlm = prefs.getBool(_kUseLlm) ?? false;
    useCloudAsr = prefs.getBool(_kUseCloudAsr) ?? true;
    asrModel = prefs.getString(_kAsrModel) ?? asrModel;
    asrBaseUrl = prefs.getString(_kAsrBaseUrl) ?? asrBaseUrl;
    asrApiKey = prefs.getString(_kAsrApiKey) ?? '';
    groqApiKey = prefs.getString(_kGroqApiKey) ?? '';
    groqBaseUrl = prefs.getString(_kGroqBaseUrl) ?? groqBaseUrl;
    groqAsrModel = prefs.getString(_kGroqAsrModel) ?? groqAsrModel;
  }

  Future<void> save({
    required String baseUrl,
    required String apiKey,
    required String model,
    required bool useLlm,
    bool? useCloudAsr,
    String? asrModel,
    String? asrBaseUrl,
    String? asrApiKey,
    String? groqApiKey,
    String? groqBaseUrl,
    String? groqAsrModel,
  }) async {
    this.baseUrl = baseUrl.trim().isEmpty
        ? 'https://api.deepseek.com/v1'
        : baseUrl.trim();
    this.apiKey = apiKey.trim();
    this.model = model.trim().isEmpty ? 'deepseek-chat' : model.trim();
    this.useLlm = useLlm;
    if (useCloudAsr != null) this.useCloudAsr = useCloudAsr;
    if (asrModel != null) {
      this.asrModel = asrModel.trim().isEmpty
          ? 'FunAudioLLM/SenseVoiceSmall'
          : asrModel.trim();
    }
    if (asrBaseUrl != null) {
      this.asrBaseUrl = asrBaseUrl.trim().isEmpty
          ? 'https://api.siliconflow.cn/v1'
          : asrBaseUrl.trim();
    }
    if (asrApiKey != null) this.asrApiKey = asrApiKey.trim();
    if (groqApiKey != null) this.groqApiKey = groqApiKey.trim();
    if (groqBaseUrl != null) {
      this.groqBaseUrl = groqBaseUrl.trim().isEmpty
          ? 'https://api.groq.com/openai/v1'
          : groqBaseUrl.trim();
    }
    if (groqAsrModel != null) {
      this.groqAsrModel = groqAsrModel.trim().isEmpty
          ? 'whisper-large-v3-turbo'
          : groqAsrModel.trim();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, this.baseUrl);
    await prefs.setString(_kApiKey, this.apiKey);
    await prefs.setString(_kModel, this.model);
    await prefs.setBool(_kUseLlm, this.useLlm);
    await prefs.setBool(_kUseCloudAsr, this.useCloudAsr);
    await prefs.setString(_kAsrModel, this.asrModel);
    await prefs.setString(_kAsrBaseUrl, this.asrBaseUrl);
    await prefs.setString(_kAsrApiKey, this.asrApiKey);
    await prefs.setString(_kGroqApiKey, this.groqApiKey);
    await prefs.setString(_kGroqBaseUrl, this.groqBaseUrl);
    await prefs.setString(_kGroqAsrModel, this.groqAsrModel);
  }
}
