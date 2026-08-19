package response

import "testing"

func TestCodeNotImplementedIsDefined(t *testing.T) {
	if CodeNotImplemented != 10010 {
		t.Fatalf("CodeNotImplemented = %d, want 10010", CodeNotImplemented)
	}
}
