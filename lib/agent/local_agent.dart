import 'package:uuid/uuid.dart';

import '../billing/bill_models.dart';
import 'agent_models.dart';
import 'agent_tools.dart';
import 'chat_memory.dart';

/// 不配大模型也能用的本地意图解析（中文常用说法 + 会话便签多轮补全）。
class LocalAgent {
  LocalAgent(this.runner);

  final AgentToolRunner runner;
  final _uuid = const Uuid();

  Future<AgentReply> handle(String raw, {SessionSticky? sticky}) async {
    final text = raw.trim();
    final note = sticky ?? SessionSticky();
    if (text.isEmpty) {
      return AgentReply(
        text: '想到啥说啥就行，比如先说「有个 302 要租出去」，再说租户和房租。',
      );
    }

    if (_isHelp(text)) {
      return AgentReply(
        text: '可以这样说（想到哪句说哪句就行）：\n'
            '· 加个小区叫阳光花园 / 阳光花园加房间 302\n'
            '· 给 302 登记租约，租户王芳，每月 10 号，房租 2800\n'
            '· 302 加物业费 150，再加网费 50\n'
            '· 302 电价 1.2，水价 5\n'
            '· 302 电表 1180 到 1234 / 算房租 / 少收 200 / 出单 / 记已收\n'
            '· 302 退租 / 删掉 302 / 删除小区阳光花园\n'
            '· 有哪些房 / 下个月收哪些租\n'
            '写操作会先确认。',
      );
    }

    if (_matchAny(text, ['有哪些房', '房源', '看看房', '列出', '有什么房'])) {
      return AgentReply(text: await runner.runRead('list_inventory', {}));
    }

    if (_matchAny(text, ['收哪些租', '哪些要收', '应收', '到期']) &&
        !_matchAny(text, ['改到', '改成', '电表', '水表'])) {
      return AgentReply(
        text: await runner.runRead('list_upcoming_dues', {'days': 40}),
      );
    }

    // 试算
    if (_matchAny(text, ['算', '试算', '清单', '多少钱', '房租怎么算'])) {
      final room = _roomOf(text, sticky: note);
      if (room != null) {
        return AgentReply(
          text: await runner.runRead('preview_rent_bill', {'room_label': room}),
        );
      }
    }

    // 抄表：可一次多种「302 电表 1180 到 1234，水表 80 到 95」
    final meterRe = RegExp(
      r'(?:([A-Za-z0-9\-]+).{0,8}?)?(电|水|燃|煤气)表\s*(\d+(?:\.\d+)?)\s*(?:到|至|->|→)\s*(\d+(?:\.\d+)?)',
    );
    final meterMatches = meterRe.allMatches(text).toList();
    if (meterMatches.isNotEmpty &&
        _matchAny(text, ['表', '电', '水', '燃', '抄'])) {
      String? room = _roomOf(text, sticky: note);
      if (room == null) {
        for (final m in meterMatches) {
          final r = m.group(1);
          if (r != null && r.isNotEmpty) {
            room = r;
            break;
          }
        }
      }
      if (room == null) {
        return AgentReply(text: '抄表要说清房号，比如「302 电表 1180 到 1234」。');
      }
      final readings = <Map<String, dynamic>>[];
      for (final m in meterMatches) {
        final kind = parseMeterKind(m.group(2)!) ?? 'electric';
        readings.add({
          'kind': kind,
          'previous_reading': double.parse(m.group(3)!),
          'current_reading': double.parse(m.group(4)!),
        });
      }
      if (readings.length == 1) {
        return _pending('record_meter_reading', {
          'room_label': room,
          ...readings.first,
        });
      }
      return _pending('record_meter_readings', {
        'room_label': room,
        'readings': readings,
      });
    }

    // 附加费：302 加物业费 150 / 302 附加费网费 50
    final extraAdd = RegExp(
      r'([A-Za-z0-9\-]+).{0,12}?(?:加|增加|设置)?(?:附加费)?\s*([\u4e00-\u9fa5A-Za-z]{2,12})\s*(\d+(?:\.\d+)?)',
    ).firstMatch(text);
    if (extraAdd != null &&
        _matchAny(text, ['附加费', '物业费', '网费', '卫生费', '管理费']) &&
        !_matchAny(text, ['电价', '水价', '单价'])) {
      return _pending('add_lease_extra', {
        'room_label': extraAdd.group(1),
        'name': extraAdd.group(2),
        'amount': double.parse(extraAdd.group(3)!),
      });
    }
    if (_matchAny(text, ['去掉', '删掉', '取消']) &&
        _matchAny(text, ['附加费', '物业费', '网费']) &&
        _roomOf(text, sticky: note) != null) {
      final name = RegExp(r'(物业费|网费|卫生费|管理费|[\u4e00-\u9fa5]{2,12}费)')
              .firstMatch(text)
              ?.group(1) ??
          '附加费';
      return _pending('remove_lease_extra', {
        'room_label': _roomOf(text, sticky: note),
        'name': name,
      });
    }

    // 单价（水电燃，不含附加费）
    if (_matchAny(text, ['电价', '水价', '单价']) &&
        _roomOf(text, sticky: note) != null) {
      final room = _roomOf(text, sticky: note)!;
      final electric = RegExp(r'电(?:价|费单价)?\s*(\d+(?:\.\d+)?)')
          .firstMatch(text)
          ?.group(1);
      final water =
          RegExp(r'水(?:价|费单价)?\s*(\d+(?:\.\d+)?)').firstMatch(text)?.group(1);
      final gas = RegExp(r'(?:燃|煤气)(?:价|费单价)?\s*(\d+(?:\.\d+)?)')
          .firstMatch(text)
          ?.group(1);
      return _pending('set_meter_rates', {
        'room_label': room,
        if (electric != null) 'electric_price': double.parse(electric),
        if (water != null) 'water_price': double.parse(water),
        if (gas != null) 'gas_price': double.parse(gas),
      });
    }

    // 退租
    if (_matchAny(text, ['退租', '退掉', '租约结束', '结束租约']) &&
        _roomOf(text, sticky: note) != null) {
      return _pending('end_lease', {
        'room_label': _roomOf(text, sticky: note),
      });
    }

    // 删房间 / 删小区
    if (_matchAny(text, ['删除房间', '删掉房间', '删房']) &&
        _roomOf(text, sticky: note) != null) {
      return _pending('delete_room', {
        'room_label': _roomOf(text, sticky: note),
      });
    }
    final delRoom = RegExp(r'(?:删除|删掉)\s*([A-Za-z0-9\-]+)').firstMatch(text);
    if (delRoom != null &&
        _matchAny(text, ['删除', '删掉']) &&
        !_matchAny(text, ['小区', '房产'])) {
      return _pending('delete_room', {'room_label': delRoom.group(1)});
    }
    final delProp = RegExp(
      r'(?:删除|删掉)(?:小区|房产)\s*([^\s，。]+)',
    ).firstMatch(text);
    if (delProp != null) {
      return _pending('delete_property', {
        'property_name': delProp.group(1)!.trim(),
      });
    }

    // 优惠：302 少收 200 / 本月优惠 200（房号可来自便签）
    if (_matchAny(text, ['少收', '优惠', '减免', '心情好'])) {
      final withRoom = RegExp(
        r'([A-Za-z0-9\-]+).{0,16}?(?:少收|优惠|减免|减)\s*(\d+(?:\.\d+)?)',
      ).firstMatch(text);
      final amountOnly = RegExp(
        r'(?:本月)?(?:少收|优惠|减免|减(?:免|掉)?)\s*(\d+(?:\.\d+)?)',
      ).firstMatch(text);
      final room = withRoom != null
          ? withRoom.group(1)
          : _roomOf(text, sticky: note);
      final amountStr = withRoom?.group(2) ?? amountOnly?.group(1);
      if (room != null &&
          amountStr != null &&
          !_looksLikeReadingOrMoney(text, room)) {
        return _pending('apply_period_discount', {
          'room_label': room,
          'amount': double.parse(amountStr),
          'note': text.contains('心情') ? '心情减免' : '本月优惠',
        });
      }
    }
    if (_matchAny(text, ['取消优惠', '清掉优惠', '不要优惠', '优惠清零'])) {
      final room = _roomOf(text, sticky: note);
      if (room != null) {
        return _pending('apply_period_discount', {
          'room_label': room,
          'amount': 0,
          'note': '',
        });
      }
    }

    // 解除冻结
    if (_matchAny(text, ['解除冻结', '取消冻结', '取消出单', '作废清单', '解冻']) &&
        _roomOf(text, sticky: note) != null) {
      return _pending(
        'unfreeze_invoice',
        {'room_label': _roomOf(text, sticky: note)},
      );
    }

    // 出单
    if (_matchAny(text, ['出单', '冻结清单', '生成清单']) &&
        _roomOf(text, sticky: note) != null) {
      return _pending(
        'issue_invoice',
        {'room_label': _roomOf(text, sticky: note)},
      );
    }

    final addProp = RegExp(
      r'(?:加|新增|创建)(?:个|一处|一个)?(?:小区|房产|楼盘)?[叫为是]?[:：]?\s*(.+)',
    ).firstMatch(text);
    if (addProp != null && _matchAny(text, ['小区', '房产', '楼盘'])) {
      final name =
          addProp.group(1)!.trim().replaceAll(RegExp(r'[。.!！]+$'), '');
      return _pending('add_property', {'name': name, 'address': ''});
    }

    final addRoom = RegExp(
      r'(.+?)(?:小区)?(?:里|下)?(?:加|新增|添加)(?:个|一间)?(?:房间|房)?\s*([A-Za-z0-9\-]+)',
    ).firstMatch(text);
    if (addRoom != null &&
        _matchAny(text, ['加', '新增', '添加']) &&
        !_matchAny(text, ['租约', '登记'])) {
      return _pending('add_room', {
        'property_name': addRoom.group(1)!.trim(),
        'room_label': addRoom.group(2)!.trim(),
        'create_property_if_missing': true,
      });
    }

    if (_matchAny(text, ['登记租约', '签租约', '新租约', '租给', '入住']) ||
        note.intent == 'create_lease' ||
        (note.roomLabel != null &&
            _matchAny(text, ['房租', '租金', '月租', '租户', '租客', '押金']) &&
            !_matchAny(text, ['少收', '优惠', '抄表', '出单']))) {
      return _parseCreateLease(text, note);
    }

    final dueDay = RegExp(
              r'([A-Za-z0-9\-]+).{0,12}?(?:收租|收款)?日?(?:改到|改成|改为|调到)\s*每月?\s*(\d{1,2})\s*号?',
            ).firstMatch(text) ??
        RegExp(r'把\s*([A-Za-z0-9\-]+)\s*.{0,8}?改到\s*每月?\s*(\d{1,2})\s*号?')
            .firstMatch(text);
    if (dueDay != null) {
      return _pending('update_rent_due_day', {
        'room_label': dueDay.group(1),
        'rent_due_day': int.parse(dueDay.group(2)!),
      });
    }

    final changeTenant = RegExp(
      r'([A-Za-z0-9\-]+).{0,8}?(?:换成|改成|改为)\s*([\u4e00-\u9fa5A-Za-z]{1,20})',
    ).firstMatch(text);
    if (changeTenant != null &&
        _matchAny(text, ['换', '改成', '改为', '租户']) &&
        !_matchAny(text, ['收租日', '每月'])) {
      final phone = RegExp(r'1\d{10}').firstMatch(text)?.group(0) ?? '';
      return _pending('update_lease_tenant', {
        'room_label': changeTenant.group(1),
        'tenant_name': changeTenant.group(2),
        'tenant_phone': phone,
      });
    }

    final paid =
        RegExp(r'([A-Za-z0-9\-]+).{0,12}?(?:收了|已收|交了|付了)').firstMatch(text);
    if (paid != null) {
      return _pending('mark_period_paid', {'room_label': paid.group(1)});
    }

    return AgentReply(
      text: '我还没听懂。发「帮助」看示例；'
          '或配置大模型 Key 理解更随意的说法。',
    );
  }

  Future<AgentReply> _parseCreateLease(String text, SessionSticky sticky) async {
    final merged = mergeStickyFromUtterance(sticky, text)..intent = 'create_lease';
    final room = merged.roomLabel;
    if (room == null || room.isEmpty) {
      return AgentReply(text: '这间房号是多少？你直接说「302」也行。');
    }

    final missing = missingLeaseSlots(merged);
    if (missing.isNotEmpty) {
      final known = <String>[
        '房号 $room',
        if (merged.tenantName != null) '租户 ${merged.tenantName}',
        if (merged.rentDueDay != null) '每月 ${merged.rentDueDay} 号',
        if (merged.baseRent != null) '房租 ${merged.baseRent}',
      ];
      return AgentReply(
        text: '先记下了：${known.join('，')}。\n'
            '还差：${missing.join('、')}？想到哪句回哪句就行。',
      );
    }

    final day = merged.rentDueDay!;
    final rent = merged.baseRent!;
    return _pending('create_lease', {
      'room_label': room,
      if (merged.propertyName != null) 'property_name': merged.propertyName,
      'tenant_name': merged.tenantName,
      'tenant_phone': merged.tenantPhone ?? '',
      'rent_due_day': day,
      'base_rent': rent,
      'deposit': merged.deposit ?? rent,
      'auto_create_room': true,
    });
  }

  String? _roomOf(String text, {SessionSticky? sticky}) {
    final explicit =
        RegExp(r'(?:给|为)\s*([A-Za-z0-9\-]+)').firstMatch(text)?.group(1) ??
            RegExp(r'([A-Za-z0-9\-]+)\s*(?:室|房)').firstMatch(text)?.group(1) ??
            RegExp(r'房号\s*[:：]?\s*([A-Za-z0-9\-]+)')
                .firstMatch(text)
                ?.group(1);
    if (explicit != null && !_looksLikeReadingOrMoney(text, explicit)) {
      return explicit;
    }

    // 「2702-1 电表…」「302 少收…」：取读数/优惠前的房号，不要把 1180/200 当成房号
    final beforeMeter = RegExp(
      r'([A-Za-z0-9\-]+)\s*(?:的)?\s*(?:电|水|燃|煤气)?表',
    ).firstMatch(text)?.group(1);
    if (beforeMeter != null && !_looksLikeReadingOrMoney(text, beforeMeter)) {
      return beforeMeter;
    }
    final beforeDiscount = RegExp(
      r'([A-Za-z0-9\-]+)\s*(?:本月)?(?:少收|优惠|减免|减)',
    ).firstMatch(text)?.group(1);
    if (beforeDiscount != null &&
        !_looksLikeReadingOrMoney(text, beforeDiscount)) {
      return beforeDiscount;
    }

    // 行首房号（含 2702-1），排除「少收200」这种以金额开头的
    final leading = RegExp(
      r'^([A-Za-z0-9]+(?:-[A-Za-z0-9]+)?)',
    ).firstMatch(text.trim())?.group(1);
    if (leading != null &&
        RegExp(
          r'^(?:[A-Za-z0-9]+-[A-Za-z0-9]+|\d{2,5}[A-Za-z]?|[A-Za-z]\d{2,4})$',
        ).hasMatch(leading) &&
        !_looksLikeReadingOrMoney(text, leading)) {
      return leading;
    }

    return sticky?.roomLabel;
  }

  /// 抄表/优惠等高置信说法：开了大模型时也优先走本地，避免模型空口答应却不提议确认。
  Future<AgentReply?> tryDirectWrite(String raw, {SessionSticky? sticky}) async {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final note = sticky ?? SessionSticky();

    final looksMeter = RegExp(
      r'(电|水|燃|煤气)表\s*\d+(?:\.\d+)?\s*(?:到|至|->|→)\s*\d+',
    ).hasMatch(text);
    final looksDiscount = RegExp(
      r'(?:少收|优惠|减免|减)\s*\d+|(?:取消优惠|清掉优惠|不要优惠|优惠清零)',
    ).hasMatch(text);
    final looksFreeze = _matchAny(text, ['解除冻结', '取消冻结', '解冻']) ||
        (_matchAny(text, ['出单', '冻结清单']) &&
            _roomOf(text, sticky: note) != null);
    if (!looksMeter && !looksDiscount && !looksFreeze) return null;

    final reply = await handle(text, sticky: note);
    final tool = reply.pending?.tool;
    if (tool == null) return null;
    const ok = {
      'record_meter_reading',
      'record_meter_readings',
      'apply_period_discount',
      'unfreeze_invoice',
      'issue_invoice',
    };
    return ok.contains(tool) ? reply : null;
  }

  /// 读数、优惠金额、房租数字不能当房号。
  bool _looksLikeReadingOrMoney(String text, String token) {
    if (RegExp(RegExp.escape(token) + r'\s*(?:到|至|->|→)').hasMatch(text)) {
      return true;
    }
    if (RegExp(r'(?:到|至|->|→)\s*' + RegExp.escape(token)).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'(?:少收|优惠|减免|减)\s*' + RegExp.escape(token))
        .hasMatch(text)) {
      return true;
    }
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(token) &&
        _matchAny(text, ['房租', '租金', '月租', '押金', '元', '块'])) {
      return true;
    }
    return false;
  }

  AgentReply _pending(String tool, Map<String, dynamic> args) {
    final action = PendingAction(
      id: _uuid.v4(),
      tool: tool,
      args: args,
      summary: runner.summarize(tool, args),
    );
    return AgentReply(
      text: '确认要执行吗？\n${action.summary}',
      pending: action,
    );
  }

  bool _isHelp(String text) =>
      text == '帮助' ||
      text == 'help' ||
      text == '?' ||
      text == '？' ||
      text.contains('怎么用');

  bool _matchAny(String text, List<String> keys) =>
      keys.any(text.contains);
}
