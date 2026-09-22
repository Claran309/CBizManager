-- 月度总结算快照（FR-BACK-05）。
--
-- 设计取舍：
-- 1) 与 settlements（业务员逐单申请、后台单级审批）刻意分开成两张表。
--    结算单是「按源单据申请 + 审批」的业务流程，参与结算的源单据会被占用（active_document_id
--    唯一键），审批驳回才释放；总结算是「按周期自动聚合」的只读报表快照，没有审批流，
--    也不占用任何源单据——同一张单据完全可以既出现在结算单里，又出现在当月的总结算里。
--    把两者塞进一张表会让「占用 / 释放」这套规则凭空长到报表头上。
-- 2) 快照即冻结：生成时把入库合计、出库合计、毛利润、毛利率与三类销售金额一次性写入，
--    之后源单据再被修改或作废都不会改变已生成的数值（与结算单的三项金额快照同一口径）。
--    因此这张表没有 version 列，也不提供修改接口；要更正只能重新生成一张，两张都留着便于追溯。
-- 3) 毛利率用「百万分之一」的整数列保存，不用浮点：20.75% 存 207500，
--    避免出现 20.749999999999996 这种由 IEEE-754 带来的展示瑕疵。
-- 4) 业务员姓名随快照落库（而不是只存 user_id）：用户改名或注销后，
--    历史报表仍然要能说明「当时这一行是谁的」。

CREATE TABLE report_snapshots (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    -- 单号：ZJS + YYYYMM + -4 位当月序号（如 ZJS202609-0003），唯一键与结算单同构。
    snapshot_no VARCHAR(32) NOT NULL,
    -- 批次号：一次生成动作的多行共享同一个批次号（业务员维度会一次生成多行）。
    batch_no VARCHAR(32) NOT NULL,
    -- 统计维度：公司维度（整组合计）/ 业务员维度（单个业务员合计）。
    scope ENUM('company', 'business_user') NOT NULL,
    -- 统计周期，左闭右开（当月 1 日 ~ 次月 1 日）。
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    -- 仅在 scope = business_user 时有值。
    business_user_id BIGINT UNSIGNED NULL,
    business_user_name VARCHAR(191) NULL,
    -- 三项核心金额快照，单位「分」。
    inbound_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    outbound_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    gross_profit DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    -- 毛利率，单位「百万分之一」（207500 = 20.75%）。见文件头说明 (3)。
    gross_margin_ppm BIGINT NOT NULL DEFAULT 0,
    -- 三类销售金额分项（FR-BACK-03：Y-1 / y-N / N）。
    vat_special_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    vat_general_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    no_invoice_amount DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    -- 参与统计的单据数（只含已提交单据，见服务层口径说明）。
    document_count BIGINT NOT NULL DEFAULT 0,
    remark VARCHAR(500) NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_report_snapshots_no (group_id, snapshot_no),
    -- 后台「按月份看总结算」。
    KEY idx_report_snapshots_period (group_id, period_start, scope, id),
    -- 按批次查看一次生成动作的全部结果。
    KEY idx_report_snapshots_batch (group_id, batch_no, id),
    -- 业务员维度的历史总结算。
    KEY idx_report_snapshots_business_user (group_id, business_user_id, period_start, id),
    KEY idx_report_snapshots_created_by (created_by),
    CONSTRAINT fk_report_snapshots_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_report_snapshots_business_user FOREIGN KEY (business_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_report_snapshots_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
