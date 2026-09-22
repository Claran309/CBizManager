ALTER TABLE invitations
    DROP FOREIGN KEY fk_invitations_revoked_by,
    DROP KEY idx_invitations_revoked_by,
    DROP COLUMN revoked_by,
    DROP COLUMN revoked_at,
    DROP COLUMN code_nonce,
    DROP COLUMN code_ciphertext,
    DROP COLUMN version,
    MODIFY COLUMN status ENUM('active', 'used') NOT NULL DEFAULT 'active';

ALTER TABLE `groups` DROP COLUMN version;
