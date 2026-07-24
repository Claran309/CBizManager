CREATE TABLE users (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    username VARCHAR(191) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(191) NOT NULL,
    account_type ENUM('platform_admin', 'group_owner', 'member') NOT NULL,
    platform_admin_guard TINYINT UNSIGNED GENERATED ALWAYS AS (
        CASE WHEN account_type = 'platform_admin' THEN 1 ELSE NULL END
    ) STORED,
    status ENUM('active', 'disabled') NOT NULL DEFAULT 'active',
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_users_username (username),
    UNIQUE KEY uk_users_platform_admin_guard (platform_admin_guard),
    KEY idx_users_account_type_status (account_type, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE `groups` (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name VARCHAR(191) NOT NULL,
    status ENUM('active', 'disabled') NOT NULL DEFAULT 'active',
    owner_user_id BIGINT UNSIGNED NOT NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_groups_name (name),
    UNIQUE KEY uk_groups_owner_user_id (owner_user_id),
    KEY idx_groups_status (status),
    CONSTRAINT fk_groups_owner_user FOREIGN KEY (owner_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_groups_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE memberships (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    member_type ENUM('owner', 'member') NOT NULL,
    status ENUM('active', 'disabled', 'removed') NOT NULL DEFAULT 'active',
    active_owner_group_id BIGINT UNSIGNED GENERATED ALWAYS AS (
        CASE WHEN member_type = 'owner' AND status = 'active' THEN group_id ELSE NULL END
    ) STORED,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_memberships_group_user (group_id, user_id),
    UNIQUE KEY uk_memberships_user (user_id),
    UNIQUE KEY uk_memberships_active_owner_group (active_owner_group_id),
    KEY idx_memberships_group_status (group_id, status),
    CONSTRAINT fk_memberships_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_memberships_user FOREIGN KEY (user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE invitations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NOT NULL,
    created_by BIGINT UNSIGNED NOT NULL,
    code_hash CHAR(64) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    used_at DATETIME(6) NULL,
    used_by BIGINT UNSIGNED NULL,
    status ENUM('active', 'used') NOT NULL DEFAULT 'active',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_invitations_code_hash (code_hash),
    KEY idx_invitations_group_status (group_id, status),
    KEY idx_invitations_expiry (expires_at),
    CONSTRAINT fk_invitations_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_invitations_created_by FOREIGN KEY (created_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_invitations_used_by FOREIGN KEY (used_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE refresh_sessions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id BIGINT UNSIGNED NOT NULL,
    group_id BIGINT UNSIGNED NULL,
    token_hash CHAR(64) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    replaced_by_session_id BIGINT UNSIGNED NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    last_used_at DATETIME(6) NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_refresh_sessions_token_hash (token_hash),
    KEY idx_refresh_sessions_user_state (user_id, revoked_at, expires_at),
    KEY idx_refresh_sessions_group_id (group_id),
    CONSTRAINT fk_refresh_sessions_user FOREIGN KEY (user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_refresh_sessions_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_refresh_sessions_replacement FOREIGN KEY (replaced_by_session_id) REFERENCES refresh_sessions (id) ON UPDATE RESTRICT ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE audit_logs (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id BIGINT UNSIGNED NULL,
    operator_user_id BIGINT UNSIGNED NOT NULL,
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(100) NOT NULL,
    resource_id VARCHAR(191) NOT NULL,
    summary VARCHAR(500) NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_audit_logs_group_created (group_id, created_at),
    KEY idx_audit_logs_operator_created (operator_user_id, created_at),
    KEY idx_audit_logs_action_created (action, created_at),
    CONSTRAINT fk_audit_logs_group FOREIGN KEY (group_id) REFERENCES `groups` (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_audit_logs_operator FOREIGN KEY (operator_user_id) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
