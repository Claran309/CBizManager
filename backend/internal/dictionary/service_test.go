package dictionary

import (
	"context"
	"errors"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

type dictionaryRepositoryStub struct {
	entries   map[uint64]Entry
	page      Page
	created   Entry
	updated   Entry
	lastDraft Draft
	err       error
}

func (r *dictionaryRepositoryStub) List(context.Context, uint64, ListQuery) (Page, error) {
	return r.page, r.err
}
func (r *dictionaryRepositoryStub) Find(_ context.Context, groupID, id uint64) (Entry, error) {
	value, ok := r.entries[id]
	if !ok || value.GroupID != groupID {
		return Entry{}, ErrNotFound
	}
	return value, nil
}
func (r *dictionaryRepositoryStub) Create(_ context.Context, groupID, userID uint64, draft Draft, _ time.Time) (Entry, error) {
	r.lastDraft = draft
	if r.err != nil {
		return Entry{}, r.err
	}
	value := r.created
	value.GroupID = groupID
	value.CreatedBy = userID
	return value, nil
}
func (r *dictionaryRepositoryStub) Update(_ context.Context, _, _, _, _ uint64, draft Draft, _ time.Time) (Entry, error) {
	r.lastDraft = draft
	if r.err != nil {
		return Entry{}, r.err
	}
	return r.updated, nil
}
func (r *dictionaryRepositoryStub) ChangeStatus(context.Context, uint64, uint64, uint64, uint64, Status, time.Time) (Entry, error) {
	if r.err != nil {
		return Entry{}, r.err
	}
	return r.updated, nil
}

type dictionaryAuthorizerStub struct {
	err   error
	calls int
}

func (a *dictionaryAuthorizerStub) Require(context.Context, identity.Principal, uint64, authorization.Code) error {
	a.calls++
	return a.err
}

func dictionaryPrincipal(userID, groupID uint64) identity.Principal {
	return identity.Principal{UserID: userID, GroupID: &groupID, AccountType: identity.AccountTypeMember, MemberType: "member"}
}
func dictionaryErrorCode(t *testing.T, err error) string {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error=%v want app error", err)
	}
	return appErr.Code
}

func TestServiceListDefaultsOrdinaryMemberToActiveAndProtectsDisabledQuery(t *testing.T) {
	groupID := uint64(7)
	repo := &dictionaryRepositoryStub{page: Page{Page: 1, PageSize: 20}}
	service := NewService(repo, &dictionaryAuthorizerStub{err: apperror.ErrForbidden})
	page, err := service.List(context.Background(), dictionaryPrincipal(11, groupID), ListQuery{})
	if err != nil || page.Page != 1 {
		t.Fatalf("List()=%+v error=%v", page, err)
	}
	disabled := StatusDisabled
	_, err = service.List(context.Background(), dictionaryPrincipal(11, groupID), ListQuery{Status: &disabled})
	if got := dictionaryErrorCode(t, err); got != apperror.CodeForbidden {
		t.Fatalf("disabled query code=%s", got)
	}
}

func TestServiceCreateValidatesKindsParentAndContact(t *testing.T) {
	groupID := uint64(7)
	phone := "13800000000"
	parentID := uint64(41)
	product := Entry{ID: parentID, GroupID: groupID, Kind: KindProductName, Name: "Widget", NormalizedName: "widget", Status: StatusActive, Version: 1}
	tests := []struct {
		name     string
		request  CreateRequest
		entries  map[uint64]Entry
		wantCode string
	}{
		{"customer may have phone", CreateRequest{Kind: KindCustomer, Name: "  Ａcme  ", ContactPhone: &phone}, nil, ""},
		{"non customer rejects phone", CreateRequest{Kind: KindUnit, Name: "箱", ContactPhone: &phone}, nil, apperror.CodeValidationFailed},
		{"model requires parent", CreateRequest{Kind: KindProductModel, Name: "X1"}, nil, apperror.CodeDictionaryParentInvalid},
		{"model accepts active product parent", CreateRequest{Kind: KindProductModel, Name: "X1", ParentID: &parentID}, map[uint64]Entry{parentID: product}, ""},
		{"other kind rejects parent", CreateRequest{Kind: KindUnit, Name: "箱", ParentID: &parentID}, map[uint64]Entry{parentID: product}, apperror.CodeDictionaryParentInvalid},
		{"unknown kind rejected", CreateRequest{Kind: Kind("unknown"), Name: "value"}, nil, apperror.CodeValidationFailed},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			repo := &dictionaryRepositoryStub{entries: test.entries, created: Entry{ID: 1, Kind: test.request.Kind, Name: test.request.Name, Status: StatusActive, Version: 1}}
			result, err := NewService(repo, &dictionaryAuthorizerStub{}).Create(context.Background(), dictionaryPrincipal(11, groupID), test.request)
			if test.wantCode == "" {
				if err != nil || result.ID == 0 {
					t.Fatalf("Create()=%+v error=%v", result, err)
				}
				if test.request.Kind == KindCustomer && repo.lastDraft.NormalizedName != "acme" {
					t.Fatalf("normalized=%q", repo.lastDraft.NormalizedName)
				}
				return
			}
			if got := dictionaryErrorCode(t, err); got != test.wantCode {
				t.Fatalf("code=%s want=%s", got, test.wantCode)
			}
		})
	}
}

func TestServiceMapsDictionaryRepositoryErrors(t *testing.T) {
	groupID := uint64(7)
	request := CreateRequest{Kind: KindUnit, Name: "箱"}
	tests := []struct {
		err  error
		want string
	}{{ErrNameExists, apperror.CodeDictionaryNameExists}, {ErrVersionConflict, apperror.CodeResourceVersionConflict}, {ErrNotFound, apperror.CodeDictionaryNotFound}, {ErrParentInvalid, apperror.CodeDictionaryParentInvalid}}
	for _, test := range tests {
		repo := &dictionaryRepositoryStub{err: test.err}
		_, err := NewService(repo, &dictionaryAuthorizerStub{}).Create(context.Background(), dictionaryPrincipal(11, groupID), request)
		if got := dictionaryErrorCode(t, err); got != test.want {
			t.Fatalf("error=%v code=%s want=%s", test.err, got, test.want)
		}
	}
}
