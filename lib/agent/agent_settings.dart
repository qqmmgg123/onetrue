import 'package:shared_preferences/shared_preferences.dart';

import '../config/baked_env.dart';
import 'llm_providers.dart';

class AgentSettings {
  AgentSettings._();
  static final AgentSettings instance = AgentSettings._();

  static const _kProvider = 'agent_llm_provider';
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
  static const _kBaiduAsrApiKey = 'agent_baidu_asr_api_key';
  static const _kBaiduAsrSecretKey = 'agent_baidu_asr_secret_key';
  static const _kBaiduLlmApiKey = 'agent_baidu_llm_api_key';
  static const _kBaiduLlmBaseUrl = 'agent_baidu_llm_base_url';
  static const _kBaiduLlmModel = 'agent_baidu_llm_model';
  static const _kZhipuChatModel = 'agent_zhipu_chat_model';
  static const _kSiliconChatModel = 'agent_silicon_chat_model';
  static const _kOneApiBaseUrl = 'agent_one_api_base_url';
  static const _kOneApiKey = 'agent_one_api_key';
  static const _kOneApiModel = 'agent_one_api_model';
  static const _kGeminiApiKey = 'agent_gemini_api_key';
  static const _kGeminiVisionModel = 'agent_gemini_vision_model';
  static const _kZhipuApiKey = 'agent_zhipu_api_key';
  static const _kZhipuBaseUrl = 'agent_zhipu_base_url';
  static const _kZhipuVisionModel = 'agent_zhipu_vision_model';
  static const _kDeepseekVisionModel = 'agent_deepseek_vision_model';
  static const _kVisionBaseUrl = 'agent_vision_base_url';
  static const _kVisionApiKey = 'agent_vision_api_key';
  static const _kVisionModels = 'agent_vision_models';

  /// auto | zhipu | baidu | silicon | oneapi | deepseek
  String llmProvider = LlmProviderId.auto;

  /// DeepSeek（高级 / 付费）
  String baseUrl = LlmProviderDefaults.deepseekBase;
  String apiKey = '';
  String model = LlmProviderDefaults.deepseekModel;
  bool useLlm = false;

  /// 开启后按住说话走云端级联：百度 → Groq → SenseVoice → 系统语音。
  bool useCloudAsr = true;

  /// 硅基流动 SenseVoice（第三优先）
  String asrModel = 'FunAudioLLM/SenseVoiceSmall';
  String asrBaseUrl = LlmProviderDefaults.siliconBase;
  String asrApiKey = '';
  String siliconChatModel = LlmProviderDefaults.siliconModel;

  /// Groq Whisper（第二优先）
  String groqApiKey = '';
  String groqBaseUrl = 'https://api.groq.com/openai/v1';
  String groqAsrModel = 'whisper-large-v3-turbo';

  /// 百度智能云短语音（第一优先）
  String baiduAsrApiKey = '';
  String baiduAsrSecretKey = '';

  /// 百度千帆对话
  String baiduLlmApiKey = '';
  String baiduLlmBaseUrl = LlmProviderDefaults.baiduBase;
  String baiduLlmModel = LlmProviderDefaults.baiduModel;

  /// 附图理解
  String geminiApiKey = '';
  String geminiVisionModel = 'gemini-2.5-flash';
  String zhipuApiKey = '';
  String zhipuBaseUrl = LlmProviderDefaults.zhipuBase;
  String zhipuChatModel = LlmProviderDefaults.zhipuModel;
  String zhipuVisionModel = 'glm-4v-flash';
  String deepseekVisionModel = 'deepseek-flash';
  String visionBaseUrl = '';
  String visionApiKey = '';
  String visionModels =
      'deepseek-ai/DeepSeek-OCR,PaddlePaddle/PaddleOCR-VL-1.5';

  /// One API 网关
  String oneApiBaseUrl = '';
  String oneApiKey = '';
  String oneApiModel = '';

  bool get hasLlm => useLlm && resolveEndpoints().isNotEmpty;

  /// 当前实际将调用的模型名（用于上下文窗口估算）。
  String get effectiveChatModel {
    final eps = resolveEndpoints();
    if (eps.isEmpty) return model;
    final m = eps.first.model;
    if (m.isEmpty || m == 'default') return model;
    return m;
  }

  bool get hasGeminiVision => geminiApiKey.trim().isNotEmpty;

  bool get hasZhipuVision => zhipuApiKey.trim().isNotEmpty;

  bool get hasDeepseekVision =>
      apiKey.trim().isNotEmpty && baseUrl.toLowerCase().contains('deepseek');

  String get deepseekVisionBaseUrl {
    final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (b.contains('deepseek')) return b;
    return 'https://api.deepseek.com';
  }

  String get effectiveVisionBaseUrl {
    final v = visionBaseUrl.trim();
    if (v.isNotEmpty) return v;
    final asr = asrBaseUrl.trim();
    if (asr.isNotEmpty && asr.contains('siliconflow')) return asr;
    if (asr.isNotEmpty && !asr.contains('deepseek')) return asr;
    return LlmProviderDefaults.siliconBase;
  }

  String get effectiveVisionApiKey {
    final v = visionApiKey.trim();
    if (v.isNotEmpty) return v;
    return asrApiKey.trim();
  }

  bool get hasSiliconVision => effectiveVisionApiKey.isNotEmpty;

  List<String> get siliconVisionModels => visionModels
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

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

  bool get hasBaiduAsr =>
      useCloudAsr &&
      baiduAsrApiKey.trim().isNotEmpty &&
      baiduAsrSecretKey.trim().isNotEmpty;

  bool get hasGroqAsr => useCloudAsr && groqApiKey.trim().isNotEmpty;

  bool get hasSenseVoiceAsr => useCloudAsr && effectiveAsrApiKey.isNotEmpty;

  bool get hasCloudAsr => hasBaiduAsr || hasGroqAsr || hasSenseVoiceAsr;

  bool get providerKeysBundled => BakedEnv.hasBundle;

  bool get hasOneApiConfigured =>
      oneApiBaseUrl.trim().isNotEmpty && oneApiKey.trim().isNotEmpty;

  LlmEndpoint? get _zhipuEndpoint {
    final key = zhipuApiKey.trim();
    if (key.isEmpty) return null;
    return LlmEndpoint(
      id: LlmProviderId.zhipu,
      name: '智谱',
      baseUrl: zhipuBaseUrl.trim().isEmpty
          ? LlmProviderDefaults.zhipuBase
          : zhipuBaseUrl.trim(),
      apiKey: key,
      model: zhipuChatModel.trim().isEmpty
          ? LlmProviderDefaults.zhipuModel
          : zhipuChatModel.trim(),
    );
  }

  LlmEndpoint? get _baiduEndpoint {
    final key = baiduLlmApiKey.trim();
    if (key.isEmpty) return null;
    return LlmEndpoint(
      id: LlmProviderId.baidu,
      name: '百度千帆',
      baseUrl: baiduLlmBaseUrl.trim().isEmpty
          ? LlmProviderDefaults.baiduBase
          : baiduLlmBaseUrl.trim(),
      apiKey: key,
      model: baiduLlmModel.trim().isEmpty
          ? LlmProviderDefaults.baiduModel
          : baiduLlmModel.trim(),
    );
  }

  LlmEndpoint? get _siliconEndpoint {
    final key = asrApiKey.trim();
    if (key.isEmpty) return null;
    return LlmEndpoint(
      id: LlmProviderId.silicon,
      name: '硅基流动',
      baseUrl: asrBaseUrl.trim().isEmpty
          ? LlmProviderDefaults.siliconBase
          : asrBaseUrl.trim(),
      apiKey: key,
      model: siliconChatModel.trim().isEmpty
          ? LlmProviderDefaults.siliconModel
          : siliconChatModel.trim(),
    );
  }

  LlmEndpoint? get _oneApiEndpoint {
    if (!hasOneApiConfigured) return null;
    final m = oneApiModel.trim();
    return LlmEndpoint(
      id: LlmProviderId.oneapi,
      name: 'One API',
      baseUrl: oneApiBaseUrl.trim(),
      apiKey: oneApiKey.trim(),
      // 网关可空模型名时用占位，由网关默认渠道处理；仍要求非空以便 usable
      model: m.isEmpty ? 'default' : m,
    );
  }

  LlmEndpoint? get _deepseekEndpoint {
    final key = apiKey.trim();
    if (key.isEmpty) return null;
    return LlmEndpoint(
      id: LlmProviderId.deepseek,
      name: 'DeepSeek',
      baseUrl: baseUrl.trim().isEmpty
          ? LlmProviderDefaults.deepseekBase
          : baseUrl.trim(),
      apiKey: key,
      model: model.trim().isEmpty
          ? LlmProviderDefaults.deepseekModel
          : model.trim(),
    );
  }

  /// 按当前厂商模式返回有序可调端点（仅 usable）。
  List<LlmEndpoint> resolveEndpoints() {
    LlmEndpoint? one(String id) {
      switch (id) {
        case LlmProviderId.zhipu:
          return _zhipuEndpoint;
        case LlmProviderId.baidu:
          return _baiduEndpoint;
        case LlmProviderId.silicon:
          return _siliconEndpoint;
        case LlmProviderId.oneapi:
          return _oneApiEndpoint;
        case LlmProviderId.deepseek:
          return _deepseekEndpoint;
        default:
          return null;
      }
    }

    final mode = llmProvider.trim().isEmpty
        ? LlmProviderId.auto
        : llmProvider.trim();

    if (mode == LlmProviderId.auto) {
      // 有网关则只走网关；否则智谱 → 百度 → 硅基
      final gateway = _oneApiEndpoint;
      if (gateway != null && gateway.usable) return [gateway];
      return [
        _zhipuEndpoint,
        _baiduEndpoint,
        _siliconEndpoint,
      ].whereType<LlmEndpoint>().where((e) => e.usable).toList();
    }

    final ep = one(mode);
    if (ep != null && ep.usable) return [ep];
    return const [];
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    llmProvider = _pick(
      BakedEnv.llmProvider,
      prefs.getString(_kProvider),
      LlmProviderId.auto,
    );
    if (!LlmProviderId.visibleChoices.contains(llmProvider) &&
        llmProvider != LlmProviderId.deepseek) {
      llmProvider = LlmProviderId.auto;
    }

    baseUrl = _pick(BakedEnv.llmBaseUrl, prefs.getString(_kBaseUrl), baseUrl);
    apiKey = _pick(BakedEnv.llmApiKey, prefs.getString(_kApiKey), '');
    model = _pick(BakedEnv.llmModel, prefs.getString(_kModel), model);
    asrModel = _pick(BakedEnv.asrModel, prefs.getString(_kAsrModel), asrModel);
    asrBaseUrl =
        _pick(BakedEnv.asrBaseUrl, prefs.getString(_kAsrBaseUrl), asrBaseUrl);
    asrApiKey = _pick(BakedEnv.asrApiKey, prefs.getString(_kAsrApiKey), '');
    siliconChatModel = _pick(
      BakedEnv.siliconChatModel,
      prefs.getString(_kSiliconChatModel),
      siliconChatModel,
    );
    groqApiKey = _pick(BakedEnv.groqApiKey, prefs.getString(_kGroqApiKey), '');
    groqBaseUrl =
        _pick(BakedEnv.groqBaseUrl, prefs.getString(_kGroqBaseUrl), groqBaseUrl);
    groqAsrModel = _pick(
      BakedEnv.groqAsrModel,
      prefs.getString(_kGroqAsrModel),
      groqAsrModel,
    );
    baiduAsrApiKey = _pick(
      BakedEnv.baiduAsrApiKey,
      prefs.getString(_kBaiduAsrApiKey),
      '',
    );
    baiduAsrSecretKey = _pick(
      BakedEnv.baiduAsrSecretKey,
      prefs.getString(_kBaiduAsrSecretKey),
      '',
    );
    baiduLlmApiKey = _pick(
      BakedEnv.baiduLlmApiKey,
      prefs.getString(_kBaiduLlmApiKey),
      '',
    );
    baiduLlmBaseUrl = _pick(
      BakedEnv.baiduLlmBaseUrl,
      prefs.getString(_kBaiduLlmBaseUrl),
      baiduLlmBaseUrl,
    );
    baiduLlmModel = _pick(
      BakedEnv.baiduLlmModel,
      prefs.getString(_kBaiduLlmModel),
      baiduLlmModel,
    );
    oneApiBaseUrl = _pick(
      BakedEnv.oneApiBaseUrl,
      prefs.getString(_kOneApiBaseUrl),
      '',
    );
    oneApiKey = _pick(BakedEnv.oneApiKey, prefs.getString(_kOneApiKey), '');
    oneApiModel = _pick(
      BakedEnv.oneApiModel,
      prefs.getString(_kOneApiModel),
      '',
    );
    geminiApiKey = _pick(
      BakedEnv.geminiApiKey,
      prefs.getString(_kGeminiApiKey),
      '',
    );
    geminiVisionModel = _pick(
      BakedEnv.geminiVisionModel,
      prefs.getString(_kGeminiVisionModel),
      geminiVisionModel,
    );
    zhipuApiKey = _pick(
      BakedEnv.zhipuApiKey,
      prefs.getString(_kZhipuApiKey),
      '',
    );
    zhipuBaseUrl = _pick(
      BakedEnv.zhipuBaseUrl,
      prefs.getString(_kZhipuBaseUrl),
      zhipuBaseUrl,
    );
    zhipuChatModel = _pick(
      BakedEnv.zhipuChatModel,
      prefs.getString(_kZhipuChatModel),
      zhipuChatModel,
    );
    zhipuVisionModel = _pick(
      BakedEnv.zhipuVisionModel,
      prefs.getString(_kZhipuVisionModel),
      zhipuVisionModel,
    );
    deepseekVisionModel = _pick(
      BakedEnv.deepseekVisionModel,
      prefs.getString(_kDeepseekVisionModel),
      deepseekVisionModel,
    );
    visionBaseUrl = _pick(
      BakedEnv.visionBaseUrl,
      prefs.getString(_kVisionBaseUrl),
      '',
    );
    visionApiKey = _pick(
      BakedEnv.visionApiKey,
      prefs.getString(_kVisionApiKey),
      '',
    );
    visionModels = _pick(
      BakedEnv.visionModels,
      prefs.getString(_kVisionModels),
      visionModels,
    );

    if (prefs.containsKey(_kUseLlm)) {
      useLlm = prefs.getBool(_kUseLlm) ?? false;
    } else if (BakedEnv.hasAnyChatLlmKey) {
      useLlm = BakedEnv.useLlm;
    } else {
      useLlm = false;
    }

    if (prefs.containsKey(_kUseCloudAsr)) {
      useCloudAsr = prefs.getBool(_kUseCloudAsr) ?? true;
    } else {
      useCloudAsr = BakedEnv.useCloudAsr;
    }
  }

  static String _pick(String baked, String? pref, String fallback) {
    if (baked.trim().isNotEmpty) return baked.trim();
    if (pref != null && pref.trim().isNotEmpty) return pref.trim();
    return fallback;
  }

  Future<void> save({
    String? llmProvider,
    required String baseUrl,
    required String apiKey,
    required String model,
    required bool useLlm,
    bool? useCloudAsr,
    String? asrModel,
    String? asrBaseUrl,
    String? asrApiKey,
    String? siliconChatModel,
    String? groqApiKey,
    String? groqBaseUrl,
    String? groqAsrModel,
    String? baiduAsrApiKey,
    String? baiduAsrSecretKey,
    String? baiduLlmApiKey,
    String? baiduLlmBaseUrl,
    String? baiduLlmModel,
    String? zhipuApiKey,
    String? zhipuBaseUrl,
    String? zhipuChatModel,
    String? oneApiBaseUrl,
    String? oneApiKey,
    String? oneApiModel,
    String? geminiApiKey,
    String? geminiVisionModel,
    String? visionBaseUrl,
    String? visionApiKey,
    String? visionModels,
  }) async {
    if (llmProvider != null && llmProvider.trim().isNotEmpty) {
      this.llmProvider = llmProvider.trim();
    }

    if (!BakedEnv.hasBundle) {
      this.baseUrl = baseUrl.trim().isEmpty
          ? LlmProviderDefaults.deepseekBase
          : baseUrl.trim();
      this.apiKey = apiKey.trim();
      this.model = model.trim().isEmpty
          ? LlmProviderDefaults.deepseekModel
          : model.trim();
      if (asrModel != null) {
        this.asrModel = asrModel.trim().isEmpty
            ? 'FunAudioLLM/SenseVoiceSmall'
            : asrModel.trim();
      }
      if (asrBaseUrl != null) {
        this.asrBaseUrl = asrBaseUrl.trim().isEmpty
            ? LlmProviderDefaults.siliconBase
            : asrBaseUrl.trim();
      }
      if (asrApiKey != null) this.asrApiKey = asrApiKey.trim();
      if (siliconChatModel != null) {
        this.siliconChatModel = siliconChatModel.trim().isEmpty
            ? LlmProviderDefaults.siliconModel
            : siliconChatModel.trim();
      }
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
      if (baiduAsrApiKey != null) {
        this.baiduAsrApiKey = baiduAsrApiKey.trim();
      }
      if (baiduAsrSecretKey != null) {
        this.baiduAsrSecretKey = baiduAsrSecretKey.trim();
      }
      if (baiduLlmApiKey != null) this.baiduLlmApiKey = baiduLlmApiKey.trim();
      if (baiduLlmBaseUrl != null) {
        this.baiduLlmBaseUrl = baiduLlmBaseUrl.trim().isEmpty
            ? LlmProviderDefaults.baiduBase
            : baiduLlmBaseUrl.trim();
      }
      if (baiduLlmModel != null) {
        this.baiduLlmModel = baiduLlmModel.trim().isEmpty
            ? LlmProviderDefaults.baiduModel
            : baiduLlmModel.trim();
      }
      if (zhipuApiKey != null) this.zhipuApiKey = zhipuApiKey.trim();
      if (zhipuBaseUrl != null) {
        this.zhipuBaseUrl = zhipuBaseUrl.trim().isEmpty
            ? LlmProviderDefaults.zhipuBase
            : zhipuBaseUrl.trim();
      }
      if (zhipuChatModel != null) {
        this.zhipuChatModel = zhipuChatModel.trim().isEmpty
            ? LlmProviderDefaults.zhipuModel
            : zhipuChatModel.trim();
      }
      if (oneApiBaseUrl != null) this.oneApiBaseUrl = oneApiBaseUrl.trim();
      if (oneApiKey != null) this.oneApiKey = oneApiKey.trim();
      if (oneApiModel != null) this.oneApiModel = oneApiModel.trim();
      if (geminiApiKey != null) this.geminiApiKey = geminiApiKey.trim();
      if (geminiVisionModel != null) {
        this.geminiVisionModel = geminiVisionModel.trim().isEmpty
            ? 'gemini-2.5-flash'
            : geminiVisionModel.trim();
      }
      if (visionBaseUrl != null) this.visionBaseUrl = visionBaseUrl.trim();
      if (visionApiKey != null) this.visionApiKey = visionApiKey.trim();
      if (visionModels != null && visionModels.trim().isNotEmpty) {
        this.visionModels = visionModels.trim();
      }
    }

    this.useLlm = useLlm;
    if (useCloudAsr != null) this.useCloudAsr = useCloudAsr;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProvider, this.llmProvider);
    if (!BakedEnv.hasBundle) {
      await prefs.setString(_kBaseUrl, this.baseUrl);
      await prefs.setString(_kApiKey, this.apiKey);
      await prefs.setString(_kModel, this.model);
      await prefs.setString(_kAsrModel, this.asrModel);
      await prefs.setString(_kAsrBaseUrl, this.asrBaseUrl);
      await prefs.setString(_kAsrApiKey, this.asrApiKey);
      await prefs.setString(_kSiliconChatModel, this.siliconChatModel);
      await prefs.setString(_kGroqApiKey, this.groqApiKey);
      await prefs.setString(_kGroqBaseUrl, this.groqBaseUrl);
      await prefs.setString(_kGroqAsrModel, this.groqAsrModel);
      await prefs.setString(_kBaiduAsrApiKey, this.baiduAsrApiKey);
      await prefs.setString(_kBaiduAsrSecretKey, this.baiduAsrSecretKey);
      await prefs.setString(_kBaiduLlmApiKey, this.baiduLlmApiKey);
      await prefs.setString(_kBaiduLlmBaseUrl, this.baiduLlmBaseUrl);
      await prefs.setString(_kBaiduLlmModel, this.baiduLlmModel);
      await prefs.setString(_kZhipuApiKey, this.zhipuApiKey);
      await prefs.setString(_kZhipuBaseUrl, this.zhipuBaseUrl);
      await prefs.setString(_kZhipuChatModel, this.zhipuChatModel);
      await prefs.setString(_kOneApiBaseUrl, this.oneApiBaseUrl);
      await prefs.setString(_kOneApiKey, this.oneApiKey);
      await prefs.setString(_kOneApiModel, this.oneApiModel);
      await prefs.setString(_kGeminiApiKey, this.geminiApiKey);
      await prefs.setString(_kGeminiVisionModel, this.geminiVisionModel);
      await prefs.setString(_kVisionBaseUrl, this.visionBaseUrl);
      await prefs.setString(_kVisionApiKey, this.visionApiKey);
      await prefs.setString(_kVisionModels, this.visionModels);
    }
    await prefs.setBool(_kUseLlm, this.useLlm);
    await prefs.setBool(_kUseCloudAsr, this.useCloudAsr);
  }
}
