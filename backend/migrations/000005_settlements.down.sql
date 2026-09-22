-- 回滚结算与审批模块：按依赖顺序逆序删除，先删子表再删主表。
DROP TABLE IF EXISTS approval_records;
DROP TABLE IF EXISTS settlement_sources;
DROP TABLE IF EXISTS settlements;
