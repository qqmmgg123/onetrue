import 'note_title.dart';

class Property {
  const Property({
    required this.id,
    required this.name,
    required this.address,
    this.city = '',
  });

  final int id;
  final String name;
  final String address;

  /// 城市名，如「杭州」，用于市集筛选。
  final String city;
}

/// 房间上架状态：draft=仅自己可见，listed=市集可见。
const kListingDraft = 'draft';
const kListingListed = 'listed';

/// 笔记形态。
const kNoteKindNote = 'note';
const kNoteKindMemo = 'memo';
const kNoteKindSchedule = 'schedule';
const kNoteKindArticle = 'article';
const kNoteKindAdmonition = 'admonition';

const kNoteFormatPlain = 'plain';
const kNoteFormatQuill = 'quill';

class Note {
  const Note({
    required this.id,
    required this.uuid,
    required this.kind,
    this.title = '',
    required this.body,
    this.format = kNoteFormatPlain,
    this.scheduleAt,
    this.remindAt,
    this.recurFreq = '',
    this.recurInterval = 1,
    this.recurByday,
    this.recurUntil,
    this.recurCount,
    this.remindOffsetMin = 0,
    this.listingStatus = kListingDraft,
    this.listedAt,
    this.city = '',
    this.coverUrl = '',
    this.parentUuid,
    this.sortOrder = 0,
    this.pinnedAt,
    this.completedAt,
    this.sourceNoteUuids = const [],
    required this.updatedAt,
  });

  final int id;
  final String uuid;
  final String kind;
  final String title;
  final String body;
  final String format;
  final DateTime? scheduleAt;
  final DateTime? remindAt;
  /// once/daily/weekly/monthly/yearly；空视为 once。
  final String recurFreq;
  final int recurInterval;
  /// 如 MO；仅 weekly。
  final String? recurByday;
  final DateTime? recurUntil;
  final int? recurCount;
  /// 日程：相对开始时间的提前分钟（≥0）。
  final int remindOffsetMin;
  final String listingStatus;
  final DateTime? listedAt;
  final String city;
  /// 文章封面公开 URL；空则阅读卡片用占位。
  final String coverUrl;
  final String? parentUuid;
  final int sortOrder;
  /// 备忘置顶时间；非空表示已置顶。
  final DateTime? pinnedAt;
  /// 备忘办结时间；非空表示已办结（禁用编辑）。
  final DateTime? completedAt;
  final List<String> sourceNoteUuids;
  final DateTime updatedAt;

  bool get isListed => listingStatus == kListingListed;
  bool get hasTitle => title.trim().isNotEmpty;
  bool get isPinned => pinnedAt != null;
  bool get isCompleted => completedAt != null;

  /// 列表展示用：有标题用标题；否则从正文纯文本抽首行（兼容 Quill JSON）。
  String get displayTitle => suggestNoteTitle(
        title: title,
        body: body,
        fallback: kindLabel,
        maxLen: 36,
      );

  String get kindLabel {
    switch (kind) {
      case kNoteKindMemo:
        return '备忘';
      case kNoteKindSchedule:
        return '日常';
      case kNoteKindArticle:
        return '文章';
      case kNoteKindAdmonition:
        return '谏言';
      default:
        return '笔记';
    }
  }
}

/// 阅读点开校验结果。
enum ArticleAvailability {
  ok,
  deleted,
  delisted,
}

extension ArticleAvailabilityMessage on ArticleAvailability {
  String get userMessage {
    switch (this) {
      case ArticleAvailability.ok:
        return '';
      case ArticleAvailability.deleted:
        return '文章已删除';
      case ArticleAvailability.delisted:
        return '该文章已下架';
    }
  }
}

/// 市集上架文章（Neon 只读）。
class MarketplaceArticle {
  const MarketplaceArticle({
    required this.noteUuid,
    required this.title,
    required this.body,
    required this.format,
    this.city = '',
    this.coverUrl = '',
    this.listedAt,
    this.ownerId = '',
    this.viewCount = 0,
    this.recommendCount = 0,
    this.commentCount = 0,
    this.deleted = false,
    this.delisted = false,
  });

  final String noteUuid;
  final String title;
  final String body;
  final String format;
  final String city;
  final String coverUrl;
  final DateTime? listedAt;
  final String ownerId;
  /// 他人访问次数（不含作者本人）。
  final int viewCount;
  final int recommendCount;
  final int commentCount;
  /// 收藏/近期里原文已被作者删除时为 true（列表仍可显示记录）。
  final bool deleted;
  /// 已改成非文章类型（对阅读侧视为下架）。
  final bool delisted;

  String get displayTitle =>
      title.trim().isNotEmpty ? title.trim() : '无标题文章';

  /// 简易热度：推荐权重最高，其次评论、浏览，再靠谱新鲜度。
  double get hotScore {
    final ageHours = listedAt == null
        ? 24 * 30.0
        : DateTime.now()
            .toUtc()
            .difference(listedAt!.toUtc())
            .inHours
            .clamp(0, 24 * 90)
            .toDouble();
    final recency = (24 * 14 - ageHours).clamp(0, 24 * 14) / (24 * 14);
    return recommendCount * 5.0 +
        commentCount * 3.0 +
        viewCount * 1.0 +
        recency * 10.0;
  }
}

/// 本机「近期阅读」记录。
class ArticleReadRecord {
  const ArticleReadRecord({
    required this.noteUuid,
    required this.title,
    required this.body,
    required this.format,
    this.city = '',
    this.coverUrl = '',
    this.ownerId = '',
    required this.lastReadAt,
  });

  final String noteUuid;
  final String title;
  final String body;
  final String format;
  final String city;
  final String coverUrl;
  final String ownerId;
  final DateTime lastReadAt;

  String get displayTitle =>
      title.trim().isNotEmpty ? title.trim() : '无标题文章';

  MarketplaceArticle toArticle() => MarketplaceArticle(
        noteUuid: noteUuid,
        title: title,
        body: body,
        format: format,
        city: city,
        coverUrl: coverUrl,
        ownerId: ownerId,
      );
}

class Room {
  const Room({
    required this.id,
    required this.propertyId,
    required this.label,
    this.videoUrl = '',
    this.videoPosterUrl = '',
    this.listingStatus = kListingDraft,
    this.listedAt,
  });

  final int id;
  final int propertyId;
  final String label;

  /// 房间视频公开地址（七牛或 R2）；空表示尚未上传。
  final String videoUrl;
  final String videoPosterUrl;
  final String listingStatus;
  final DateTime? listedAt;

  bool get hasVideo => videoUrl.trim().isNotEmpty;
  bool get isListed => listingStatus == kListingListed;
}

/// 游客广场上的只读房源（来自 Neon，不进本地房东库）。
class MarketplaceListing {
  const MarketplaceListing({
    required this.roomUuid,
    required this.propertyUuid,
    required this.propertyName,
    required this.city,
    required this.address,
    required this.roomLabel,
    this.videoUrl = '',
    this.videoPosterUrl = '',
    this.listedAt,
  });

  final String roomUuid;
  final String propertyUuid;
  final String propertyName;
  final String city;
  final String address;
  final String roomLabel;
  final String videoUrl;
  final String videoPosterUrl;
  final DateTime? listedAt;

  bool get hasVideo => videoUrl.trim().isNotEmpty;
}

class Tenant {
  const Tenant({
    required this.id,
    required this.name,
    required this.phone,
  });

  final int id;
  final String name;
  final String phone;
}

/// 租约每月附加费项（物业、网费、卫生费等，可多项）。
class LeaseExtraItem {
  const LeaseExtraItem({
    this.id,
    required this.name,
    required this.amount,
    this.sortOrder = 0,
  });

  final int? id;
  final String name;
  final double amount;
  final int sortOrder;
}

class Lease {
  const Lease({
    required this.id,
    required this.roomId,
    required this.tenantId,
    required this.startDate,
    this.endDate,
    required this.rentDueDay,
    required this.baseRent,
    required this.deposit,
    required this.status,
    this.electricPrice = 0,
    this.waterPrice = 0,
    this.gasPrice = 0,
    this.extras = const [],
    this.fixedExtra = 0,
    this.fixedExtraLabel = '固定杂费',
  });

  final int id;
  final int roomId;
  final int tenantId;
  final DateTime startDate;
  final DateTime? endDate;
  final int rentDueDay;
  final double baseRent;
  final double deposit;
  final String status;
  final double electricPrice;
  final double waterPrice;
  final double gasPrice;
  final List<LeaseExtraItem> extras;
  final double fixedExtra;
  final String fixedExtraLabel;

  bool get isActive => status == 'active';

  /// 兼容旧字段：优先 extras，否则回退 fixedExtra。
  List<LeaseExtraItem> get effectiveExtras {
    if (extras.isNotEmpty) return extras;
    if (fixedExtra > 0) {
      return [LeaseExtraItem(name: fixedExtraLabel, amount: fixedExtra)];
    }
    return const [];
  }

  double priceFor(String kind) {
    switch (kind) {
      case 'electric':
        return electricPrice;
      case 'water':
        return waterPrice;
      case 'gas':
        return gasPrice;
      default:
        return 0;
    }
  }
}

class RentPeriod {
  const RentPeriod({
    required this.id,
    required this.leaseId,
    required this.periodStart,
    required this.periodEnd,
    required this.dueDate,
    required this.amount,
    required this.status,
    this.remark = '',
  });

  final int id;
  final int leaseId;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime dueDate;
  final double amount;
  final String status;

  /// 本月房租备注（显示在应收/账期列表）。
  final String remark;

  bool get isPaid => status == 'paid';
  bool get isOpen => status == 'pending' || status == 'invoiced';
}

class DueItem {
  const DueItem({
    required this.period,
    required this.roomLabel,
    required this.propertyName,
    required this.tenantName,
    required this.tenantPhone,
  });

  final RentPeriod period;
  final String roomLabel;
  final String propertyName;
  final String tenantName;
  final String tenantPhone;
}

class RoomSnapshot {
  const RoomSnapshot({
    required this.room,
    this.lease,
    this.tenant,
  });

  final Room room;
  final Lease? lease;
  final Tenant? tenant;
}
