enum DictionaryKind {
  supplierCompany('supplier_company'),
  customer('customer'),
  productName('product_name'),
  productModel('product_model'),
  unit('unit'),
  shippingUnit('shipping_unit');

  const DictionaryKind(this.wireValue);

  final String wireValue;

  static DictionaryKind fromWireValue(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => throw FormatException('Unknown dictionary kind: $value'),
  );
}

enum DictionaryStatus {
  active('active'),
  disabled('disabled');

  const DictionaryStatus(this.wireValue);

  final String wireValue;

  static DictionaryStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown dictionary status: $value'),
  );
}

final class DictionaryEntry {
  const DictionaryEntry({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.name,
    this.parentId,
    this.contactPhone,
    required this.status,
    required this.version,
  });

  final int id;
  final int groupId;
  final DictionaryKind kind;
  final String name;
  final int? parentId;
  final String? contactPhone;
  final DictionaryStatus status;
  final int version;

  factory DictionaryEntry.fromJson(Map<String, Object?> json) {
    return DictionaryEntry(
      id: json['id'] as int,
      groupId: json['group_id'] as int,
      kind: DictionaryKind.fromWireValue(json['kind'] as String),
      name: json['name'] as String,
      parentId: json['parent_id'] as int?,
      contactPhone: json['contact_phone'] as String?,
      status: DictionaryStatus.fromWireValue(json['status'] as String),
      version: json['version'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DictionaryEntry &&
      id == other.id &&
      groupId == other.groupId &&
      kind == other.kind &&
      name == other.name &&
      parentId == other.parentId &&
      contactPhone == other.contactPhone &&
      status == other.status &&
      version == other.version;

  @override
  int get hashCode => Object.hash(
    id,
    groupId,
    kind,
    name,
    parentId,
    contactPhone,
    status,
    version,
  );
}

final class DictionaryQuery {
  const DictionaryQuery({this.kind, this.parentId, this.status, this.keyword});

  final DictionaryKind? kind;
  final int? parentId;
  final DictionaryStatus? status;
  final String? keyword;
}

final class DictionaryDraft {
  const DictionaryDraft({
    required this.kind,
    required this.name,
    this.parentId,
    this.contactPhone,
  });

  final DictionaryKind kind;
  final String name;
  final int? parentId;
  final String? contactPhone;
}
