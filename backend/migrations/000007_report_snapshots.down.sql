-- 回滚 000007：删除月度总结算快照表。
--
-- 这张表只引用 groups / users，没有其他表反向引用它，
-- 因此直接删除即可；单据表与结算单表都不受影响。
DROP TABLE IF EXISTS report_snapshots;
