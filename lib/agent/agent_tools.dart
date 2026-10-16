import '../billing/bill_models.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import '../ui/format.dart';
import 'agent_models.dart';

const writeTools = {
  'add_property',
  'rename_property',
  'delete_property',
  'add_room',
  'delete_room',
  'create_lease',
  'update_lease',
  'update_rent_due_day',
  'update_lease_tenant',
  'end_lease',
  'set_lease_extras',
  'add_lease_extra',
  'remove_lease_extra',
  'set_meter_rates',
  'record_meter_reading',
  'record_meter_readings',
  'apply_period_discount',
  'issue_invoice',
  'unfreeze_invoice',
  'mark_period_paid',
  'mark_period_unpaid',
};

/// OpenAI-compatible tools schema（发给大模型用）。
final List<Map<String, dynamic>> toolSchemas = [
  {
    'type': 'function',
    'function': {
      'name': 'list_inventory',
      'description': '列出当前所有小区、房间和在租租约摘要',
      'parameters': {'type': 'object', 'properties': {}},
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'list_upcoming_dues',
      'description': '列出未收账期（应收）',
      'parameters': {
        'type': 'object',
        'properties': {
          'days': {'type': 'integer', 'description': '未来几天，默认 30'},
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'preview_rent_bill',
      'description': '试算某房间最近一期未收清单（含水电、附加费、优惠），不出单',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'add_property',
      'description': '新增一处房产/小区',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'address': {'type': 'string'},
        },
        'required': ['name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'rename_property',
      'description': '修改小区名称或地址',
      'parameters': {
        'type': 'object',
        'properties': {
          'property_name': {'type': 'string', 'description': '原名称'},
          'new_name': {'type': 'string'},
          'address': {'type': 'string'},
        },
        'required': ['property_name', 'new_name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'delete_property',
      'description': '删除整个小区及其下房间、租约（危险操作）',
      'parameters': {
        'type': 'object',
        'properties': {
          'property_name': {'type': 'string'},
        },
        'required': ['property_name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'add_room',
      'description': '在指定小区下新增房间',
      'parameters': {
        'type': 'object',
        'properties': {
          'property_name': {'type': 'string'},
          'room_label': {'type': 'string'},
          'create_property_if_missing': {'type': 'boolean'},
        },
        'required': ['property_name', 'room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'delete_room',
      'description': '删除房间及其租约账期（危险操作）',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'create_lease',
      'description': '登记租约并生成账期；extras 为多项每月附加费',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'tenant_name': {'type': 'string'},
          'tenant_phone': {'type': 'string'},
          'rent_due_day': {'type': 'integer'},
          'base_rent': {'type': 'number'},
          'deposit': {'type': 'number'},
          'electric_price': {'type': 'number'},
          'water_price': {'type': 'number'},
          'gas_price': {'type': 'number'},
          'extras': {
            'type': 'array',
            'description': '附加费列表，如 [{name:物业费,amount:150},{name:网费,amount:50}]',
            'items': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'amount': {'type': 'number'},
              },
              'required': ['name', 'amount'],
            },
          },
          'start_date': {'type': 'string'},
          'end_date': {'type': 'string'},
          'auto_create_room': {'type': 'boolean'},
        },
        'required': ['room_label', 'tenant_name', 'rent_due_day', 'base_rent'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_lease',
      'description': '修改在租租约字段（房租/押金/日期/单价等，未传的字段保持原值）',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'tenant_name': {'type': 'string'},
          'tenant_phone': {'type': 'string'},
          'rent_due_day': {'type': 'integer'},
          'base_rent': {'type': 'number'},
          'deposit': {'type': 'number'},
          'electric_price': {'type': 'number'},
          'water_price': {'type': 'number'},
          'gas_price': {'type': 'number'},
          'start_date': {'type': 'string'},
          'end_date': {'type': 'string'},
          'extras': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'amount': {'type': 'number'},
              },
            },
          },
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_rent_due_day',
      'description': '修改每月收款日',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'rent_due_day': {'type': 'integer'},
        },
        'required': ['room_label', 'rent_due_day'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_lease_tenant',
      'description': '修改在租租户姓名/电话',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'tenant_name': {'type': 'string'},
          'tenant_phone': {'type': 'string'},
        },
        'required': ['room_label', 'tenant_name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'end_lease',
      'description': '办理退租：租约结束，房间变空房',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'end_date': {'type': 'string', 'description': 'YYYY-MM-DD，默认今天'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'set_lease_extras',
      'description': '覆盖设置租约的全部每月附加费项（名称+金额）',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'extras': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'amount': {'type': 'number'},
              },
              'required': ['name', 'amount'],
            },
          },
        },
        'required': ['room_label', 'extras'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'add_lease_extra',
      'description': '追加一项每月附加费',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'name': {'type': 'string'},
          'amount': {'type': 'number'},
        },
        'required': ['room_label', 'name', 'amount'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'remove_lease_extra',
      'description': '按名称删除一项每月附加费',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'name': {'type': 'string'},
        },
        'required': ['room_label', 'name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'set_meter_rates',
      'description': '设置水电燃单价（不含附加费，附加费用 set_lease_extras）',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'electric_price': {'type': 'number'},
          'water_price': {'type': 'number'},
          'gas_price': {'type': 'number'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'record_meter_reading',
      'description': '录入单种表读数。若用户一次说了水电多种表，请改用 record_meter_readings。',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'kind': {'type': 'string', 'description': 'electric/water/gas 或 电/水/燃'},
          'previous_reading': {'type': 'number'},
          'current_reading': {'type': 'number'},
        },
        'required': ['room_label', 'kind', 'current_reading'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'record_meter_readings',
      'description':
          '一次录入多种抄表（水+电+燃）。用户同时报了多种表时必须用这个，不要只录一种。',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'readings': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {
                  'type': 'string',
                  'description': 'electric/water/gas 或 电/水/燃',
                },
                'previous_reading': {'type': 'number'},
                'current_reading': {'type': 'number'},
              },
              'required': ['kind', 'current_reading'],
            },
          },
        },
        'required': ['room_label', 'readings'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'apply_period_discount',
      'description': '本月优惠减免（不改合同房租）',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'amount': {'type': 'number'},
          'note': {'type': 'string'},
        },
        'required': ['room_label', 'amount'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'issue_invoice',
      'description': '为最近一期未收账期出单冻结清单',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'unfreeze_invoice',
      'description':
          '解除最近一期已出单冻结，恢复试算以便改抄表/优惠；改完需重新 issue_invoice',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'mark_period_paid',
      'description': '记最近一期未收为已收',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'mark_period_unpaid',
      'description': '撤销最近一期已收，改回未收',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
        },
        'required': ['room_label'],
      },
    },
  },
];

class AgentToolRunner {
  AgentToolRunner(this.store, {AppDatabase? db})
      : _db = db ?? AppDatabase.instance;

  final AppStore store;
  final AppDatabase _db;

  String summarize(String tool, Map<String, dynamic> args) {
    switch (tool) {
      case 'add_property':
        return '新增小区「${args['name']}」';
      case 'rename_property':
        return '把小区「${args['property_name']}」改名为「${args['new_name']}」';
      case 'delete_property':
        return '删除小区「${args['property_name']}」及其全部房间租约';
      case 'add_room':
        return '在「${args['property_name']}」下新增房间 ${args['room_label']}';
      case 'delete_room':
        return '删除房间 ${args['room_label']}（含租约账期）';
      case 'create_lease':
        return '给 ${args['room_label']} 登记租约：${args['tenant_name']}，'
            '每月${args['rent_due_day']}号，房租 ${args['base_rent']}';
      case 'update_lease':
        return '修改 ${args['room_label']} 的租约信息';
      case 'update_rent_due_day':
        return '把 ${args['room_label']} 收款日改为每月${args['rent_due_day']}号';
      case 'update_lease_tenant':
        return '把 ${args['room_label']} 租户改为 ${args['tenant_name']}';
      case 'end_lease':
        return '办理 ${args['room_label']} 退租';
      case 'set_lease_extras':
        return '设置 ${args['room_label']} 附加费：${_extrasText(args['extras'])}';
      case 'add_lease_extra':
        return '给 ${args['room_label']} 加附加费「${args['name']}」${args['amount']}';
      case 'remove_lease_extra':
        return '去掉 ${args['room_label']} 附加费「${args['name']}」';
      case 'set_meter_rates':
        return '设置 ${args['room_label']} 单价：电${args['electric_price'] ?? '-'} '
            '水${args['water_price'] ?? '-'} 燃${args['gas_price'] ?? '-'}';
      case 'record_meter_reading':
        final kind = meterKindLabel(
          parseMeterKind('${args['kind']}') ?? '${args['kind']}',
        );
        final prev = args['previous_reading'];
        return prev == null
            ? '录入 ${args['room_label']} ${kind}表本期 ${args['current_reading']}'
            : '录入 ${args['room_label']} ${kind}表 $prev→${args['current_reading']}';
      case 'record_meter_readings':
        final parts = <String>[];
        final list = args['readings'];
        if (list is List) {
          for (final r in list) {
            if (r is! Map) continue;
            final k = meterKindLabel(
              parseMeterKind('${r['kind']}') ?? '${r['kind']}',
            );
            parts.add(
              '$k ${r['previous_reading'] ?? '?'}→${r['current_reading']}',
            );
          }
        }
        return '录入 ${args['room_label']} 抄表：${parts.join('；')}';
      case 'apply_period_discount':
        final a = args['amount'];
        return (a == 0 || a == 0.0)
            ? '清除 ${args['room_label']} 本月优惠'
            : '${args['room_label']} 本月优惠减免 $a';
      case 'issue_invoice':
        return '为 ${args['room_label']} 最近一期出单冻结清单';
      case 'unfreeze_invoice':
        return '解除 ${args['room_label']} 最近一期出单冻结';
      case 'mark_period_paid':
        return '把 ${args['room_label']} 最近一期未收记为已收';
      case 'mark_period_unpaid':
        return '撤销 ${args['room_label']} 最近一期已收';
      default:
        return '执行 $tool';
    }
  }

  String _extrasText(dynamic raw) {
    final list = _parseExtras(raw);
    if (list.isEmpty) return '（清空）';
    return list.map((e) => '${e.name}${e.amount}').join('、');
  }

  Future<String> runRead(String tool, Map<String, dynamic> args) async {
    switch (tool) {
      case 'list_inventory':
        return _listInventory();
      case 'list_upcoming_dues':
        return _listDues(args['days'] is int ? args['days'] as int : 30);
      case 'preview_rent_bill':
        return _previewBill(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
      default:
        throw StateError('$tool 不是只读工具');
    }
  }

  Future<String> commit(PendingAction action) async {
    final args = action.args;
    switch (action.tool) {
      case 'add_property':
        await store.addProperty(
          '${args['name']}'.trim(),
          '${args['address'] ?? ''}'.trim(),
        );
        return '已添加小区「${args['name']}」。';
      case 'rename_property':
        final prop =
            await _db.findPropertyByName('${args['property_name']}'.trim());
        if (prop == null) return '找不到小区「${args['property_name']}」。';
        await store.renameProperty(
          id: prop.id,
          name: '${args['new_name']}'.trim(),
          address: args['address']?.toString(),
        );
        return '已改名：${prop.name} → ${args['new_name']}。';
      case 'delete_property':
        final prop =
            await _db.findPropertyByName('${args['property_name']}'.trim());
        if (prop == null) return '找不到小区「${args['property_name']}」。';
        await store.removeProperty(prop.id);
        return '已删除小区「${prop.name}」。';
      case 'add_room':
        final property = await _ensureProperty(
          '${args['property_name']}'.trim(),
          createIfMissing: args['create_property_if_missing'] != false,
        );
        await store.addRoom(property.id, '${args['room_label']}'.trim());
        return '已在「${property.name}」添加房间 ${args['room_label']}。';
      case 'delete_room':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        await store.removeRoom(snap.room.id);
        return '已删除房间 ${snap.room.label}。';
      case 'create_lease':
        final room = await _resolveOrCreateRoom(
          label: '${args['room_label']}'.trim(),
          propertyName: args['property_name']?.toString(),
          autoCreate: args['auto_create_room'] != false,
        );
        // 已有在租约：改成更新，避免结束旧约导致抄表/账期断掉。
        final existing = await _db.activeLeaseForRoom(room.id);
        if (existing != null) {
          final merged = Map<String, dynamic>.from(args);
          merged['room_label'] = room.label;
          // 误用 create 且没带有效附加费时，不要清空已有 extras
          if (_parseExtras(args['extras']).isEmpty) {
            merged.remove('extras');
          }
          return _updateLeaseFields(merged);
        }
        final start = parseYmd(args['start_date']?.toString()) ??
            dateOnly(DateTime.now());
        final extras = _parseExtras(args['extras']);
        // 兼容旧说法：单个 fixed_extra
        final legacy = _asDouble(args['fixed_extra']);
        final items = extras.isNotEmpty
            ? extras
            : (legacy != null && legacy > 0
                ? [
                    LeaseExtraItem(
                      name: '${args['fixed_extra_label'] ?? '固定杂费'}',
                      amount: legacy,
                    )
                  ]
                : <LeaseExtraItem>[]);
        await store.saveLease(
          roomId: room.id,
          tenantName: '${args['tenant_name']}'.trim(),
          tenantPhone: '${args['tenant_phone'] ?? ''}'.trim(),
          startDate: start,
          endDate: parseYmd(args['end_date']?.toString()),
          rentDueDay: _asInt(args['rent_due_day'])!,
          baseRent: _asDouble(args['base_rent'])!,
          deposit: _asDouble(args['deposit']) ?? _asDouble(args['base_rent'])!,
          electricPrice: _asDouble(args['electric_price']) ?? 0,
          waterPrice: _asDouble(args['water_price']) ?? 0,
          gasPrice: _asDouble(args['gas_price']) ?? 0,
          extras: items,
        );
        return '已为 ${room.label} 登记租约，并生成账期与提醒。';
      case 'update_lease':
        return _updateLeaseFields(args);
      case 'update_rent_due_day':
        return _updateLeaseFields({
          ...args,
          'rent_due_day': args['rent_due_day'],
        });
      case 'update_lease_tenant':
        return _updateLeaseFields(args);
      case 'end_lease':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 没有在租租约。';
        await store.endLease(
          leaseId: lease.id,
          endDate: parseYmd(args['end_date']?.toString()),
        );
        return '已办理 ${snap.room.label} 退租。';
      case 'set_lease_extras':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        await store.setLeaseExtras(
          leaseId: lease.id,
          extras: _parseExtras(args['extras']),
        );
        return '已更新附加费。\n${await _previewBill(snap.room.label, null)}';
      case 'add_lease_extra':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final cur = List<LeaseExtraItem>.from(lease.effectiveExtras);
        cur.add(
          LeaseExtraItem(
            name: '${args['name']}'.trim(),
            amount: _asDouble(args['amount']) ?? 0,
          ),
        );
        await store.setLeaseExtras(leaseId: lease.id, extras: cur);
        return '已添加附加费「${args['name']}」。';
      case 'remove_lease_extra':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final name = '${args['name']}'.trim();
        final next = lease.effectiveExtras
            .where((e) => e.name != name)
            .toList();
        await store.setLeaseExtras(leaseId: lease.id, extras: next);
        return '已去掉附加费「$name」。';
      case 'set_meter_rates':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        await store.setMeterRates(
          leaseId: lease.id,
          electricPrice:
              _asDouble(args['electric_price']) ?? lease.electricPrice,
          waterPrice: _asDouble(args['water_price']) ?? lease.waterPrice,
          gasPrice: _asDouble(args['gas_price']) ?? lease.gasPrice,
        );
        return '已更新 ${snap.room.label} 的计费单价。';
      case 'record_meter_reading':
        return _recordMeters(args, [
          {
            'kind': args['kind'],
            'previous_reading': args['previous_reading'],
            'current_reading': args['current_reading'],
          },
        ]);
      case 'record_meter_readings':
        final list = args['readings'];
        if (list is! List || list.isEmpty) return '缺少 readings 列表';
        return _recordMeters(
          args,
          list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
        );
      case 'apply_period_discount':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        await store.applyDiscount(
          periodId: periodId,
          amount: _asDouble(args['amount']) ?? 0,
          note: '${args['note'] ?? '心情减免'}',
        );
        return '已更新优惠。\n${await _previewBill(snap.room.label, null)}';
      case 'issue_invoice':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        final bill = await store.issueBill(periodId);
        return '已出单。\n${bill.toShareText()}';
      case 'unfreeze_invoice':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _latestInvoicedPeriodId(lease.id);
        if (periodId == null) {
          return '${snap.room.label} 没有已冻结的账期可解除。';
        }
        final bill = await store.unfreezeBill(periodId);
        return '已解除冻结，可改抄表/优惠后重新出单。\n${bill.toShareText()}';
      case 'mark_period_paid':
        final label = '${args['room_label']}'.trim();
        final due = store.pending.where((e) => e.roomLabel == label).toList();
        if (due.isEmpty) return '$label 没有未收账期。';
        await store.markPaid(due.first.period.id);
        return '已把 $label ${md(due.first.period.dueDate)} 那期记为已收。';
      case 'mark_period_unpaid':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 没有在租租约。';
        final periods = await _db.periodsForLease(lease.id);
        final paid = periods.where((p) => p.isPaid).toList();
        if (paid.isEmpty) return '${snap.room.label} 没有已收账期可撤销。';
        await store.markUnpaid(paid.first.id);
        return '已撤销 ${snap.room.label} ${md(paid.first.dueDate)} 的已收。';
      default:
        return '未知操作：${action.tool}';
    }
  }

  Future<int?> _latestInvoicedPeriodId(int leaseId) async {
    final periods = await _db.periodsForLease(leaseId);
    for (final p in periods) {
      if (p.isPaid) continue;
      final inv = await _db.latestInvoiceForPeriod(p.id);
      if (inv != null) return p.id;
    }
    return null;
  }

  Future<String> _recordMeters(
    Map<String, dynamic> args,
    List<Map<String, dynamic>> readings,
  ) async {
    final snap = await _resolveOneRoom(
      '${args['room_label']}'.trim(),
      args['property_name']?.toString(),
    );
    final lease = snap.lease;
    if (lease == null) return '${snap.room.label} 还没有在租租约。';
    final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
    if (periodId == null) return '${snap.room.label} 没有可抄表的账期。';
    final frozen = await _db.latestInvoiceForPeriod(periodId);
    if (frozen != null) {
      return '${snap.room.label} 本期已出单冻结。请先说「解除冻结」，再改抄表。';
    }
    final done = <String>[];
    for (final r in readings) {
      final kind = parseMeterKind('${r['kind']}') ?? '${r['kind']}';
      if (!const ['electric', 'water', 'gas'].contains(kind)) {
        return '表种请用 电/水/燃气（收到：${r['kind']}）';
      }
      final current = _asDouble(r['current_reading']);
      if (current == null) return '${meterKindLabel(kind)}表缺少本期读数';
      await store.recordMeterReading(
        leaseId: lease.id,
        kind: kind,
        reading: current,
        periodId: periodId,
        previousReading: _asDouble(r['previous_reading']),
      );
      done.add(meterKindLabel(kind));
    }
    final bill =
        await _previewBill(snap.room.label, args['property_name']?.toString());
    return '已录入${done.join('、')}表。\n$bill';
  }

  Future<String> _updateLeaseFields(Map<String, dynamic> args) async {
    final snap = await _resolveOneRoom(
      '${args['room_label']}'.trim(),
      args['property_name']?.toString(),
    );
    final lease = snap.lease;
    final tenant = snap.tenant;
    if (lease == null || tenant == null) {
      return '${snap.room.label} 还没有在租租约。';
    }
    final extras = args.containsKey('extras')
        ? _parseExtras(args['extras'])
        : lease.effectiveExtras;
    await store.saveLease(
      leaseId: lease.id,
      roomId: snap.room.id,
      tenantName: args['tenant_name'] != null
          ? '${args['tenant_name']}'.trim()
          : tenant.name,
      tenantPhone: args['tenant_phone'] != null
          ? '${args['tenant_phone']}'.trim()
          : tenant.phone,
      startDate:
          parseYmd(args['start_date']?.toString()) ?? lease.startDate,
      endDate: args.containsKey('end_date')
          ? parseYmd(args['end_date']?.toString())
          : lease.endDate,
      rentDueDay: _asInt(args['rent_due_day']) ?? lease.rentDueDay,
      baseRent: _asDouble(args['base_rent']) ?? lease.baseRent,
      deposit: _asDouble(args['deposit']) ?? lease.deposit,
      electricPrice: _asDouble(args['electric_price']) ?? lease.electricPrice,
      waterPrice: _asDouble(args['water_price']) ?? lease.waterPrice,
      gasPrice: _asDouble(args['gas_price']) ?? lease.gasPrice,
      extras: extras,
    );
    return '已更新 ${snap.room.label} 的租约。';
  }

  List<LeaseExtraItem> _parseExtras(dynamic raw) {
    if (raw is! List) return const [];
    final out = <LeaseExtraItem>[];
    var i = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final name = '${item['name'] ?? ''}'.trim();
      final amount = _asDouble(item['amount']);
      if (name.isEmpty || amount == null || amount == 0) continue;
      out.add(LeaseExtraItem(name: name, amount: amount, sortOrder: i++));
    }
    return out;
  }

  Future<String> _previewBill(String roomLabel, String? propertyName) async {
    final snap = await _resolveOneRoom(roomLabel, propertyName);
    final lease = snap.lease;
    if (lease == null) return '$roomLabel 没有在租租约。';
    final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
    if (periodId == null) return '$roomLabel 没有未收账期。';
    final bill = await store.previewBill(periodId);
    return bill.toShareText();
  }

  Future<String> _listInventory() async {
    final rows = await _db.inventorySummary();
    if (rows.isEmpty) return '还没有任何小区。可以说「加个小区叫阳光花园」。';
    final buf = StringBuffer('当前房源：\n');
    String? lastProp;
    for (final r in rows) {
      final prop = r['property_name'] as String? ?? '';
      if (prop != lastProp) {
        buf.writeln('【$prop】');
        lastProp = prop;
      }
      final room = r['room_label'] as String?;
      if (room == null) {
        buf.writeln('  （暂无房间）');
        continue;
      }
      final tenant = r['tenant_name'] as String?;
      if (tenant == null) {
        buf.writeln('  $room · 空房');
      } else {
        buf.writeln(
          '  $room · $tenant · 每月${r['rent_due_day']}号 · ${formatYuan((r['base_rent'] as num).toDouble())}',
        );
      }
    }
    return buf.toString().trimRight();
  }

  Future<String> _listDues(int days) async {
    await store.reload();
    final today = dateOnly(DateTime.now());
    final until = today.add(Duration(days: days));
    final items = store.pending
        .where((e) => !e.period.dueDate.isAfter(until))
        .toList();
    if (items.isEmpty) return '未来 $days 天没有未收账期。';
    final buf = StringBuffer('未收账期：\n');
    for (final e in items) {
      final tag = e.period.dueDate.isBefore(today)
          ? '逾期'
          : (e.period.dueDate == today ? '今天' : md(e.period.dueDate));
      buf.writeln(
        '· $tag ${e.roomLabel} ${e.tenantName} 应收 ${formatYuan(e.period.amount)}',
      );
    }
    return buf.toString().trimRight();
  }

  Future<Property> _ensureProperty(
    String name, {
    required bool createIfMissing,
  }) async {
    final existing = await _db.findPropertyByName(name);
    if (existing != null) return existing;
    if (!createIfMissing) throw StateError('找不到小区「$name」');
    final id = await store.addProperty(name, '');
    return (await _db.getProperty(id))!;
  }

  Future<Room> _resolveOrCreateRoom({
    required String label,
    String? propertyName,
    required bool autoCreate,
  }) async {
    final matches =
        await _db.findRoomsByLabel(label, propertyName: propertyName);
    if (matches.length == 1) return matches.first.room;
    if (matches.length > 1) {
      throw StateError('有多间房叫 $label，请说明小区名。');
    }
    if (!autoCreate) throw StateError('找不到房间 $label。');
    final props = await _db.listProperties();
    Property property;
    if (propertyName != null && propertyName.trim().isNotEmpty) {
      property =
          await _ensureProperty(propertyName.trim(), createIfMissing: true);
    } else if (props.length == 1) {
      property = props.first;
    } else if (props.isEmpty) {
      final id = await store.addProperty('默认小区', '');
      property = (await _db.getProperty(id))!;
    } else {
      throw StateError('有多个小区，请带上小区名。');
    }
    final roomId = await store.addRoom(property.id, label);
    return (await _db.getRoom(roomId))!;
  }

  Future<RoomSnapshot> _resolveOneRoom(
    String label,
    String? propertyName,
  ) async {
    final matches =
        await _db.findRoomsByLabel(label, propertyName: propertyName);
    if (matches.isEmpty) throw StateError('找不到房间 $label。');
    if (matches.length > 1) throw StateError('有多间房叫 $label，请带上小区名。');
    return matches.first;
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse('$v'.replaceAll(',', ''));
  }
}
