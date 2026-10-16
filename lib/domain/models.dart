class Property {
  const Property({
    required this.id,
    required this.name,
    required this.address,
  });

  final int id;
  final String name;
  final String address;
}

class Room {
  const Room({
    required this.id,
    required this.propertyId,
    required this.label,
  });

  final int id;
  final int propertyId;
  final String label;
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
  });

  final int id;
  final int leaseId;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime dueDate;
  final double amount;
  final String status;

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
