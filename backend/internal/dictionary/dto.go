package dictionary

type ListQuery struct {
	Kind     *Kind   `form:"kind" binding:"omitempty,oneof=supplier_company customer product_name product_model unit shipping_unit"`
	ParentID *uint64 `form:"parent_id" binding:"omitempty,min=1"`
	Status   *Status `form:"status" binding:"omitempty,oneof=active disabled"`
	Keyword  string  `form:"keyword"`
	Page     int     `form:"page" binding:"omitempty,min=1"`
	PageSize int     `form:"page_size" binding:"omitempty,min=1,max=100"`
}

type CreateRequest struct {
	Kind         Kind    `json:"kind" binding:"required,oneof=supplier_company customer product_name product_model unit shipping_unit"`
	Name         string  `json:"name" binding:"required"`
	ParentID     *uint64 `json:"parent_id" binding:"omitempty,min=1"`
	ContactPhone *string `json:"contact_phone"`
}

type UpdateRequest struct {
	Name         string  `json:"name" binding:"required"`
	ParentID     *uint64 `json:"parent_id" binding:"omitempty,min=1"`
	ContactPhone *string `json:"contact_phone"`
	Version      uint64  `json:"version" binding:"required,min=1"`
}

type ChangeStatusRequest struct {
	Status  Status `json:"status" binding:"required,oneof=active disabled"`
	Version uint64 `json:"version" binding:"required,min=1"`
}

type PaginationData struct {
	Page     int   `json:"page"`
	PageSize int   `json:"page_size"`
	Total    int64 `json:"total"`
}
type PageData struct {
	Items      []Entry        `json:"items"`
	Pagination PaginationData `json:"pagination"`
}
