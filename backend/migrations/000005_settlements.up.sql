-- 结算单与审批记录（FR-DOC-02 / FR-DOC-03 / FR-BACK-04）。
--
-- 设计取舍：
-- 1) 结算单只保存「金额快照」而不是每次重算。生成时把进项合计、销售合计、毛利润
--    写入结算单本体，源单据后续被修改或作废都不会改变已生成的结算单数值，
--    对应开发计划「修改源单不会改变已审批结算单快照」这条完成标准。
-- 2) settlement_sources 永久保留结算单与源单据的关联关系（含单号与金额快照），
--    满足「结算单可以追溯到所有源单」。
-- 3) 「同一源单据不允许被两张有效结算单同时引用」用唯一索引兜底，而不是只靠应用层校验：
--    active_document_id 是 document_id 的活跃副本，源单据被占用时写入 document_id、
--    结算单被驳回释放后置为 NULL。MySQL 与 SQLite 的唯一索引都允许多个 NULL，
--    因此同一源单据可以出现在多张历史驳回单里，但同一时刻只能被一张有效结算单引用。
-- 4) 审批是单级流程，驳回即终态；业务员修改源单据后重新申请会生成新的结算单。
--    审批动作逐条追加到 approval_records，历史记录永不删除、永不覆盖。

CREATE TABLE settlements (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    settlement_no VARCHAR(32) NOT NULL,
    status ENUM('pending', 'approved', 'rejected') NOT NULL DEFAULT 'pending',
    -- 申请人（业务员）；子账号默认只能看到自己申请的结算单。
    requester_user_id BIGINT UNSIGNED NOT NULL,
    remark VARCHAR(500) NULL,
    -- 生成时快照的三项金额，单位「分」。毛利润 = 销售合计 − 进项合计，允许为负。
    inbound_total DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    outbound_total DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    gross_profit DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    source_count INT UNSIGNED NOT NULL DEFAULT 0,
    version BIGINT UNSIGNED NOT NULL DEFAULT 1,
    decided_at DATETIME(6) NULL,
    decided_by BIGINT UNSIGNED NULL,
    decision_remark VARCHAR(500) NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    updated_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    -- 结算单号形如 JS202609-0003：类型前缀 + 年月 + 当月 4 位序号。
    UNIQUE KEY uk_settlements_group_no (group_id, settlement_no),
    -- 后台审批列表默认按「组 + 状态 + 生成时间」倒序翻页。
    KEY idx_settlements_group_status_created (group_id, status, created_at, id),
    -- 子账号「只看本人结算单」的默认数据范围。
    KEY idx_settlements_requester (group_id, requester_user_id, created_at, id),
    KEY idx_settlements_created_by (created_by),
    KEY idx_settlements_decided_by (decided_by),
    CONSTRAINT fk_settlements_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_settlements_requester FOREIGN KEY (requester_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_settlements_decided_by FOREIGN KEY (decided_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_settlements_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_settlements_updated_by FOREIGN KEY (updated_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 结算单与源单据的关联。单号、业务员、业务日期与金额都在这里留快照，
-- 这样即使源单据后来被改单或作废，结算单详情仍然能独立讲清楚「当时依据了什么」。
CREATE TABLE settlement_sources (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    settlement_id BIGINT UNSIGNED NOT NULL,
    document_id BIGINT UNSIGNED NOT NULL,
    kind ENUM('inbound', 'outbound') NOT NULL,
    document_no VARCHAR(32) NOT NULL,
    business_user_id BIGINT UNSIGNED NOT NULL,
    business_date DATE NOT NULL,
    amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    -- 活跃引用副本：被有效结算单占用时等于 document_id，释放后置 NULL。见文件头说明 (3)。
    active_document_id BIGINT UNSIGNED NULL,
    released_at DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_settlement_sources_active_document (group_id, active_document_id),
    KEY idx_settlement_sources_settlement (settlement_id, id),
    KEY idx_settlement_sources_document (group_id, document_id),
    KEY idx_settlement_sources_kind (group_id, kind, business_date),
    CONSTRAINT fk_settlement_sources_settlement FOREIGN KEY (settlement_id) REFERENCES settlements (id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_settlement_sources_document FOREIGN KEY (document_id) REFERENCES documents (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_settlement_sources_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 审批记录：申请、通过、驳回都追加一条，只增不改，作为审批链路的事实来源。
CREATE TABLE approval_records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    settlement_id BIGINT UNSIGNED NOT NULL,
    action ENUM('submitted', 'approved', 'rejected') NOT NULL,
    operator_user_id BIGINT UNSIGNED NOT NULL,
    remark VARCHAR(500) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_approval_records_settlement (settlement_id, id),
    KEY idx_approval_records_group_created (group_id, created_at),
    CONSTRAINT fk_approval_records_settlement FOREIGN KEY (settlement_id) REFERENCES settlements (id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_approval_records_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_approval_records_operator FOREIGN KEY (operator_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
