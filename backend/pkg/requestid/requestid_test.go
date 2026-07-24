package requestid

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func TestMiddlewarePreservesValidRequestID(t *testing.T) {
	const incoming = "550e8400-e29b-41d4-a716-446655440000"
	var fromContext string
	router := newTestRouter(func(c *gin.Context) {
		fromContext = FromContext(c)
		c.Status(http.StatusNoContent)
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set(Header, incoming)
	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusNoContent)
	}
	if got := recorder.Header().Get(Header); got != incoming {
		t.Fatalf("response request ID = %q, want %q", got, incoming)
	}
	if fromContext != incoming {
		t.Fatalf("FromContext() = %q, want %q", fromContext, incoming)
	}
}

func TestMiddlewareGeneratesUUIDWhenRequestIDMissing(t *testing.T) {
	var fromContext string
	router := newTestRouter(func(c *gin.Context) {
		fromContext = FromContext(c)
		c.Status(http.StatusNoContent)
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	router.ServeHTTP(recorder, request)

	generated := recorder.Header().Get(Header)
	if generated == "" {
		t.Fatal("middleware must generate a request ID")
	}
	if _, err := uuid.Parse(generated); err != nil {
		t.Fatalf("generated request ID %q is not a UUID: %v", generated, err)
	}
	if fromContext != generated {
		t.Fatalf("FromContext() = %q, want generated ID %q", fromContext, generated)
	}
}

func TestMiddlewareReplacesInvalidRequestID(t *testing.T) {
	const invalid = "contains spaces"
	router := newTestRouter(func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set(Header, invalid)
	router.ServeHTTP(recorder, request)

	generated := recorder.Header().Get(Header)
	if generated == invalid || generated == "" {
		t.Fatalf("response request ID = %q, want a generated value", generated)
	}
	if _, err := uuid.Parse(generated); err != nil {
		t.Fatalf("replacement request ID %q is not a UUID: %v", generated, err)
	}
}

func TestFromContextReturnsEmptyForMissingValue(t *testing.T) {
	context, _ := gin.CreateTestContext(httptest.NewRecorder())
	if got := FromContext(context); got != "" {
		t.Fatalf("FromContext() = %q, want empty string", got)
	}
}

func newTestRouter(handler gin.HandlerFunc) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(Middleware())
	router.GET("/", handler)
	return router
}
