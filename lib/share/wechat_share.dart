import 'dart:typed_data';

import 'package:fluwx/fluwx.dart';
import 'package:http/http.dart' as http;

import '../config/baked_env.dart';
import '../media/qiniu_uploader.dart';

/// 微信开放平台：分享网页到好友/朋友圈（标题 + 描述 + 缩略图）。
class WeChatShare {
  WeChatShare._();
  static final WeChatShare instance = WeChatShare._();

  final Fluwx _api = Fluwx();
  bool _ready = false;

  bool get configured => BakedEnv.hasWechat;

  Future<void> init() async {
    final appId = BakedEnv.wechatAppId.trim();
    if (appId.isEmpty) return;
    final link = BakedEnv.wechatUniversalLink.trim();
    await _api.registerApi(
      appId: appId,
      universalLink: link.isEmpty ? null : link,
    );
    _ready = true;
  }

  Future<bool> get isInstalled async {
    if (!_ready && configured) await init();
    if (!_ready) return false;
    return _api.isWeChatInstalled;
  }

  /// [scene]：会话 / 朋友圈。
  Future<void> shareWebPage({
    required String url,
    required String title,
    required String description,
    String? thumbUrl,
    WeChatScene scene = WeChatScene.session,
  }) async {
    if (!configured) {
      throw StateError('未配置 WECHAT_APP_ID，无法调用微信分享');
    }
    if (!_ready) await init();
    if (!await _api.isWeChatInstalled) {
      throw StateError('未安装微信');
    }

    final thumb = await _loadThumb(thumbUrl);
    await _api.share(
      WeChatShareWebPageModel(
        url,
        title: title.isEmpty ? '房间视频' : title,
        description:
            description.isEmpty ? '点击查看房间实拍视频' : description,
        thumbData: thumb,
        scene: scene,
      ),
    );
  }

  /// 微信要求缩略图约 ≤32KB；过大则不传（仍可分享链接）。
  Future<Uint8List?> _loadThumb(String? url) async {
    final raw = (url ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final playable = QiniuUploader.playableUrl(raw);
      final res = await http
          .get(Uri.parse(playable))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > 32 * 1024) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
