import '../billing/bill_models.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../state/app_store.dart';
import '../ui/format.dart';
import 'agent_models.dart';

const writeTools = {
  'add_property',
  'rename_property',
  'delete_property',
  'add_room',
  'rename_room',
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
  'set_period_remark',
  'add_period_fee',
  'remove_period_fee',
  'set_period_fees',
  'issue_invoice',
  'unfreeze_invoice',
  'mark_period_paid',
  'mark_period_unpaid',
  'create_note',
  'update_note',
  'convert_note_kind',
  'merge_notes_to_article',
  'publish_note',
  'unpublish_note',
};

/// 游客只下发只读 tools，避免模型提议写操作。
List<Map<String, dynamic>> toolSchemasFor({required bool landlord}) {
  if (landlord) return toolSchemas;
  return toolSchemas.where((t) {
    final fn = t['function'];
    if (fn is! Map) return false;
    final name = '${fn['name']}';
    return !writeTools.contains(name);
  }).toList();
}

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
          'city': {'type': 'string', 'description': '城市，如杭州'},
        },
        'required': ['name'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'rename_property',
      'description': '修改小区名称、城市或地址',
      'parameters': {
        'type': 'object',
        'properties': {
          'property_name': {'type': 'string', 'description': '原名称'},
          'new_name': {'type': 'string'},
          'address': {'type': 'string'},
          'city': {'type': 'string'},
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
      'name': 'rename_room',
      'description': '修改房间号/房间名称',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string', 'description': '原房号'},
          'new_label': {'type': 'string', 'description': '新房号'},
          'property_name': {'type': 'string', 'description': '所属小区，重名时必填'},
        },
        'required': ['room_label', 'new_label'],
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
        'required': ['room_label', 'rent_due_day', 'base_rent'],
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
      'description':
          '录入或修改单种表读数。可只改上期或只改本期（previous_reading / current_reading 可只传一个）。'
          '若用户一次说了水电多种表，请改用 record_meter_readings。',
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
      'name': 'set_period_remark',
      'description':
          '设置或修改最近一期未收账期的备注（显示在应收/账期列表）。'
          'remark 传空字符串表示清空备注。',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'remark': {'type': 'string', 'description': '备注内容；空则清空'},
        },
        'required': ['room_label', 'remark'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'add_period_fee',
      'description':
          '给最近一期未收账期加一项一次性额外费用（名称+金额）。'
          '不是每月附加费；同名则覆盖金额。amount=0 等同删除。',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'name': {'type': 'string', 'description': '费用名称，如维修费、卫生清扫'},
          'amount': {'type': 'number'},
        },
        'required': ['room_label', 'name', 'amount'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'remove_period_fee',
      'description': '按名称删除本月一次性额外费用',
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
      'name': 'set_period_fees',
      'description':
          '覆盖设置本月全部一次性额外费用列表。空数组=清空。'
          '与每月附加费（set_lease_extras）无关。',
      'parameters': {
        'type': 'object',
        'properties': {
          'room_label': {'type': 'string'},
          'property_name': {'type': 'string'},
          'fees': {
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
        'required': ['room_label', 'fees'],
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
  {
    'type': 'function',
    'function': {
      'name': 'list_notes',
      'description': '列出笔记本内容（随笔/备忘/日程/文章）',
      'parameters': {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'description': 'note|memo|schedule|article，空=全部',
          },
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'create_note',
      'description':
          '新建一条笔记。kind: note随笔/memo备忘/schedule日程/article文章。'
          '日程可设 recur_freq(once|daily|weekly|monthly|yearly)、recur_byday、'
          'recur_until/recur_count（结束，互斥）、remind_offset_min（提前分钟）',
      'parameters': {
        'type': 'object',
        'properties': {
          'kind': {'type': 'string'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'schedule_at': {
            'type': 'string',
            'description': 'ISO8601 日程时间',
          },
          'remind_at': {
            'type': 'string',
            'description': 'ISO8601 提醒时间（备忘绝对时间）',
          },
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
        'required': ['body'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_note',
      'description': '按 note_id 或标题关键词改笔记正文/标题/时间/重复/提醒',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string', 'description': '用标题或正文开头匹配'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'schedule_at': {'type': 'string'},
          'remind_at': {'type': 'string'},
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'convert_note_kind',
      'description': '把一篇笔记改成另一种形态（随笔/备忘/日程/文章），不自动上架',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
          'new_kind': {'type': 'string'},
          'schedule_at': {'type': 'string'},
          'remind_at': {'type': 'string'},
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
        'required': ['new_kind'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'merge_notes_to_article',
      'description':
          '把一篇或多篇笔记整理成一篇新文章；默认保留原文。body 填整理后的正文',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_ids': {
            'type': 'array',
            'items': {'type': 'integer'},
          },
          'title_queries': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'archive_sources': {
            'type': 'boolean',
            'description': 'true 时软删原文，默认 false',
          },
        },
        'required': ['body'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'publish_note',
      'description': '把文章上架到市集',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
          'city': {'type': 'string'},
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'unpublish_note',
      'description': '下架市集文章',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
        },
      },
    },
  }
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
      case 'rename_room':
        return '把房间 ${args['room_label']} 改名为 ${args['new_label']}';
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
      case 'set_period_remark':
        final r = '${args['remark'] ?? ''}'.trim();
        return r.isEmpty
            ? '清空 ${args['room_label']} 本月备注'
            : '把 ${args['room_label']} 本月备注改为「$r」';
      case 'add_period_fee':
        final amt = args['amount'];
        return (amt == 0 || amt == 0.0)
            ? '去掉 ${args['room_label']} 本月额外「${args['name']}」'
            : '给 ${args['room_label']} 加本月额外「${args['name']}」$amt';
      case 'remove_period_fee':
        return '去掉 ${args['room_label']} 本月额外「${args['name']}」';
      case 'set_period_fees':
        return '设置 ${args['room_label']} 本月额外费用：${_extrasText(args['fees'])}';
      case 'issue_invoice':
        return '为 ${args['room_label']} 最近一期出单冻结清单';
      case 'unfreeze_invoice':
        return '解除 ${args['room_label']} 最近一期出单冻结';
      case 'mark_period_paid':
        return '把 ${args['room_label']} 最近一期未收记为已收';
      case 'mark_period_unpaid':
        return '撤销 ${args['room_label']} 最近一期已收';
      case 'create_note':
        return '记一条${_kindLabel(args['kind'])}：'
            '${_snip(args['title'] ?? args['body'])}';
      case 'update_note':
        return '更新笔记 ${_snip(args['title_query'] ?? args['note_id'])}';
      case 'convert_note_kind':
        return '把笔记改成${_kindLabel(args['new_kind'])}';
      case 'merge_notes_to_article':
        return '整理成文章「${_snip(args['title'] ?? '无标题')}」（保留原文）';
      case 'publish_note':
        return '上架文章到市集';
      case 'unpublish_note':
        return '下架市集文章';
      default:
        return '执行 $tool';
    }
  }

  String _extrasText(dynamic raw) {
    final list = _parseExtras(raw);
    if (list.isEmpty) return '（清空）';
    return list.map((e) => '${e.name}${e.amount}').join('、');
  }
  String _kindLabel(dynamic kind) {
    switch ('$kind') {
      case 'memo':
        return '备忘';
      case 'schedule':
        return '日程';
      case 'article':
        return '文章';
      default:
        return '随笔';
    }
  }

  String _snip(dynamic raw) {
    final s = '$raw'.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '（无标题）';
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
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
      case 'list_notes':
        return _listNotes(args['kind']?.toString());
      default:
        throw StateError('$tool 不是只读工具');
    }
  }

  Future<String> commit(PendingAction action) async {
    if (store.isGuest) {
      return '游客不能改账本或笔记本。请先注册/登录后再操作。';
    }
    final args = action.args;
    switch (action.tool) {
      case 'add_property':
        await store.addProperty(
          '${args['name']}'.trim(),
          '${args['address'] ?? ''}'.trim(),
          city: '${args['city'] ?? ''}'.trim(),
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
          city: args['city']?.toString(),
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
      case 'rename_room':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final newLabel = '${args['new_label']}'.trim();
        if (newLabel.isEmpty) return '新房号不能为空。';
        final old = snap.room.label;
        await store.renameRoom(id: snap.room.id, label: newLabel);
        return '已改房号：$old → $newLabel。';
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
        final tenantName = '${args['tenant_name'] ?? ''}'.trim();
        await store.saveLease(
          roomId: room.id,
          tenantName: tenantName.isEmpty ? '未填写' : tenantName,
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
      case 'set_period_remark':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        final remark = '${args['remark'] ?? ''}'.trim();
        await store.updatePeriodRemark(periodId: periodId, remark: remark);
        return remark.isEmpty
            ? '已清空 ${snap.room.label} 本月备注。'
            : '已更新 ${snap.room.label} 本月备注：「$remark」。';
      case 'add_period_fee':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        final feeName = '${args['name']}'.trim();
        final feeAmt = _asDouble(args['amount']) ?? 0;
        await store.upsertPeriodFee(
          periodId: periodId,
          name: feeName,
          amount: feeAmt,
        );
        return feeAmt <= 0
            ? '已去掉本月额外「$feeName」。\n${await _previewBill(snap.room.label, null)}'
            : '已加本月额外「$feeName」$feeAmt。\n${await _previewBill(snap.room.label, null)}';
      case 'remove_period_fee':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        final rmName = '${args['name']}'.trim();
        await store.removePeriodFee(periodId: periodId, name: rmName);
        return '已去掉本月额外「$rmName」。\n${await _previewBill(snap.room.label, null)}';
      case 'set_period_fees':
        final snap = await _resolveOneRoom(
          '${args['room_label']}'.trim(),
          args['property_name']?.toString(),
        );
        final lease = snap.lease;
        if (lease == null) return '${snap.room.label} 还没有在租租约。';
        final periodId = await _db.latestOpenPeriodIdForLease(lease.id);
        if (periodId == null) return '${snap.room.label} 没有未收账期。';
        final oldFees = await _db.listPeriodFees(periodId);
        for (final f in oldFees) {
          await store.removePeriodFee(periodId: periodId, name: f.name);
        }
        for (final e in _parseExtras(args['fees'])) {
          if (e.amount <= 0) continue;
          await store.upsertPeriodFee(
            periodId: periodId,
            name: e.name,
            amount: e.amount,
          );
        }
        return '已更新本月额外费用。\n${await _previewBill(snap.room.label, null)}';
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
        return '已解除冻结，可改抄表/优惠/额外费用后重新出单。\n${bill.toShareText()}';
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
      case 'create_note':
        final kind = '${args['kind'] ?? kNoteKindNote}'.trim();
        final k = kind.isEmpty ? kNoteKindNote : kind;
        final scheduleAt = _parseNoteTs(args['schedule_at']);
        final recur = _parseRecurArgs(args, scheduleAt: scheduleAt, kind: k);
        final id = await store.addNote(
          kind: k,
          title: '${args['title'] ?? ''}'.trim(),
          body: '${args['body'] ?? ''}',
          scheduleAt: scheduleAt,
          remindAt: recur.remindAt ?? _parseNoteTs(args['remind_at']),
          recurFreq: recur.recurFreq == kRecurOnce ? '' : recur.recurFreq,
          recurByday: recur.recurByday,
          recurUntil: recur.recurUntil,
          recurCount: recur.recurCount,
          remindOffsetMin: recur.remindOffsetMin ?? 0,
        );
        return '已记下${_kindLabel(k)} #$id。';
      case 'update_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到要改的笔记。';
        final scheduleAt = args.containsKey('schedule_at')
            ? _parseNoteTs(args['schedule_at'])
            : note.scheduleAt;
        final recur = _parseRecurArgs(
          args,
          scheduleAt: scheduleAt,
          kind: note.kind,
        );
        await store.saveNote(
          id: note.id,
          title: args.containsKey('title') ? '${args['title']}'.trim() : null,
          body: args.containsKey('body') ? '${args['body']}' : null,
          scheduleAt: args.containsKey('schedule_at') ? scheduleAt : null,
          clearScheduleAt:
              args.containsKey('schedule_at') && scheduleAt == null,
          remindAt: recur.remindAt ??
              (args.containsKey('remind_at')
                  ? _parseNoteTs(args['remind_at'])
                  : null),
          clearRemindAt: args.containsKey('remind_at') &&
              (args['remind_at'] == null ||
                  '${args['remind_at']}'.trim().isEmpty) &&
              recur.remindOffsetMin == null,
          recurFreq: args.containsKey('recur_freq')
              ? (recur.recurFreq == kRecurOnce ? '' : recur.recurFreq)
              : null,
          recurByday: recur.recurByday,
          clearRecurByday: recur.clearByday,
          recurUntil: recur.recurUntil,
          clearRecurUntil: recur.clearUntil,
          recurCount: recur.recurCount,
          clearRecurCount: recur.clearCount,
          remindOffsetMin: recur.remindOffsetMin,
        );
        return '已更新笔记 #${note.id}。';
      case 'convert_note_kind':
        final note = await _resolveNote(args);
        if (note == null) return '找不到要转换的笔记。';
        final newKind = '${args['new_kind']}'.trim();
        if (newKind.isEmpty) return '请指定 new_kind。';
        final scheduleAt = args.containsKey('schedule_at')
            ? _parseNoteTs(args['schedule_at'])
            : note.scheduleAt;
        final recur = _parseRecurArgs(
          args,
          scheduleAt: scheduleAt,
          kind: newKind,
        );
        await store.saveNote(
          id: note.id,
          kind: newKind,
          scheduleAt: args.containsKey('schedule_at') ? scheduleAt : null,
          remindAt: recur.remindAt ??
              (args.containsKey('remind_at')
                  ? _parseNoteTs(args['remind_at'])
                  : null),
          recurFreq: args.containsKey('recur_freq')
              ? (recur.recurFreq == kRecurOnce ? '' : recur.recurFreq)
              : null,
          recurByday: recur.recurByday,
          clearRecurByday: recur.clearByday,
          recurUntil: recur.recurUntil,
          clearRecurUntil: recur.clearUntil,
          recurCount: recur.recurCount,
          clearRecurCount: recur.clearCount,
          remindOffsetMin: recur.remindOffsetMin,
        );
        return '已把 #${note.id} 改成${_kindLabel(newKind)}。';
      case 'merge_notes_to_article':
        final ids = <int>{};
        final idList = args['note_ids'];
        if (idList is List) {
          for (final e in idList) {
            final id = e is int ? e : int.tryParse('$e');
            if (id != null) ids.add(id);
          }
        }
        final queries = args['title_queries'];
        if (queries is List) {
          final all = await store.notesOf();
          for (final q in queries) {
            final s = '$q'.trim();
            if (s.isEmpty) continue;
            for (final n in all) {
              if (n.title.contains(s) || n.body.contains(s)) ids.add(n.id);
            }
          }
        }
        final sources = <Note>[];
        for (final id in ids) {
          final n = await store.db.noteById(id);
          if (n != null) sources.add(n);
        }
        final body = '${args['body'] ?? ''}'.trim();
        if (body.isEmpty) return '整理后的正文不能为空。';
        final newId = await store.addNote(
          kind: kNoteKindArticle,
          title: '${args['title'] ?? ''}'.trim(),
          body: body,
          sourceNoteUuids: sources.map((e) => e.uuid).toList(),
        );
        if (args['archive_sources'] == true) {
          for (final s in sources) {
            await store.removeNote(s.id);
          }
        }
        return '已生成文章 #$newId'
            '${sources.isEmpty ? '' : '（来源 ${sources.length} 篇，默认保留）'}。';
      case 'publish_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到文章。';
        if (note.kind != kNoteKindArticle) {
          await store.saveNote(id: note.id, kind: kNoteKindArticle);
        }
        await store.setNoteListing(
          noteId: note.id,
          listed: true,
          city: args['city']?.toString(),
        );
        return '已上架文章 #${note.id}。';
      case 'unpublish_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到文章。';
        await store.setNoteListing(noteId: note.id, listed: false);
        return '已下架文章 #${note.id}。';
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
      final previous = _asDouble(r['previous_reading']);
      if (current == null && previous == null) {
        return '${meterKindLabel(kind)}表缺少读数（可只说本月或只说上月）';
      }
      await store.recordMeterReading(
        leaseId: lease.id,
        kind: kind,
        reading: current,
        periodId: periodId,
        previousReading: previous,
      );
      final tip = [
        if (previous != null) '上月$previous',
        if (current != null) '本月$current',
      ].join('→');
      done.add('${meterKindLabel(kind)}表($tip)');
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

  Future<String> _listNotes(String? kind) async {
    final notes = await store.notesOf(
      kind: (kind == null || kind.trim().isEmpty) ? null : kind.trim(),
    );
    if (notes.isEmpty) return '笔记本是空的。';
    final buf = StringBuffer('笔记列表：\n');
    for (final n in notes.take(40)) {
      final extra = noteRecurRemindSummary(n);
      buf.writeln(
        '· #${n.id} [${n.kindLabel}] ${n.displayTitle}'
        '${n.isListed ? '（已上架）' : ''}'
        '${extra.isEmpty ? '' : ' · $extra'}',
      );
    }
    return buf.toString().trimRight();
  }

  Future<Note?> _resolveNote(Map<String, dynamic> args) async {
    final idRaw = args['note_id'];
    final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
    if (id != null) return store.db.noteById(id);
    final q = '${args['title_query'] ?? ''}'.trim();
    if (q.isEmpty) return null;
    final all = await store.notesOf();
    for (final n in all) {
      if (n.title.contains(q) ||
          n.body.contains(q) ||
          n.displayTitle.contains(q)) {
        return n;
      }
    }
    return null;
  }

  DateTime? _parseNoteTs(dynamic raw) {
    if (raw == null) return null;
    final s = '$raw'.trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  int? _parseIntArg(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse('$raw'.trim());
  }

  ({
    String recurFreq,
    String? recurByday,
    DateTime? recurUntil,
    int? recurCount,
    bool clearUntil,
    bool clearCount,
    bool clearByday,
    int? remindOffsetMin,
    DateTime? remindAt,
  }) _parseRecurArgs(
    Map<String, dynamic> args, {
    DateTime? scheduleAt,
    String? kind,
  }) {
    final freqRaw = args.containsKey('recur_freq')
        ? normalizeRecurFreq('${args['recur_freq']}')
        : null;
    final freq = freqRaw ?? '';
    String? byday;
    var clearByday = false;
    if (args.containsKey('recur_byday')) {
      final b = '${args['recur_byday']}'.trim().toUpperCase();
      if (b.isEmpty) {
        clearByday = true;
        byday = null;
      } else {
        byday = b;
      }
    } else if (freq == kRecurWeekly && scheduleAt != null) {
      byday = weekdayToByDay(scheduleAt);
    }

    DateTime? until;
    int? count;
    var clearUntil = false;
    var clearCount = false;
    final hasUntil = args.containsKey('recur_until');
    final hasCount = args.containsKey('recur_count');
    if (hasUntil) {
      final raw = args['recur_until'];
      if (raw == null || '$raw'.trim().isEmpty) {
        clearUntil = true;
        until = null;
      } else {
        until = _parseNoteTs(raw);
        clearCount = true;
        count = null;
      }
    }
    if (hasCount) {
      final raw = args['recur_count'];
      if (raw == null || '$raw'.trim().isEmpty) {
        clearCount = true;
        count = null;
      } else {
        count = _parseIntArg(raw);
        clearUntil = true;
        until = null;
      }
    }

    int? offset;
    DateTime? remind = _parseNoteTs(args['remind_at']);
    if (args.containsKey('remind_offset_min')) {
      final parsed = _parseIntArg(args['remind_offset_min']) ?? 0;
      offset = parsed < 0 ? 0 : parsed;
      if (kind == kNoteKindSchedule || kind == null) {
        remind = remindAtFromOffset(scheduleAt, offset);
      }
    }

    return (
      recurFreq: freq,
      recurByday: byday,
      recurUntil: until,
      recurCount: count,
      clearUntil: clearUntil,
      clearCount: clearCount,
      clearByday: clearByday,
      remindOffsetMin: offset,
      remindAt: remind,
    );
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
