import 'dart:io';

import 'package:flutter/material.dart';

import '../agent/voice_capture.dart';
import '../agent/voice_dictation.dart';

/// 找 AI / 笔记 AI 共用的底部输入：按住说话 · 附图 · 键盘切换。
class VoiceInputBar extends StatelessWidget {
  const VoiceInputBar({
    super.key,
    required this.voice,
    required this.voiceMode,
    required this.onToggleVoiceMode,
    required this.input,
    required this.onSend,
    required this.onAttachImage,
    this.busy = false,
    this.pendingImage,
    this.onClearImage,
    this.hintText = '随便说…',
    this.darkChrome = true,
  });

  final VoiceCapture voice;
  final bool voiceMode;
  final VoidCallback onToggleVoiceMode;
  final TextEditingController input;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;
  final bool busy;
  final File? pendingImage;
  final VoidCallback? onClearImage;
  final String hintText;
  final bool darkChrome;

  @override
  Widget build(BuildContext context) {
    final bg = darkChrome ? const Color(0xFF111111) : const Color(0xFFE8E8E8);
    final fg = darkChrome ? Colors.white : const Color(0xFF111111);
    final muted = darkChrome ? Colors.white70 : const Color(0xFF666666);

    return Material(
      color: bg,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (voice.listening || voice.transcribing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      voice.statusLine,
                      style: TextStyle(color: muted, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: List.generate(12, (i) {
                        final threshold = (i + 1) / 12;
                        final active = voice.soundLevel >= threshold * 0.85;
                        final h =
                            6.0 + (active ? voice.soundLevel * 18 : voice.soundLevel * 4);
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1.5),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 60),
                              height: h.clamp(4, 24),
                              decoration: BoxDecoration(
                                color: active ? fg : muted.withOpacity(0.35),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            if (pendingImage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        pendingImage!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        voiceMode ? '已附图 · 按住说话说明后松开' : '已附图 · 写上要求后发送',
                        style: TextStyle(color: muted, fontSize: 13),
                      ),
                    ),
                    IconButton(
                      onPressed: busy ? null : onClearImage,
                      icon: Icon(Icons.close, color: muted),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
              child: Row(
                children: [
                  Expanded(
                    child: voiceMode
                        ? Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (_) => voice.onHoldStart(),
                            onPointerUp: (_) =>
                                voice.onHoldEnd(send: true),
                            onPointerCancel: (_) =>
                                voice.onHoldEnd(send: false),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              height: 48,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: voice.listening
                                    ? const Color(0xFF333333)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Text(
                                voice.listening ? '松开发送…' : '按住说话',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: voice.listening
                                      ? Colors.white
                                      : const Color(0xFF111111),
                                ),
                              ),
                            ),
                          )
                        : TextField(
                            controller: input,
                            minLines: 1,
                            maxLines: 4,
                            style: TextStyle(color: fg, fontSize: 15),
                            cursorColor: fg,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => onSend(),
                            decoration: InputDecoration(
                              hintText: hintText,
                              hintStyle: TextStyle(color: muted),
                              filled: true,
                              fillColor: darkChrome
                                  ? const Color(0xFF2A2A2A)
                                  : Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                            ),
                          ),
                  ),
                  IconButton(
                    tooltip: '附图',
                    onPressed:
                        busy || voice.transcribing ? null : onAttachImage,
                    icon: Icon(
                      pendingImage == null
                          ? Icons.image_outlined
                          : Icons.image,
                      color: muted,
                    ),
                  ),
                  IconButton(
                    tooltip: voiceMode ? '切换键盘' : '切换语音',
                    onPressed: busy || voice.transcribing
                        ? null
                        : onToggleVoiceMode,
                    icon: Icon(
                      voiceMode
                          ? Icons.keyboard_alt_outlined
                          : Icons.mic_none,
                      color: muted,
                    ),
                  ),
                  if (!voiceMode)
                    TextButton(
                      onPressed: busy ? null : onSend,
                      child: Text(
                        '发送',
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 笔记正文旁麦克风：点按切换听写（开麦高亮，说完停顿自动出字，再点关闭）。
class NoteMicButton extends StatefulWidget {
  const NoteMicButton({
    super.key,
    required this.onText,
  });

  final void Function(String text) onText;

  @override
  State<NoteMicButton> createState() => _NoteMicButtonState();
}

class _NoteMicButtonState extends State<NoteMicButton> {
  late final VoiceDictation _dictation;

  @override
  void initState() {
    super.initState();
    _dictation = VoiceDictation(
      onTranscript: widget.onText,
      onStatus: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
        );
      },
    );
    _dictation.addListener(_onTick);
    _dictation.init();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dictation.removeListener(_onTick);
    _dictation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = _dictation.active;
    final busy = _dictation.transcribing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (on && _dictation.hint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4, right: 2),
            child: Text(
              busy ? _dictation.hint : '听写中 · 再点结束',
              style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
            ),
          ),
        Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _dictation.toggle(),
            child: Ink(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? const Color(0xFF111111) : const Color(0xFFF0F0F0),
                border: Border.all(
                  color: on ? const Color(0xFF111111) : const Color(0xFFCCCCCC),
                ),
              ),
              child: Icon(
                on ? Icons.mic : Icons.mic_none,
                size: 22,
                color: on ? Colors.white : const Color(0xFF666666),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
