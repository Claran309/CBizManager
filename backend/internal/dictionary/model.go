package dictionary

import "time"

type Kind string

const (
	KindSupplierCompany Kind = "supplier_company"
	KindCustomer        Kind = "customer"
	KindProductName     Kind = "product_name"
	KindProductModel    Kind = "product_model"
	KindUnit            Kind = "unit"
	KindShippingUnit    Kind = "shipping_unit"
)

type Status string

const (
	StatusActive   Status = "active"
	StatusDisabled Status = "disabled"
)

type Entry struct {
	ID             uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	GroupID        uint64    `gorm:"not null;index" json:"group_id"`
	Kind           Kind      `gorm:"size:32;not null" json:"kind"`
	Name           string    `gorm:"size:191;not null" json:"name"`
	NormalizedName string    `gorm:"size:191;not null" json:"-"`
	ParentID       *uint64   `json:"parent_id"`
	ParentScopeID  uint64    `gorm:"column:parent_scope_id;->;-:migration" json:"-"`
	ContactPhone   *string   `gorm:"size:50" json:"contact_phone"`
	Status         Status    `gorm:"size:16;not null" json:"status"`
	Version        uint64    `gorm:"not null;default:1" json:"version"`
	CreatedBy      uint64    `gorm:"not null" json:"created_by"`
	UpdatedBy      uint64    `gorm:"not null" json:"updated_by"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (Entry) TableName() string { return "dictionary_entries" }

type Page struct {
	Items    []Entry
	Page     int
	PageSize int
	Total    int64
}

type Draft struct {
	Kind           Kind
	Name           string
	NormalizedName string
	ParentID       *uint64
	ContactPhone   *string
}
