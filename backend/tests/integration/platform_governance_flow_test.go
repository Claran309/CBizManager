//go:build integration

package integration

import (
	"bytes"
	"context"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/infrastructure/cryptography"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/platform"
	"CBizDocsManager/backend/pkg/apperror"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
)

// integrationSession 把「已登录身份」和「它当前持有的访问令牌」绑在一起。
// Principal 本身不含令牌，而停用组之后我们要验证同一枚令牌会立刻失效，
// 所以必须把原始令牌显式带在测试里。
type integrationSession struct {
	principal   *identity.Principal
	accessToken string
}

// TestPlatformGovernanceAndInvitationLifecycle 覆盖平台治理与邀请码闭环：
//
//	建组 → 组列表/详情 → 组主账号改密 → 签发邀请码 → 列表 → 查看明文 → 撤销 → 再次查看被拒
//	→ 邀请码注册成员 → 主账号交接给组内成员 → 停用组（连带撤销会话）→ 启用组 → 组名冲突。
//
// 这里刻意走真实 MySQL，因为乐观锁、行锁、多表事务与生成列只有在真实方言下才有意义。
func TestPlatformGovernanceAndInvitationLifecycle(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()

	identityRepo := identity.NewRepository(db)
	organizationRepo := organization.NewRepository(db)
	platformRepo := platform.NewRepository(db)
	passwords := identity.NewPasswordManager()
	tokens, err := jwtmanager.NewManager("integration-secret-at-least-32-bytes", "integration", 15*time.Minute)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	// 邀请码密钥固定为 32 字节，保证同一测试内签发与解密使用同一把钥匙。
	invitationCipher, err := cryptography.NewInvitationCipher(bytes.Repeat([]byte{0x2a}, 32))
	if err != nil {
		t.Fatalf("NewInvitationCipher() error = %v", err)
	}
	identityService := identity.NewService(identityRepo, passwords, tokens, 15*time.Minute, 7*24*time.Hour)
	platformService := platform.NewService(platformRepo, passwords)
	organizationService := organization.NewService(organizationRepo, passwords, invitationCipher)

	if created, err := identityService.BootstrapPlatformAdmin(ctx, "admin", "temporary-admin-password"); err != nil || !created {
		t.Fatalf("BootstrapPlatformAdmin()=(%v,%v)", created, err)
	}
	adminSession := loginAs(t, identityService, "admin", "temporary-admin-password")
	// 平台管理员的初始密码必须先改掉，否则治理接口会被前置校验拦住。
	changePassword(t, identityService, adminSession, "temporary-admin-password", "platform-admin-password")
	adminSession = loginAs(t, identityService, "admin", "platform-admin-password")

	// 1. 创建组与主账号。
	groupName := "钢铁贸易一组"
	created, err := platformService.CreateGroup(ctx, *adminSession.principal, platform.CreateGroupRequest{
		Name: groupName, OwnerUsername: "group-owner-one",
		OwnerDisplayName: "一组主账号", OwnerTemporaryPassword: "owner-temporary-password",
	})
	if err != nil {
		t.Fatalf("CreateGroup() error = %v", err)
	}
	groupID := created.Group.ID

	// 2. 组列表支持关键字过滤，且总数与条目一致。
	page, err := platformService.ListGroups(ctx, *adminSession.principal, platform.GroupQuery{Keyword: "钢铁"})
	if err != nil {
		t.Fatalf("ListGroups() error = %v", err)
	}
	if page.Total != 1 || len(page.Items) != 1 || page.Items[0].ID != groupID {
		t.Fatalf("ListGroups() = %+v", page)
	}
	if page.Items[0].Owner.Username != "group-owner-one" || page.Items[0].MemberCount != 1 {
		t.Fatalf("ListGroups() row = %+v", page.Items[0])
	}
	if page, err = platformService.ListGroups(ctx, *adminSession.principal, platform.GroupQuery{Keyword: "不存在的组"}); err != nil || page.Total != 0 {
		t.Fatalf("ListGroups(no match) = (%+v,%v)", page, err)
	}

	// 3. 组详情：成员状态分布 + 主账号候选人（此时只有 owner，候选为空）。
	detail, err := platformService.GetGroupDetail(ctx, *adminSession.principal, groupID)
	if err != nil {
		t.Fatalf("GetGroupDetail() error = %v", err)
	}
	if detail.Group.Name != groupName || detail.Group.Owner.Username != "group-owner-one" {
		t.Fatalf("GetGroupDetail() group = %+v", detail.Group)
	}
	if len(detail.OwnerCandidates) != 0 {
		t.Fatalf("GetGroupDetail() candidates = %+v, want empty", detail.OwnerCandidates)
	}

	// 4. 组主账号改密后签发邀请码。
	ownerSession := loginAs(t, identityService, "group-owner-one", "owner-temporary-password")
	changePassword(t, identityService, ownerSession, "owner-temporary-password", "group-owner-password")
	ownerSession = loginAs(t, identityService, "group-owner-one", "group-owner-password")

	invitation, err := organizationService.CreateInvitation(ctx, *ownerSession.principal, organization.CreateInvitationRequest{ExpiresInDays: 3})
	if err != nil {
		t.Fatalf("CreateInvitation() error = %v", err)
	}
	if invitation.InvitationCode == "" || invitation.ExpiresAt.IsZero() {
		t.Fatalf("CreateInvitation() = %+v", invitation)
	}

	// 5. 列表不得泄漏密文或明文；然后再查看明文必须与签发值时一致。
	invitationPage, err := organizationService.ListInvitations(ctx, *ownerSession.principal, organization.InvitationQuery{})
	if err != nil {
		t.Fatalf("ListInvitations() error = %v", err)
	}
	if invitationPage.Total != 1 || len(invitationPage.Items) != 1 {
		t.Fatalf("ListInvitations() = %+v", invitationPage)
	}
	if invitationPage.Items[0].Status != organization.InvitationDisplayActive {
		t.Fatalf("ListInvitations() status = %q, want active", invitationPage.Items[0].Status)
	}
	secret, err := organizationService.RevealInvitation(ctx, *ownerSession.principal, invitation.InvitationID)
	if err != nil {
		t.Fatalf("RevealInvitation() error = %v", err)
	}
	if secret.InvitationCode != invitation.InvitationCode {
		t.Fatalf("RevealInvitation() code = %q, want %q", secret.InvitationCode, invitation.InvitationCode)
	}

	// 6. 撤销后不可再查看，也不可重复撤销。
	revoked, err := organizationService.RevokeInvitation(ctx, *ownerSession.principal, invitation.InvitationID, organization.RevokeInvitationRequest{
		Version: invitationPage.Items[0].Version,
	})
	if err != nil {
		t.Fatalf("RevokeInvitation() error = %v", err)
	}
	if revoked.Status != organization.InvitationDisplayRevoked {
		t.Fatalf("RevokeInvitation() status = %q", revoked.Status)
	}
	if _, err = organizationService.RevealInvitation(ctx, *ownerSession.principal, invitation.InvitationID); err != nil {
		assertIntegrationCode(t, err, apperror.CodeInvitationNotRevealable)
	} else {
		t.Fatal("RevealInvitation() after revoke = nil error, want INVITATION_NOT_REVEALABLE")
	}
	if _, err = organizationService.RevokeInvitation(ctx, *ownerSession.principal, invitation.InvitationID, organization.RevokeInvitationRequest{Version: revoked.Version}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeInvitationNotFound)
	} else {
		t.Fatal("RevokeInvitation() twice = nil error, want INVITATION_NOT_FOUND")
	}

	// 7. 用一张新邀请码注册成员，随后把主账号交接给该成员。
	memberInvitation, err := organizationService.CreateInvitation(ctx, *ownerSession.principal, organization.CreateInvitationRequest{})
	if err != nil {
		t.Fatalf("CreateInvitation(member) error = %v", err)
	}
	registration, err := organizationService.Register(ctx, organization.RegisterRequest{
		InvitationCode: memberInvitation.InvitationCode, Username: "group-member-one",
		Password: "member-password", DisplayName: "一组业务员",
	})
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}

	detail, err = platformService.GetGroupDetail(ctx, *adminSession.principal, groupID)
	if err != nil {
		t.Fatalf("GetGroupDetail(after register) error = %v", err)
	}
	if len(detail.OwnerCandidates) != 1 || detail.OwnerCandidates[0].MembershipID == 0 {
		t.Fatalf("GetGroupDetail() candidates = %+v", detail.OwnerCandidates)
	}
	candidateMembershipID := detail.OwnerCandidates[0].MembershipID

	handover, err := platformService.ChangeGroupOwner(ctx, *adminSession.principal, groupID, platform.ChangeGroupOwnerRequest{
		Mode: platform.ChangeOwnerExistingMember, MembershipID: &candidateMembershipID, Version: detail.Group.Version,
	})
	if err != nil {
		t.Fatalf("ChangeGroupOwner(existing member) error = %v", err)
	}
	if handover.Owner.ID != registration.User.ID || handover.Owner.AccountType != identity.AccountTypeGroupOwner {
		t.Fatalf("ChangeGroupOwner() owner = %+v", handover.Owner)
	}

	// 交接完成后：旧主账号降级为普通成员且不再能签发邀请码；新主账号升格为 owner。
	oldOwnerSession := loginAs(t, identityService, "group-owner-one", "group-owner-password")
	if oldOwnerSession.principal.AccountType != identity.AccountTypeMember || oldOwnerSession.principal.MemberType != "member" {
		t.Fatalf("old owner principal = %+v", oldOwnerSession.principal)
	}
	newOwnerSession := loginAs(t, identityService, "group-member-one", "member-password")
	if newOwnerSession.principal.AccountType != identity.AccountTypeGroupOwner || newOwnerSession.principal.MemberType != "owner" {
		t.Fatalf("new owner principal = %+v", newOwnerSession.principal)
	}
	if _, err := organizationService.CreateInvitation(ctx, *oldOwnerSession.principal, organization.CreateInvitationRequest{}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeForbidden)
	} else {
		t.Fatal("old owner CreateInvitation() = nil error, want FORBIDDEN")
	}

	// 8. 停用组：幂等重复停用不报冲突；停用后组内已有令牌立即失效。
	detail, err = platformService.GetGroupDetail(ctx, *adminSession.principal, groupID)
	if err != nil {
		t.Fatalf("GetGroupDetail(before disable) error = %v", err)
	}
	disabled, err := platformService.ChangeGroupStatus(ctx, *adminSession.principal, groupID, platform.ChangeGroupStatusRequest{
		Status: organization.GroupStatusDisabled, Version: detail.Group.Version,
	})
	if err != nil {
		t.Fatalf("ChangeGroupStatus(disable) error = %v", err)
	}
	if disabled.Status != organization.GroupStatusDisabled || disabled.Version <= detail.Group.Version {
		t.Fatalf("ChangeGroupStatus(disable) = %+v", disabled)
	}
	again, err := platformService.ChangeGroupStatus(ctx, *adminSession.principal, groupID, platform.ChangeGroupStatusRequest{
		Status: organization.GroupStatusDisabled, Version: disabled.Version,
	})
	if err != nil {
		t.Fatalf("ChangeGroupStatus(disable again) error = %v", err)
	}
	if again.Version != disabled.Version {
		t.Fatalf("idempotent disable bumped version: %d -> %d", disabled.Version, again.Version)
	}
	if _, err := identityService.Authenticate(ctx, newOwnerSession.accessToken); err == nil {
		t.Fatal("Authenticate() on disabled group = nil error, want AUTH_TOKEN_EXPIRED")
	} else {
		assertIntegrationCode(t, err, apperror.CodeAuthTokenExpired)
	}

	// 9. 启用组后组可恢复治理，且组名冲突会被稳定映射。
	enabled, err := platformService.ChangeGroupStatus(ctx, *adminSession.principal, groupID, platform.ChangeGroupStatusRequest{
		Status: organization.GroupStatusActive, Version: again.Version,
	})
	if err != nil {
		t.Fatalf("ChangeGroupStatus(enable) error = %v", err)
	}
	if enabled.Status != organization.GroupStatusActive {
		t.Fatalf("ChangeGroupStatus(enable) = %+v", enabled)
	}
	if _, err := platformService.CreateGroup(ctx, *adminSession.principal, platform.CreateGroupRequest{
		Name: groupName, OwnerUsername: "another-owner", OwnerDisplayName: "另一主账号", OwnerTemporaryPassword: "another-password",
	}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeGroupNameExists)
	} else {
		t.Fatal("CreateGroup(duplicate name) = nil error, want GROUP_NAME_EXISTS")
	}
}

// loginAs 用账号密码登录，返回身份与当前访问令牌。
func loginAs(t *testing.T, service *identity.Service, username, password string) integrationSession {
	t.Helper()
	pair, err := service.Login(context.Background(), identity.LoginRequest{Username: username, Password: password})
	if err != nil {
		t.Fatalf("Login(%s) error = %v", username, err)
	}
	return integrationSession{
		principal:   authenticateIntegration(t, service, pair.AccessToken),
		accessToken: pair.AccessToken,
	}
}

// changePassword 走真实改密流程，避免测试直接改库绕过密码校验。
func changePassword(t *testing.T, service *identity.Service, session integrationSession, current, next string) {
	t.Helper()
	if err := service.ChangePassword(context.Background(), *session.principal, identity.ChangePasswordRequest{
		CurrentPassword: current, NewPassword: next,
	}); err != nil {
		t.Fatalf("ChangePassword() error = %v", err)
	}
}
