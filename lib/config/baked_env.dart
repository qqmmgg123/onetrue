/// 编译期注入的配置（来自 `supabase/env.local` → `dart_defines.json`）。
/// 打包：`.\build_apk.ps1` 或
/// `flutter build apk --dart-define-from-file=supabase/dart_defines.json`
class BakedEnv {
  BakedEnv._();

  // —— 大模型对话 ——
  /// auto | zhipu | baidu | silicon | oneapi | deepseek
  static const String llmProvider = String.fromEnvironment(
    'LLM_PROVIDER',
    defaultValue: 'auto',
  );
  static const String llmBaseUrl = String.fromEnvironment(
    'LLM_BASE_URL',
    defaultValue: 'https://api.deepseek.com/v1',
  );
  static const String llmApiKey = String.fromEnvironment('LLM_API_KEY');
  static const String llmModel = String.fromEnvironment(
    'LLM_MODEL',
    defaultValue: 'deepseek-chat',
  );
  static const bool useLlm = bool.fromEnvironment('USE_LLM', defaultValue: false);

  /// 智谱对话（默认 glm-4-flash；识图仍用 ZHIPU_VISION_MODEL）
  static const String zhipuChatModel = String.fromEnvironment(
    'ZHIPU_CHAT_MODEL',
    defaultValue: 'glm-4-flash',
  );

  /// 百度千帆对话（OpenAI 兼容 v2，与 ASR 的 AK/SK 分开）
  static const String baiduLlmApiKey =
      String.fromEnvironment('BAIDU_LLM_API_KEY');
  static const String baiduLlmBaseUrl = String.fromEnvironment(
    'BAIDU_LLM_BASE_URL',
    defaultValue: 'https://qianfan.baidubce.com/v2',
  );
  static const String baiduLlmModel = String.fromEnvironment(
    'BAIDU_LLM_MODEL',
    defaultValue: 'ernie-speed-8k',
  );

  /// 硅基对话（空则复用 ASR_*）
  static const String siliconChatModel = String.fromEnvironment(
    'SILICON_CHAT_MODEL',
    defaultValue: 'Qwen/Qwen2.5-7B-Instruct',
  );

  /// One API / New API 聚合网关（配好后 auto 优先走这里）
  static const String oneApiBaseUrl =
      String.fromEnvironment('ONE_API_BASE_URL');
  static const String oneApiKey = String.fromEnvironment('ONE_API_KEY');
  static const String oneApiModel = String.fromEnvironment('ONE_API_MODEL');

  // —— 百度智能云短语音（ASR 第一优先）——
  static const String baiduAsrApiKey =
      String.fromEnvironment('BAIDU_ASR_API_KEY');
  static const String baiduAsrSecretKey =
      String.fromEnvironment('BAIDU_ASR_SECRET_KEY');

  // —— Groq Whisper（ASR 第二优先）——
  static const String groqApiKey = String.fromEnvironment('GROQ_API_KEY');
  static const String groqBaseUrl = String.fromEnvironment(
    'GROQ_BASE_URL',
    defaultValue: 'https://api.groq.com/openai/v1',
  );
  static const String groqAsrModel = String.fromEnvironment(
    'GROQ_ASR_MODEL',
    defaultValue: 'whisper-large-v3-turbo',
  );

  // —— 硅基 SenseVoice（ASR 第三优先）——
  static const String asrBaseUrl = String.fromEnvironment(
    'ASR_BASE_URL',
    defaultValue: 'https://api.siliconflow.cn/v1',
  );
  static const String asrApiKey = String.fromEnvironment('ASR_API_KEY');
  static const String asrModel = String.fromEnvironment(
    'ASR_MODEL',
    defaultValue: 'FunAudioLLM/SenseVoiceSmall',
  );
  static const bool useCloudAsr =
      bool.fromEnvironment('USE_CLOUD_ASR', defaultValue: true);

  // —— 附图理解（对话里「看图做事」）——
  /// 智谱免费真识图：https://open.bigmodel.cn 申请 API Key，模型 glm-4v-flash
  static const String zhipuApiKey = String.fromEnvironment('ZHIPU_API_KEY');
  static const String zhipuBaseUrl = String.fromEnvironment(
    'ZHIPU_BASE_URL',
    defaultValue: 'https://open.bigmodel.cn/api/paas/v4',
  );
  static const String zhipuVisionModel = String.fromEnvironment(
    'ZHIPU_VISION_MODEL',
    defaultValue: 'glm-4v-flash',
  );
  /// DeepSeek 官方真识图模型名（复用 LLM_API_KEY）
  static const String deepseekVisionModel = String.fromEnvironment(
    'DEEPSEEK_VISION_MODEL',
    defaultValue: 'deepseek-flash',
  );
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String geminiVisionModel = String.fromEnvironment(
    'GEMINI_VISION_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );
  /// 硅基 OCR 兜底；空则复用 ASR_*
  static const String visionBaseUrl = String.fromEnvironment('VISION_BASE_URL');
  static const String visionApiKey = String.fromEnvironment('VISION_API_KEY');
  static const String visionModels = String.fromEnvironment(
    'VISION_MODELS',
    defaultValue:
        'deepseek-ai/DeepSeek-OCR,PaddlePaddle/PaddleOCR-VL-1.5',
  );

  // —— Neon / Postgres 同步（直连连接串，适合自用打包）——
  static const String databaseUrl = String.fromEnvironment('DATABASE_URL');
  static const String syncOwnerId = String.fromEnvironment('SYNC_OWNER_ID');
  static const bool syncEnabled =
      bool.fromEnvironment('SYNC_ENABLED', defaultValue: false);

  // —— 七牛云房间视频（优先，国内更快）——
  static const String qiniuAccessKey =
      String.fromEnvironment('QINIU_ACCESS_KEY');
  static const String qiniuSecretKey =
      String.fromEnvironment('QINIU_SECRET_KEY');
  static const String qiniuBucket = String.fromEnvironment('QINIU_BUCKET');
  static const String qiniuPublicBase =
      String.fromEnvironment('QINIU_PUBLIC_BASE');
  static const String qiniuUploadHost = String.fromEnvironment(
    'QINIU_UPLOAD_HOST',
    defaultValue: 'https://upload.qiniup.com',
  );
  /// 多媒体处理队列名（控制台创建）；空=默认公有队列，可能排队更久
  static const String qiniuPipeline = String.fromEnvironment('QINIU_PIPELINE');

  // —— Cloudflare R2 房间视频（七牛失败时备用）——
  static const String r2AccountId = String.fromEnvironment('R2_ACCOUNT_ID');
  static const String r2AccessKeyId =
      String.fromEnvironment('R2_ACCESS_KEY_ID');
  static const String r2SecretAccessKey =
      String.fromEnvironment('R2_SECRET_ACCESS_KEY');
  static const String r2Bucket = String.fromEnvironment('R2_BUCKET');
  static const String r2PublicBase = String.fromEnvironment('R2_PUBLIC_BASE');

  /// 分享站根地址（EdgeOne / 国内域名），如 https://xxx.edgeone.app
  static const String shareWebBase = String.fromEnvironment('SHARE_WEB_BASE');
  static const String appDownloadUrl =
      String.fromEnvironment('APP_DOWNLOAD_URL');
  static const String appDownloadHint = String.fromEnvironment(
    'APP_DOWNLOAD_HINT',
    defaultValue: 'App 下载方式稍后公布',
  );
  /// 更新清单 JSON；空则默认用 `{QINIU|R2}_PUBLIC_BASE/app/version.json`
  static const String appUpdateManifestUrl =
      String.fromEnvironment('APP_UPDATE_MANIFEST_URL');

  /// 微信开放平台移动应用 AppID（分享网页卡片）
  static const String wechatAppId = String.fromEnvironment('WECHAT_APP_ID');
  static const String wechatUniversalLink =
      String.fromEnvironment('WECHAT_UNIVERSAL_LINK');

  static bool get hasWechat => wechatAppId.trim().isNotEmpty;

  static bool get hasLlmKey => llmApiKey.trim().isNotEmpty;
  static bool get hasBaiduLlmKey => baiduLlmApiKey.trim().isNotEmpty;
  static bool get hasOneApi =>
      oneApiBaseUrl.trim().isNotEmpty && oneApiKey.trim().isNotEmpty;
  static bool get hasBaiduAsrKey =>
      baiduAsrApiKey.trim().isNotEmpty && baiduAsrSecretKey.trim().isNotEmpty;
  static bool get hasGroqKey => groqApiKey.trim().isNotEmpty;
  static bool get hasAsrKey => asrApiKey.trim().isNotEmpty;
  static bool get hasGeminiKey => geminiApiKey.trim().isNotEmpty;
  static bool get hasZhipuKey => zhipuApiKey.trim().isNotEmpty;
  /// 是否已内置任一对话可用 Key（免费级联或 DeepSeek / One API）。
  static bool get hasAnyChatLlmKey =>
      hasZhipuKey || hasBaiduLlmKey || hasAsrKey || hasOneApi || hasLlmKey;
  static bool get hasVisionKey =>
      hasZhipuKey ||
      hasGeminiKey ||
      visionApiKey.trim().isNotEmpty ||
      hasAsrKey ||
      hasLlmKey;
  static bool get hasSyncDb => databaseUrl.trim().isNotEmpty;
  static bool get hasQiniu =>
      qiniuAccessKey.trim().isNotEmpty &&
      qiniuSecretKey.trim().isNotEmpty &&
      qiniuBucket.trim().isNotEmpty &&
      qiniuPublicBase.trim().isNotEmpty;
  static bool get hasR2 =>
      r2AccountId.trim().isNotEmpty &&
      r2AccessKeyId.trim().isNotEmpty &&
      r2SecretAccessKey.trim().isNotEmpty &&
      r2Bucket.trim().isNotEmpty &&
      r2PublicBase.trim().isNotEmpty;

  /// 是否已把服务商配置打进安装包（手机上不必再填 Key）。
  static bool get hasBundle =>
      hasLlmKey ||
      hasBaiduLlmKey ||
      hasOneApi ||
      hasBaiduAsrKey ||
      hasGroqKey ||
      hasAsrKey ||
      hasGeminiKey ||
      hasZhipuKey ||
      hasSyncDb ||
      hasQiniu ||
      hasR2;
}
