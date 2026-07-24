-- 成员状态和权限共享同一个乐观锁版本；复合唯一键供权限表的同组外键引用。
ALTER TABLE memberships
    ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1,
    ADD UNIQUE KEY uk_memberships_id_group (id, group_id);

CREATE TABLE membership_permissions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    membership_id BIGINT UNSIGNED NOT NULL,
    permission_code VARCHAR(100) NOT NULL,
    granted_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_membership_permissions_membership_code (membership_id, permission_code),
    KEY idx_membership_permissions_group_code (group_id, permission_code),
    KEY idx_membership_permissions_granted_by (granted_by),
    CONSTRAINT fk_membership_permissions_membership_group FOREIGN KEY (membership_id, group_id) REFERENCES memberships (id, group_id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT fk_membership_permissions_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_membership_permissions_granted_by FOREIGN KEY (granted_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE dictionary_entries (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    kind ENUM('supplier_company', 'customer', 'product_name', 'product_model', 'unit', 'shipping_unit') NOT NULL,
    name VARCHAR(191) NOT NULL,
    normalized_name VARCHAR(191) NOT NULL,
    parent_id BIGINT UNSIGNED NULL,
    parent_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(parent_id, 0)) STORED,
    contact_phone VARCHAR(50) NULL,
    status ENUM('active', 'disabled') NOT NULL DEFAULT 'active',
    version BIGINT UNSIGNED NOT NULL DEFAULT 1,
    created_by BIGINT UNSIGNED NOT NULL,
    updated_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_dictionary_scope_name (group_id, kind, parent_scope_id, normalized_name),
    KEY idx_dictionary_entries_group_status (group_id, status),
    KEY idx_dictionary_entries_group_query (group_id, kind, parent_scope_id, normalized_name, id),
    KEY idx_dictionary_entries_parent (parent_id),
    KEY idx_dictionary_entries_created_by (created_by),
    KEY idx_dictionary_entries_updated_by (updated_by),
    CONSTRAINT fk_dictionary_entries_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_dictionary_entries_parent FOREIGN KEY (parent_id) REFERENCES dictionary_entries (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_dictionary_entries_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_dictionary_entries_updated_by FOREIGN KEY (updated_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
