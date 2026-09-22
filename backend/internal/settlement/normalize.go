package settlement

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	// maxSourcesPerSettlement 限制单张结算单可关联的源单据数量。
	// 一期一张单据最多几百行明细，200 张源单据足够覆盖「按月批量结算」的用法，
	// 同时避免单次请求把整月单据一次性全拿进来导致事务过长。
	maxSourcesPerSettlement = 200
	// settlementNoPrefix 是结算单号前缀：JS = 结算。
	settlementNoPrefix = "JS"
)

// formatSettlementNo 生成结算单号：前缀 + 年月 + 当月 4 位序号，例如 JS202609-0003。
//
// 刻意按「年月」而不是「业务日期」编号：结算单没有自己的业务日期，
// 它汇总的是若干张源单据，用生成月份编号更符合财务对账习惯。
func formatSettlementNo(month string, sequence int) string {
	return fmt.Sprintf("%s%s-%04d", settlementNoPrefix, month, sequence)
}

// settlementNoLikePattern 返回按月份过滤单号的 LIKE 前缀。
func settlementNoLikePattern(month string) string {
	return settlementNoPrefix + month + "-%"
}

// sequenceFromSettlementNo 从既有单号中解析当月序号，解析失败返回 0（由调用方从 1 重新开始）。
func sequenceFromSettlementNo(settlementNo string) int {
	index := strings.LastIndex(settlementNo, "-")
	if index < 0 || index == len(settlementNo)-1 {
		return 0
	}
	sequence, err := strconv.Atoi(settlementNo[index+1:])
	if err != nil || sequence < 0 {
		return 0
	}
	return sequence
}

// normalizeOptionalText 折叠内部连续空白并去除首尾空白；结果为空时返回 nil。
//
// 与单据模块的文本归一化规则保持一致（同一套表单体系不允许出现两种空白口径）。
func normalizeOptionalText(raw *string, maxLength int) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	cleaned := strings.Join(strings.Fields(*raw), " ")
	if cleaned == "" {
		return nil, nil
	}
	if len([]rune(cleaned)) > maxLength {
		return nil, fmt.Errorf("文本长度超过 %d", maxLength)
	}
	return &cleaned, nil
}

// normalizeSourceIDs 归一化结算申请里勾选的源单据 ID 列表。
//
// 去重时保留首次出现的顺序，便于生成稳定的请求指纹；
// 同一个单据在请求里重复出现属于客户端缺陷，必须显式报错而不是静默去重，
// 否则客户端会以为「勾了两张」，服务端只结了一张。
func normalizeSourceIDs(raw []uint64) ([]uint64, error) {
	if len(raw) == 0 || len(raw) > maxSourcesPerSettlement {
		return nil, fmt.Errorf("源单据数量必须在 1 到 %d 之间", maxSourcesPerSettlement)
	}
	seen := make(map[uint64]struct{}, len(raw))
	result := make([]uint64, 0, len(raw))
	for _, id := range raw {
		if id == 0 {
			return nil, fmt.Errorf("源单据 ID 非法")
		}
		if _, exists := seen[id]; exists {
			return nil, fmt.Errorf("源单据 %d 重复出现", id)
		}
		seen[id] = struct{}{}
		result = append(result, id)
	}
	return result, nil
}
