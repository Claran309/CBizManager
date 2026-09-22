-- 一期业务单据（入库 / 出库）与幂等记录。
--
-- 设计取舍：入库单与出库单共享同一套「单据 + 往来单位分组 + 商品明细」三层结构，
-- 因此用 kind 判别列承载两种单据，而不是把 inbound_/outbound_ 两套表完全复制一遍。
-- 差异字段（出库的出货单位与销售金额类型）在入库场景保持 NULL，由服务层按 kind 校验。
-- 好处是结算单、汇总统计、幂等与审计等横向能力只写一份 SQL。

CREATE TABLE documents (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    kind ENUM('inbound', 'outbound') NOT NULL,
    document_no VARCHAR(32) NOT NULL,
    status ENUM('draft', 'submitted', 'voided') NOT NULL DEFAULT 'draft',
    business_user_id BIGINT UNSIGNED NOT NULL,
    business_date DATE NOT NULL,
    shipping_unit VARCHAR(191) NULL,
    sale_amount_type ENUM('Y-1', 'y-N', 'N') NULL,
    total_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    remark VARCHAR(500) NULL,
    version BIGINT UNSIGNED NOT NULL DEFAULT 1,
    submitted_at DATETIME(6) NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    updated_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_documents_group_no (group_id, document_no),
    -- 列表默认按「组 + 类型 + 状态 + 业务日期」倒序翻页，覆盖手机端历史与后台汇总。
    KEY idx_documents_group_kind_status_date (group_id, kind, status, business_date, id),
    -- 子账号「只看本人单据」的默认数据范围。
    KEY idx_documents_business_user (group_id, business_user_id, business_date, id),
    KEY idx_documents_created_by (created_by),
    KEY idx_documents_updated_by (updated_by),
    CONSTRAINT fk_documents_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_documents_business_user FOREIGN KEY (business_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_documents_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_documents_updated_by FOREIGN KEY (updated_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 往来单位分组：入库对应「进项公司」，出库对应「客户（含联系电话）」。
CREATE TABLE document_parties (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    document_id BIGINT UNSIGNED NOT NULL,
    position INT UNSIGNED NOT NULL,
    party_name VARCHAR(191) NOT NULL,
    contact_phone VARCHAR(50) NULL,
    -- 关联辅助字典，用于后续「辅助填写」统计与快照追溯；被删除时保留名称快照。
    dictionary_entry_id BIGINT UNSIGNED NULL,
    subtotal DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_document_parties_position (document_id, position),
    KEY idx_document_parties_group_name (group_id, party_name),
    KEY idx_document_parties_dictionary (dictionary_entry_id),
    CONSTRAINT fk_document_parties_document FOREIGN KEY (document_id) REFERENCES documents (id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_document_parties_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_document_parties_dictionary FOREIGN KEY (dictionary_entry_id) REFERENCES dictionary_entries (id) ON UPDATE RESTRICT ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 商品明细。金额一律落库保存（amount = 单价 × 数量，四舍五入到分），
-- 避免每次查询都要重算，也保证统计口径稳定。
CREATE TABLE document_items (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    document_id BIGINT UNSIGNED NOT NULL,
    party_id BIGINT UNSIGNED NOT NULL,
    position INT UNSIGNED NOT NULL,
    product_name VARCHAR(191) NOT NULL,
    product_model VARCHAR(191) NULL,
    unit VARCHAR(32) NULL,
    quantity DECIMAL(18, 3) NOT NULL DEFAULT 0.000,
    weight DECIMAL(18, 3) NULL,
    unit_price DECIMAL(18, 4) NOT NULL DEFAULT 0.0000,
    price_tax_mode ENUM('tax_included', 'tax_excluded') NOT NULL,
    amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    remark VARCHAR(500) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_document_items_position (party_id, position),
    KEY idx_document_items_document (document_id, id),
    KEY idx_document_items_group_product (group_id, product_name, product_model),
    CONSTRAINT fk_document_items_document FOREIGN KEY (document_id) REFERENCES documents (id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_document_items_party FOREIGN KEY (party_id) REFERENCES document_parties (id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_document_items_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 幂等记录：Android 离线队列会重复提交同一请求，服务端凭
-- 「组 + 用户 + 场景 + Idempotency-Key」识别重放，直接返回首次创建的资源。
-- request_fingerprint 用于识别「同一个 Key 携带了不同请求体」这一客户端缺陷。
CREATE TABLE idempotency_records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    scope VARCHAR(100) NOT NULL,
    idempotency_key VARCHAR(191) NOT NULL,
    request_fingerprint CHAR(64) NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    resource_id VARCHAR(191) NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_idempotency_records_scope_key (group_id, user_id, scope, idempotency_key),
    KEY idx_idempotency_records_created (created_at),
    CONSTRAINT fk_idempotency_records_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_idempotency_records_user FOREIGN KEY (user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
