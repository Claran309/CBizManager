-- 回滚 000006：删除付款 / 收款 / 开票记录表。
--
-- 这张表只引用 documents / groups / users，没有其他表反向引用它，
-- 因此直接删除即可；单据表本身不受影响。
DROP TABLE IF EXISTS finance_records;
