ALTER TABLE `groups`
    ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1;

ALTER TABLE invitations
    MODIFY COLUMN status ENUM('active', 'used', 'revoked') NOT NULL DEFAULT 'active',
    ADD COLUMN code_ciphertext VARBINARY(255) NULL AFTER code_hash,
    ADD COLUMN code_nonce VARBINARY(12) NULL AFTER code_ciphertext,
    ADD COLUMN revoked_at DATETIME(6) NULL AFTER used_by,
    ADD COLUMN revoked_by BIGINT UNSIGNED NULL AFTER revoked_at,
    ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER status,
    ADD KEY idx_invitations_revoked_by (revoked_by),
    ADD CONSTRAINT fk_invitations_revoked_by FOREIGN KEY (revoked_by) REFERENCES users (id) ON UPDATE RESTRICT ON DELETE SET NULL;
