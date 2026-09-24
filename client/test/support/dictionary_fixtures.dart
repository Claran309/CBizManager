import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';

/// 字典模块的测试夹具。
///
/// 分两类：
/// - 下面几个 **const 实体**是「固定场景」的常用默认值，直接当常量用；
/// - [buildDictionaryEntry] 是「需要微调某几个字段」时的构造器，它走真实的
///   [DictionaryEntry.fromJson]，所以夹具与 `DictionaryEntryData` 契约始终同构 ——
///   契约一旦调整，全部用例会一起失败，而不是悄悄用着一份过期的手搓结构。
///
/// 默认 groupId 统一取 10：字典按组隔离，需要验证跨组隔离时显式传 groupId 即可。

/// 一个客户条目：组内 id 5、启用中、版本 1。
const controllerDictionaryEntry = DictionaryEntry(
  id: 5,
  groupId: 10,
  kind: DictionaryKind.customer,
  name: 'Customer A',
  status: DictionaryStatus.active,
  version: 1,
);

/// 与 [controllerDictionaryEntry] 同一条，只是已停用、版本 +1。
const disabledDictionaryEntry = DictionaryEntry(
  id: 5,
  groupId: 10,
  kind: DictionaryKind.customer,
  name: 'Customer A',
  status: DictionaryStatus.disabled,
  version: 2,
);

/// 一个品名条目（id 6）：用来验证「乱序响应」与「型号的父级候选」。
const newerDictionaryEntry = DictionaryEntry(
  id: 6,
  groupId: 10,
  kind: DictionaryKind.productName,
  name: 'Product A',
  status: DictionaryStatus.active,
  version: 1,
);

/// 一个型号条目：父级是 [newerDictionaryEntry]（品名 id 6）。
const productModelDictionaryEntry = DictionaryEntry(
  id: 7,
  groupId: 10,
  kind: DictionaryKind.productModel,
  name: 'HRB400 Φ20',
  parentId: 6,
  status: DictionaryStatus.active,
  version: 1,
);

/// 不可作为父级的品名：已停用。
///
/// 「型号必须挂在**启用中**的品名下」是后端硬约束，所以父级候选里不该出现它。
const disabledProductNameDictionaryEntry = DictionaryEntry(
  id: 8,
  groupId: 10,
  kind: DictionaryKind.productName,
  name: 'Retired Product',
  status: DictionaryStatus.disabled,
  version: 3,
);

/// 按字段构造一个字典条目夹具（走真实 [DictionaryEntry.fromJson]）。
///
/// 默认值就是 [controllerDictionaryEntry]，用例只需要写出「与默认不同的那几项」。
DictionaryEntry buildDictionaryEntry({
  int id = 5,
  int groupId = 10,
  DictionaryKind kind = DictionaryKind.customer,
  String name = 'Customer A',
  int? parentId,
  String? contactPhone,
  DictionaryStatus status = DictionaryStatus.active,
  int version = 1,
}) => DictionaryEntry.fromJson(<String, Object?>{
  'id': id,
  'group_id': groupId,
  'kind': kind.wireValue,
  'name': name,
  'parent_id': parentId,
  'contact_phone': contactPhone,
  'status': status.wireValue,
  'version': version,
});
