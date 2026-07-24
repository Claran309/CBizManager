-- 先删除依赖 memberships 的业务表，再移除被复合外键引用过的索引和版本列。
DROP TABLE IF EXISTS dictionary_entries;
DROP TABLE IF EXISTS membership_permissions;
ALTER TABLE memberships DROP INDEX uk_memberships_id_group;
ALTER TABLE memberships DROP COLUMN version;
