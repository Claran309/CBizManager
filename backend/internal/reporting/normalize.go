package reporting

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/pkg/bizdate"
)

const (
	// defaultPageSize 是分页缺省值。
	defaultPageSize = 20
	// maxPageSize 限制单页上限，防止客户端一次拉全表。
	maxPageSize = 100
	// maxKeywordLength 限制 LIKE 关键词长度。
	maxKeywordLength = 100
	// maxRemarkLength 限制备注长度（与单据 / 结算 / 财务模块保持一致）。
	maxRemarkLength = 500
	// snapshotNoPrefix 是总结算单号前缀。
	snapshotNoPrefix = "ZJS"
	// maxSnapshotNoAttempts 限制单号并发撞车后的重试次数。
	maxSnapshotNoAttempts = 5
)

// normalizePeriod 解析 period 参数并归一化成「当月 1 日 + 次月 1 日」的左闭右开区间。
//
// period 缺省时取注入时钟所属月份，与「单据月度汇总缺省查当月」保持一致：
// 界面一进来不应该是一片空白，也不应该要求客户端自己算月份。
func normalizePeriod(raw string, now time.Time) (string, time.Time, time.Time, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		start := bizdate.MonthStart(now)
		return bizdate.FormatMonth(start), start, start.AddDate(0, 1, 0), nil
	}
	start, end, err := bizdate.ParseMonth(text)
	if err != nil {
		return "", time.Time{}, time.Time{}, err
	}
	return bizdate.FormatMonth(start), start, end, nil
}

// normalizeKeyword 归一化 LIKE 关键词：折叠内部连续空白并去首尾；结果为空时返回空串。
func normalizeKeyword(raw string) (string, error) {
	text := strings.Join(strings.Fields(raw), " ")
	if len([]rune(text)) > maxKeywordLength {
		return "", fmt.Errorf("查询关键词过长")
	}
	return text, nil
}

// normalizeRemark 归一化备注：折叠内部连续空白；结果为空时返回 nil（而不是空字符串），
// 避免数据库里同时出现 NULL 与 '' 两种「没有备注」。
func normalizeRemark(raw *string) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	text := strings.Join(strings.Fields(*raw), " ")
	if text == "" {
		return nil, nil
	}
	if len([]rune(text)) > maxRemarkLength {
		return nil, fmt.Errorf("备注过长")
	}
	return &text, nil
}

// normalizePagination 归一化分页参数。
func normalizePagination(page, pageSize int) (int, int, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = defaultPageSize
	}
	if pageSize > maxPageSize {
		return 0, 0, fmt.Errorf("page_size 超出上限")
	}
	return page, pageSize, nil
}

// formatSnapshotNo 生成总结算单号：ZJS + YYYYMM + -4 位当月序号（如 ZJS202609-0003）。
//
// 月份用紧凑写法（bizdate.FormatMonthCompact）而不是带横线的 YYYY-MM：
// 单号里再出现一个 "-" 会让 sequenceFromSnapshotNo 的「最后一个 - 之后是序号」解析规则失效。
func formatSnapshotNo(month string, sequence int) string {
	return fmt.Sprintf("%s%s-%04d", snapshotNoPrefix, month, sequence)
}

// snapshotNoLikePattern 返回按月份过滤单号的 LIKE 前缀。
func snapshotNoLikePattern(month string) string {
	return snapshotNoPrefix + month + "-%"
}

// sequenceFromSnapshotNo 从既有单号里解析当月序号，解析失败返回 0（由调用方从 1 重新开始）。
func sequenceFromSnapshotNo(snapshotNo string) int {
	index := strings.LastIndex(snapshotNo, "-")
	if index < 0 || index == len(snapshotNo)-1 {
		return 0
	}
	sequence, err := strconv.Atoi(snapshotNo[index+1:])
	if err != nil || sequence < 0 {
		return 0
	}
	return sequence
}
