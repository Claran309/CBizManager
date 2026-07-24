package dictionary

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type gormRepository struct{ db *gorm.DB }

func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

func (r *gormRepository) List(ctx context.Context, groupID uint64, query ListQuery) (Page, error) {
	base := r.db.WithContext(ctx).Model(&Entry{}).Where("group_id = ?", groupID)
	if query.Kind != nil {
		base = base.Where("kind = ?", *query.Kind)
	}
	if query.ParentID != nil {
		base = base.Where("parent_id = ?", *query.ParentID)
	}
	if query.Status != nil {
		base = base.Where("status = ?", *query.Status)
	}
	if query.Keyword != "" {
		base = base.Where("normalized_name LIKE ?", "%"+query.Keyword+"%")
	}
	var total int64
	if err := base.Count(&total).Error; err != nil {
		return Page{}, fmt.Errorf("count dictionary entries: %w", err)
	}
	var entries []Entry
	offset := (query.Page - 1) * query.PageSize
	if err := base.Order("kind ASC").Order("COALESCE(parent_id, 0) ASC").Order("normalized_name ASC").Order("id ASC").Offset(offset).Limit(query.PageSize).Find(&entries).Error; err != nil {
		return Page{}, fmt.Errorf("list dictionary entries: %w", err)
	}
	return Page{Items: entries, Page: query.Page, PageSize: query.PageSize, Total: total}, nil
}

func (r *gormRepository) Find(ctx context.Context, groupID, id uint64) (Entry, error) {
	return findEntry(r.db.WithContext(ctx), groupID, id)
}

func (r *gormRepository) Create(ctx context.Context, groupID, userID uint64, draft Draft, now time.Time) (Entry, error) {
	entry := Entry{GroupID: groupID, Kind: draft.Kind, Name: draft.Name, NormalizedName: draft.NormalizedName, ParentID: draft.ParentID,
		ContactPhone: draft.ContactPhone, Status: StatusActive, Version: 1, CreatedBy: userID, UpdatedBy: userID, CreatedAt: now, UpdatedAt: now}
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := validateParentInTransaction(tx.WithContext(ctx), groupID, draft); err != nil {
			return err
		}
		if err := tx.Create(&entry).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrNameExists
			}
			return fmt.Errorf("insert dictionary entry: %w", err)
		}
		return appendDictionaryAudit(tx, groupID, userID, "dictionary.created", entry.ID, "辅助字典已创建", now)
	})
	if err != nil {
		return Entry{}, err
	}
	return entry, nil
}

func (r *gormRepository) Update(ctx context.Context, groupID, id, userID, version uint64, draft Draft, now time.Time) (Entry, error) {
	var result Entry
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		current, err := findEntry(tx.Clauses(clause.Locking{Strength: "UPDATE"}), groupID, id)
		if err != nil {
			return err
		}
		if current.Version != version {
			return ErrVersionConflict
		}
		if err := validateParentInTransaction(tx, groupID, draft); err != nil {
			return err
		}
		update := tx.Model(&Entry{}).Where("id = ? AND group_id = ? AND version = ?", id, groupID, version).Updates(map[string]any{
			"name": draft.Name, "normalized_name": draft.NormalizedName, "parent_id": draft.ParentID, "contact_phone": draft.ContactPhone,
			"updated_by": userID, "updated_at": now, "version": gorm.Expr("version + 1"),
		})
		if errors.Is(update.Error, gorm.ErrDuplicatedKey) {
			return ErrNameExists
		}
		if update.Error != nil {
			return fmt.Errorf("update dictionary entry: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}
		if err := appendDictionaryAudit(tx, groupID, userID, "dictionary.updated", id, "辅助字典已更新", now); err != nil {
			return err
		}
		current.Name, current.NormalizedName, current.ParentID, current.ContactPhone = draft.Name, draft.NormalizedName, draft.ParentID, draft.ContactPhone
		current.UpdatedBy, current.UpdatedAt, current.Version = userID, now, version+1
		result = current
		return nil
	})
	if err != nil {
		return Entry{}, err
	}
	return result, nil
}

func (r *gormRepository) ChangeStatus(ctx context.Context, groupID, id, userID, version uint64, status Status, now time.Time) (Entry, error) {
	var result Entry
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		current, err := findEntry(tx.Clauses(clause.Locking{Strength: "UPDATE"}), groupID, id)
		if err != nil {
			return err
		}
		if current.Version != version {
			return ErrVersionConflict
		}
		update := tx.Model(&Entry{}).Where("id = ? AND group_id = ? AND version = ?", id, groupID, version).Updates(map[string]any{
			"status": status, "updated_by": userID, "updated_at": now, "version": gorm.Expr("version + 1"),
		})
		if update.Error != nil {
			return fmt.Errorf("update dictionary status: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}
		if err := appendDictionaryAudit(tx, groupID, userID, "dictionary.status.changed", id, "辅助字典状态已变更", now); err != nil {
			return err
		}
		current.Status, current.UpdatedBy, current.UpdatedAt, current.Version = status, userID, now, version+1
		result = current
		return nil
	})
	if err != nil {
		return Entry{}, err
	}
	return result, nil
}

func findEntry(db *gorm.DB, groupID, id uint64) (Entry, error) {
	var entry Entry
	err := db.Where("id = ? AND group_id = ?", id, groupID).Take(&entry).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Entry{}, ErrNotFound
	}
	if err != nil {
		return Entry{}, fmt.Errorf("find dictionary entry: %w", err)
	}
	return entry, nil
}

func validateParentInTransaction(tx *gorm.DB, groupID uint64, draft Draft) error {
	if draft.Kind != KindProductModel {
		if draft.ParentID != nil {
			return ErrParentInvalid
		}
		return nil
	}
	if draft.ParentID == nil {
		return ErrParentInvalid
	}
	parent, err := findEntry(tx.Clauses(clause.Locking{Strength: "UPDATE"}), groupID, *draft.ParentID)
	if errors.Is(err, ErrNotFound) {
		return ErrParentInvalid
	}
	if err != nil {
		return err
	}
	if parent.Kind != KindProductName || parent.Status != StatusActive {
		return ErrParentInvalid
	}
	return nil
}

func appendDictionaryAudit(db *gorm.DB, groupID, userID uint64, action string, id uint64, summary string, now time.Time) error {
	err := db.Table("audit_logs").Create(map[string]any{"group_id": groupID, "operator_user_id": userID, "action": action,
		"resource_type": "dictionary_entry", "resource_id": strconv.FormatUint(id, 10), "summary": summary, "created_at": now}).Error
	if err != nil {
		return fmt.Errorf("append dictionary audit: %w", err)
	}
	return nil
}
