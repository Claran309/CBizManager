-- 付款 / 收款 / 开票跟踪（FR-IN-05 / FR-OUT-05 / FR-OUT-06 / FR-BACK-02 / FR-BACK-03）。
--
-- 设计取舍：
-- 1) 三类记录（付款 / 收款 / 开票）共用一张表，用 kind 判别列区分，而不是三张独立表。
--    理由与入库单 / 出库单共用 documents 表一致：字段高度重合（金额、日期、方式、备注、
--    单据快照），而「累计不得超过单据总额」「按月份汇总」「数据范围收敛」这些横向能力
--    只写一遍，避免三套实现逐渐漂移。
-- 2) 按明细建模，支持一张单据分多次付款 / 收款 / 开票。单据上的「已付 / 未付 / 已收 /
--    未收 / 已开票 / 开票状态」一律由服务端按金额合计推导，不落冗余状态列，
--    从根上杜绝「状态列与明细对不上」。
-- 3) 单据快照（单号 / 往来单位 / 业务员 / 业务日期）随记录一起落库：财务记录脱离单据
--    也能独立说明「当时依据了什么」，并且列表页不需要 join 单据表。
-- 4) 对私卡只保存卡号后 4 位（业务上只需要尾号，前端也不展示完整卡号），
--    避免完整卡号进入数据库、日志与审计摘要。

CREATE TABLE finance_records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    -- 关联单据；入库单只接受 payment / invoice，出库单只接受 receipt（服务层强校验）。
    document_id BIGINT UNSIGNED NOT NULL,
    document_kind ENUM('inbound', 'outbound') NOT NULL,
    -- 下列四列是记录生成时的单据快照。
    document_no VARCHAR(32) NOT NULL,
    party_name VARCHAR(191) NOT NULL,
    business_user_id BIGINT UNSIGNED NOT NULL,
    business_date DATE NOT NULL,
    -- 记录类型：付款（入库单）/ 收款（出库单）/ 开票（入库单）。
    kind ENUM('payment', 'receipt', 'invoice') NOT NULL,
    -- 本次付款 / 收款 / 开票金额，单位「分」；必须大于 0，且累计不得超过单据总额。
    amount DECIMAL(18, 2) NOT NULL,
    -- 实际发生日期（用户可手写，解析口径与单据业务日期一致）。
    occurred_on DATE NOT NULL,
    -- 付款 / 收款方式，仅 payment 与 receipt 携带；invoice 一律为 NULL。
    method ENUM('transfer', 'private_card', 'public_account') NULL,
    -- 转账方式的备注（微信 / 支付宝）。
    method_note VARCHAR(100) NULL,
    -- 对私卡卡号后 4 位，仅 private_card 携带。见文件头说明 (4)。
    card_tail CHAR(4) NULL,
    -- 发票号，仅 invoice 携带。
    invoice_no VARCHAR(64) NULL,
    remark VARCHAR(500) NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- 单据结清视图：按单据取全部记录并做累计。
    KEY idx_finance_records_group_document (group_id, document_id, kind, id),
    -- 后台「按月份看未付款 / 未收款 / 未开票」。
    KEY idx_finance_records_group_kind_occurred (group_id, kind, occurred_on, id),
    -- 业务员维度的财务流水查询。
    KEY idx_finance_records_business_user (group_id, business_user_id, occurred_on, id),
    KEY idx_finance_records_created_by (created_by),
    CONSTRAINT fk_finance_records_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_finance_records_document FOREIGN KEY (document_id) REFERENCES documents (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_finance_records_business_user FOREIGN KEY (business_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_finance_records_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
