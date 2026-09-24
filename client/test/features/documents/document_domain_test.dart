import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:flutter_test/flutter_test.dart';

/// 单据领域模型的契约测试。
///
/// 逐条对齐后端 `internal/document/{model,dto}.go` 的 wire 字段与枚举取值，
/// 以及「列表行 business_user 只回填 id+display_name」的陷阱。
void main() {
  group('枚举 wire 值', () {
    test('DocumentKind', () {
      expect(DocumentKind.inbound.wireValue, 'inbound');
      expect(DocumentKind.outbound.wireValue, 'outbound');
      expect(DocumentKind.fromWireValue('inbound'), DocumentKind.inbound);
      expect(DocumentKind.fromWireValue('outbound'), DocumentKind.outbound);
      expect(() => DocumentKind.fromWireValue('xx'), throwsFormatException);
      expect(DocumentKind.inbound.numberPrefix, 'RK');
      expect(DocumentKind.outbound.numberPrefix, 'CK');
      expect(DocumentKind.inbound.isInbound, isTrue);
      expect(DocumentKind.outbound.isInbound, isFalse);
    });

    test('DocumentStatus 状态机', () {
      expect(DocumentStatus.draft.wireValue, 'draft');
      expect(DocumentStatus.submitted.wireValue, 'submitted');
      expect(DocumentStatus.voided.wireValue, 'voided');
      expect(DocumentStatus.voided.isTerminal, isTrue);
      expect(DocumentStatus.submitted.isTerminal, isFalse);
      expect(
        () => DocumentStatus.fromWireValue('approved'),
        throwsFormatException,
      );
    });

    test('PriceTaxMode', () {
      expect(PriceTaxMode.taxIncluded.wireValue, 'tax_included');
      expect(PriceTaxMode.taxExcluded.wireValue, 'tax_excluded');
      expect(() => PriceTaxMode.fromWireValue('x'), throwsFormatException);
    });

    test('SaleAmountType', () {
      expect(SaleAmountType.vatSpecial.wireValue, 'Y-1');
      expect(SaleAmountType.vatGeneral.wireValue, 'y-N');
      expect(SaleAmountType.noInvoice.wireValue, 'N');
      expect(() => SaleAmountType.fromWireValue('Z'), throwsFormatException);
    });
  });

  group('DocumentSummary（列表行）', () {
    test('解析列表行，business_user 只回填 id+display_name', () {
      final summary = DocumentSummary.fromJson(<String, Object?>{
        'document_id': 42,
        'kind': 'inbound',
        'document_no': 'RK20260922-0001',
        'status': 'submitted',
        'business_date': '2026-09-22',
        // 后端 toSummaryData 只填 ID + DisplayName，username/account_type 是零值空串。
        'business_user': <String, Object?>{
          'id': 7,
          'username': '',
          'display_name': '张三',
          'account_type': '',
        },
        'shipping_unit': null,
        'sale_amount_type': null,
        'party_names': <String>['华东钢贸', '华北钢贸'],
        'item_count': 5,
        'total_amount': '146982.33',
        'version': 3,
        'submitted_at': null,
        'created_at': '2026-09-22T10:00:00Z',
        'updated_at': '2026-09-22T10:00:00Z',
      });

      expect(summary.documentId, 42);
      expect(summary.kind, DocumentKind.inbound);
      expect(summary.documentNo, 'RK20260922-0001');
      expect(summary.status, DocumentStatus.submitted);
      expect(summary.businessDate, DateTime.utc(2026, 9, 22));
      expect(summary.businessUser.id, 7);
      expect(summary.businessUser.displayName, '张三');
      // 列表行的 username/account_type 是空串，不能强校验非空。
      expect(summary.businessUser.username, '');
      expect(summary.partyNames, <String>['华东钢贸', '华北钢贸']);
      expect(summary.itemCount, 5);
      expect(summary.totalAmount.format(), '146982.33');
      expect(summary.version, 3);
    });

    test('金额字段必须是字符串，数字则拒绝', () {
      final base = _summaryJson()..['total_amount'] = 146982.33;
      expect(() => DocumentSummary.fromJson(base), throwsFormatException);
    });

    test('非法枚举抛 FormatException', () {
      final base = _summaryJson()..['status'] = 'approved';
      expect(() => DocumentSummary.fromJson(base), throwsFormatException);
    });
  });

  group('DocumentDetail（详情）', () {
    test('解析详情：parties 分组 + items 明细 + 金额与大写', () {
      final detail = DocumentDetail.fromJson(<String, Object?>{
        'document_id': 42,
        'kind': 'outbound',
        'document_no': 'CK20260922-0002',
        'status': 'submitted',
        'business_user': <String, Object?>{
          'id': 7,
          'username': 'zhangsan',
          'display_name': '张三',
          'account_type': 'member',
        },
        'business_date': '2026-09-22',
        'shipping_unit': '吨',
        'sale_amount_type': 'Y-1',
        'total_amount': '50731.08',
        'total_amount_upper': '人民币伍万零柒佰叁拾壹元零捌分',
        'remark': null,
        'version': 3,
        'submitted_at': '2026-09-22T10:00:00Z',
        'created_at': '2026-09-22T09:00:00Z',
        'updated_at': '2026-09-22T10:00:00Z',
        'parties': <Object?>[
          <String, Object?>{
            'party_id': 1,
            'position': 1,
            'party_name': '华东钢贸',
            'contact_phone': '13800000000',
            'subtotal': '50731.08',
            'items': <Object?>[
              <String, Object?>{
                'item_id': 101,
                'position': 1,
                'product_name': '螺纹钢',
                'product_model': 'HRB400',
                'unit': '吨',
                'quantity': '17.050',
                'weight': null,
                'unit_price': '2975.4300',
                'price_tax_mode': 'tax_included',
                'amount': '50731.08',
                'remark': null,
              },
            ],
          },
        ],
      });

      expect(detail.documentId, 42);
      expect(detail.kind, DocumentKind.outbound);
      expect(detail.shippingUnit, '吨');
      expect(detail.saleAmountType, SaleAmountType.vatSpecial);
      expect(detail.totalAmountUpper, '人民币伍万零柒佰叁拾壹元零捌分');
      // 详情里的 business_user 是完整 UserSummary。
      expect(detail.businessUser.username, 'zhangsan');

      final party = detail.parties.single;
      expect(party.partyName, '华东钢贸');
      expect(party.contactPhone, '13800000000');
      expect(party.subtotal.format(), '50731.08');

      final item = party.items.single;
      expect(item.productName, '螺纹钢');
      expect(item.productModel, 'HRB400');
      expect(item.quantity.format(), '17.050');
      expect(item.unitPrice.format(), '2975.4300');
      expect(item.priceTaxMode, PriceTaxMode.taxIncluded);
      expect(item.amount.format(), '50731.08');
    });

    test('详情 business_user 缺 id 抛错（完整摘要必须带 id）', () {
      final json = _detailJson();
      (json['business_user'] as Map<String, Object?>)['id'] = 0;
      expect(() => DocumentDetail.fromJson(json), throwsFormatException);
    });
  });
}

Map<String, Object?> _summaryJson() => <String, Object?>{
  'document_id': 1,
  'kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'status': 'draft',
  'business_date': '2026-09-22',
  'business_user': <String, Object?>{
    'id': 7,
    'username': '',
    'display_name': '张三',
    'account_type': '',
  },
  'shipping_unit': null,
  'sale_amount_type': null,
  'party_names': <String>[],
  'item_count': 0,
  'total_amount': '0.00',
  'version': 1,
  'submitted_at': null,
  'created_at': '2026-09-22T10:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _detailJson() => <String, Object?>{
  'document_id': 1,
  'kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'status': 'draft',
  'business_user': <String, Object?>{
    'id': 7,
    'username': 'zhangsan',
    'display_name': '张三',
    'account_type': 'member',
  },
  'business_date': '2026-09-22',
  'shipping_unit': null,
  'sale_amount_type': null,
  'total_amount': '0.00',
  'total_amount_upper': '人民币零元整',
  'remark': null,
  'version': 1,
  'submitted_at': null,
  'created_at': '2026-09-22T10:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
  'parties': <Object?>[],
};
