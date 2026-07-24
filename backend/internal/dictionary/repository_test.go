package dictionary

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type dictionaryAuditTest struct {
	ID             uint64 `gorm:"primaryKey"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (dictionaryAuditTest) TableName() string { return "audit_logs" }

func openDictionaryTestDB(t *testing.T, withAudit bool) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_foreign_keys=on", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("sql db: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	models := []any{&identity.User{}, &organization.Group{}, &Entry{}}
	if withAudit {
		models = append(models, &dictionaryAuditTest{})
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if err := db.Exec("CREATE UNIQUE INDEX uk_dictionary_test_scope_name ON dictionary_entries (group_id, kind, IFNULL(parent_id, 0), normalized_name)").Error; err != nil {
		t.Fatalf("create scope index: %v", err)
	}
	return db
}

type dictionaryFixture struct {
	owner identity.User
	group organization.Group
}

func seedDictionaryFixture(t *testing.T, db *gorm.DB) dictionaryFixture {
	t.Helper()
	fixture := dictionaryFixture{owner: identity.User{ID: 10, Username: "owner", PasswordHash: "hash", DisplayName: "Owner", AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive}}
	if err := db.Create(&fixture.owner).Error; err != nil {
		t.Fatalf("seed owner: %v", err)
	}
	fixture.group = organization.Group{ID: 7, Name: "Finance", Status: organization.GroupStatusActive, OwnerUserID: fixture.owner.ID, CreatedBy: fixture.owner.ID}
	if err := db.Create(&fixture.group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	return fixture
}

func TestRepositoryCreateMapsNormalizedScopeConflictAndAudits(t *testing.T) {
	db := openDictionaryTestDB(t, true)
	fixture := seedDictionaryFixture(t, db)
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 17, 0, 0, 0, time.UTC)
	draft := Draft{Kind: KindCustomer, Name: "Acme", NormalizedName: "acme"}
	created, err := repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, draft, now)
	if err != nil || created.ID == 0 || created.Version != 1 || created.Status != StatusActive {
		t.Fatalf("created=%+v error=%v", created, err)
	}
	_, err = repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindCustomer, Name: "ＡＣＭＥ", NormalizedName: "acme"}, now)
	if !errors.Is(err, ErrNameExists) {
		t.Fatalf("duplicate error=%v", err)
	}
	var audits int64
	_ = db.Model(&dictionaryAuditTest{}).Count(&audits).Error
	if audits != 1 {
		t.Fatalf("audit count=%d want=1", audits)
	}
}

func TestRepositoryRejectsInvalidProductModelParentInsideTransaction(t *testing.T) {
	db := openDictionaryTestDB(t, true)
	fixture := seedDictionaryFixture(t, db)
	repo := NewRepository(db)
	now := time.Now().UTC()
	missingParent := uint64(999)

	_, err := repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindProductModel, Name: "X1", NormalizedName: "x1", ParentID: &missingParent}, now)
	if !errors.Is(err, ErrParentInvalid) {
		t.Fatalf("missing parent error=%v", err)
	}
	parent, err := repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindProductName, Name: "Widget", NormalizedName: "widget"}, now)
	if err != nil {
		t.Fatalf("create product parent: %v", err)
	}
	if _, err := repo.ChangeStatus(context.Background(), fixture.group.ID, parent.ID, fixture.owner.ID, parent.Version, StatusDisabled, now.Add(time.Minute)); err != nil {
		t.Fatalf("disable parent: %v", err)
	}
	_, err = repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindProductModel, Name: "X2", NormalizedName: "x2", ParentID: &parent.ID}, now.Add(2*time.Minute))
	if !errors.Is(err, ErrParentInvalid) {
		t.Fatalf("disabled parent error=%v", err)
	}
}

func TestRepositoryListFiltersScopeAndUsesStableOrder(t *testing.T) {
	db := openDictionaryTestDB(t, true)
	fixture := seedDictionaryFixture(t, db)
	now := time.Now().UTC()
	entries := []Entry{
		{GroupID: fixture.group.ID, Kind: KindUnit, Name: "箱", NormalizedName: "箱", Status: StatusActive, Version: 1, CreatedBy: fixture.owner.ID, UpdatedBy: fixture.owner.ID, CreatedAt: now, UpdatedAt: now},
		{GroupID: fixture.group.ID, Kind: KindCustomer, Name: "Beta", NormalizedName: "beta", Status: StatusActive, Version: 1, CreatedBy: fixture.owner.ID, UpdatedBy: fixture.owner.ID, CreatedAt: now, UpdatedAt: now},
		{GroupID: fixture.group.ID, Kind: KindCustomer, Name: "Alpha", NormalizedName: "alpha", Status: StatusDisabled, Version: 1, CreatedBy: fixture.owner.ID, UpdatedBy: fixture.owner.ID, CreatedAt: now, UpdatedAt: now},
	}
	for index := range entries {
		if err := db.Create(&entries[index]).Error; err != nil {
			t.Fatalf("seed entry: %v", err)
		}
	}
	active := StatusActive
	page, err := NewRepository(db).List(context.Background(), fixture.group.ID, ListQuery{Status: &active, Page: 1, PageSize: 20})
	if err != nil || page.Total != 2 || len(page.Items) != 2 {
		t.Fatalf("page=%+v error=%v", page, err)
	}
	if page.Items[0].Kind != KindCustomer || page.Items[1].Kind != KindUnit {
		t.Fatalf("stable order=%+v", page.Items)
	}
	other, err := NewRepository(db).List(context.Background(), 8, ListQuery{Status: &active, Page: 1, PageSize: 20})
	if err != nil || other.Total != 0 {
		t.Fatalf("other=%+v error=%v", other, err)
	}
}

func TestRepositoryUpdateAndStatusUseOptimisticVersion(t *testing.T) {
	db := openDictionaryTestDB(t, true)
	fixture := seedDictionaryFixture(t, db)
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 17, 30, 0, 0, time.UTC)
	entry, err := repo.Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindUnit, Name: "箱", NormalizedName: "箱"}, now)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	updated, err := repo.Update(context.Background(), fixture.group.ID, entry.ID, fixture.owner.ID, 1, Draft{Kind: KindUnit, Name: "纸箱", NormalizedName: "纸箱"}, now.Add(time.Minute))
	if err != nil || updated.Version != 2 || updated.Name != "纸箱" {
		t.Fatalf("updated=%+v error=%v", updated, err)
	}
	_, err = repo.Update(context.Background(), fixture.group.ID, entry.ID, fixture.owner.ID, 1, Draft{Kind: KindUnit, Name: "旧写入", NormalizedName: "旧写入"}, now)
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("stale update error=%v", err)
	}
	disabled, err := repo.ChangeStatus(context.Background(), fixture.group.ID, entry.ID, fixture.owner.ID, 2, StatusDisabled, now.Add(2*time.Minute))
	if err != nil || disabled.Version != 3 || disabled.Status != StatusDisabled {
		t.Fatalf("disabled=%+v error=%v", disabled, err)
	}
}

func TestRepositoryRollsBackDictionaryWriteWhenAuditFails(t *testing.T) {
	db := openDictionaryTestDB(t, false)
	fixture := seedDictionaryFixture(t, db)
	_, err := NewRepository(db).Create(context.Background(), fixture.group.ID, fixture.owner.ID, Draft{Kind: KindUnit, Name: "箱", NormalizedName: "箱"}, time.Now().UTC())
	if err == nil {
		t.Fatal("Create() error=nil, want missing audit table")
	}
	var count int64
	_ = db.Model(&Entry{}).Count(&count).Error
	if count != 0 {
		t.Fatalf("rolled back entry count=%d", count)
	}
}
