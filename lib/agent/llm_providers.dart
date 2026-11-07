/// 对话大模型厂商选择与默认端点。

/// 设置页 / prefs 存的厂商 id。
class LlmProviderId {
  static const auto = 'auto';
  static const zhipu = 'zhipu';
  static const baidu = 'baidu';
  static const silicon = 'silicon';
  static const oneapi = 'oneapi';
  static const deepseek = 'deepseek';

  /// 主界面可选（不含付费 DeepSeek）。
  static const visibleChoices = <String>[
    auto,
    zhipu,
    baidu,
    silicon,
    oneapi,
  ];

  static String label(String id) {
    switch (id) {
      case auto:
        return '自动（推荐）';
      case zhipu:
        return '智谱 GLM';
      case baidu:
        return '百度千帆';
      case silicon:
        return '硅基流动';
      case oneapi:
        return 'One API 网关';
      case deepseek:
        return 'DeepSeek（付费）';
      default:
        return id;
    }
  }
}

/// 一次可调用的 OpenAI 兼容端点。
class LlmEndpoint {
  const LlmEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get usable =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;
}

/// 默认 Base / 模型（Key 由 bake 或设置注入）。
class LlmProviderDefaults {
  static const zhipuBase = 'https://open.bigmodel.cn/api/paas/v4';
  static const zhipuModel = 'glm-4-flash';

  static const baiduBase = 'https://qianfan.baidubce.com/v2';
  static const baiduModel = 'ernie-speed-8k';

  static const siliconBase = 'https://api.siliconflow.cn/v1';
  static const siliconModel = 'Qwen/Qwen2.5-7B-Instruct';

  static const deepseekBase = 'https://api.deepseek.com/v1';
  static const deepseekModel = 'deepseek-chat';
}
