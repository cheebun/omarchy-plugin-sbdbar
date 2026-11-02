package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

// Sample bodies follow the real providers' field layout, with a documentation IP.
var ipSamples = map[string]string{
	"ip.sb": `{"organization":"xTom Japan Corporation","asn":3258,"ip":"203.0.113.7","country":"Japan",
		"country_code":"JP","region":"Tokyo","city":"Tokyo","asn_organization":"xTom Japan Corporation"}`,
	"ipwho.is": `{"ip":"203.0.113.7","success":true,"country":"Japan","country_code":"JP","region":"Tokyo","city":"Tokyo",
		"connection":{"asn":3258,"org":"xTom Japan Corporation","isp":"xTom Japan Corporation"}}`,
	"ipapi.is": `{"ip":"203.0.113.7","is_bogon":false,"company":"xTom Japan Corporation",
		"asn":"AS3258 xTom Japan Corporation","city":"Tokyo","region":"Tokyo","country":"Japan"}`,
}

func TestParseIPResponse(t *testing.T) {
	for provider, body := range ipSamples {
		got, err := parseIPResponse(provider, []byte(body))
		if err != nil {
			t.Fatalf("%s: %v", provider, err)
		}
		if !got.Success || got.IP != "203.0.113.7" || got.Country != "Japan" || got.City != "Tokyo" ||
			got.ASN != "3258" || got.Org != "xTom Japan Corporation" {
			t.Errorf("%s = %+v", provider, got)
		}
	}
	// ipapi.is nested form
	nested := `{"ip":"203.0.113.7","location":{"country":"Japan","country_code":"JP","state":"Tokyo","city":"Tokyo"},
		"asn":{"asn":3258,"org":"xTom Japan Corporation"}}`
	if got, err := parseIPResponse("ipapi.is", []byte(nested)); err != nil || got.ASN != "3258" || got.CountryCode != "JP" || got.Org != "xTom Japan Corporation" {
		t.Errorf("ipapi.is nested = %+v, %v", got, err)
	}
	if _, err := parseIPResponse("ipwho.is", []byte(`{"success":false,"message":"Reserved range"}`)); err == nil {
		t.Error("ipwho.is failure accepted")
	}
	if _, err := parseIPResponse("ip.sb", []byte(`{"country":"Japan"}`)); err == nil {
		t.Error("missing ip accepted")
	}
}

func TestLookupIPOverHTTP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "sbdbar-agent" {
			t.Errorf("User-Agent = %q", r.Header.Get("User-Agent"))
		}
		w.Write([]byte(ipSamples["ip.sb"]))
	}))
	defer srv.Close()
	old := ipProviders["ip.sb"]
	ipProviders["ip.sb"] = srv.URL
	defer func() { ipProviders["ip.sb"] = old }()

	if got := lookupIP(context.Background(), srv.Client(), "ip.sb"); !got.Success || got.IP != "203.0.113.7" {
		t.Errorf("lookupIP = %+v", got)
	}
	if got := lookupIP(context.Background(), srv.Client(), "nope"); got.Success || got.Error == "" {
		t.Errorf("unknown provider = %+v", got)
	}
}

func TestSetPref(t *testing.T) {
	cfg := Config{}
	for _, c := range []struct {
		key, value string
		ok         bool
	}{
		{"groupsView", "list", true}, {"groupsView", "grid", false},
		{"ipProvider", "ipwho.is", true}, {"ipProvider", "ipify", false},
		{"stunServer", "stun.douyucdn.cn:18000", true}, {"stunServer", "", false}, {"stunServer", "nohost", false},
		{"color", "red", false},
	} {
		if err := setPref(&cfg, c.key, c.value); (err == nil) != c.ok {
			t.Errorf("setPref(%s, %q) err = %v", c.key, c.value, err)
		}
	}
	if cfg.GroupsView != "list" || cfg.IPProvider != "ipwho.is" || cfg.STUNServer != "stun.douyucdn.cn:18000" {
		t.Errorf("cfg = %+v", cfg)
	}
}

func (f *fakeDaemon) StartSTUNTest(req *daemonpb.STUNTestRequest, st grpc.ServerStreamingServer[daemonpb.STUNTestProgress]) error {
	if err := f.auth(st.Context()); err != nil {
		return err
	}
	if req.GetOutboundTag() != "direct" {
		return st.Send(&daemonpb.STUNTestProgress{IsFinal: true, Error: "outbound not found: " + req.GetOutboundTag()})
	}
	if req.GetServer() != defaultSTUNServer {
		return st.Send(&daemonpb.STUNTestProgress{IsFinal: true, Error: "binding request: i/o timeout"})
	}
	for _, p := range []*daemonpb.STUNTestProgress{
		{Phase: 0, ExternalAddr: "198.51.100.9:40000", LatencyMs: 12},
		{Phase: 1, ExternalAddr: "198.51.100.9:40000", LatencyMs: 12, NatMapping: 1},
		{Phase: 3, ExternalAddr: "198.51.100.9:40000", LatencyMs: 12, NatMapping: 1, NatFiltering: 3, NatTypeSupported: true, IsFinal: true},
	} {
		if err := st.Send(p); err != nil {
			return err
		}
	}
	return nil
}

func TestRunSTUN(t *testing.T) {
	f, addr := startFake(t)
	var buf syncBuffer
	runSTUN(&lineWriter{w: &buf}, addr, f.secret, "", "direct")
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("got %d lines: %s", len(lines), buf.String())
	}
	var last map[string]any
	_ = json.Unmarshal([]byte(lines[2]), &last)
	// No server given: the default (MiWiFi) is used
	if last["phase"] != "done" || last["externalAddr"] != "198.51.100.9:40000" || last["natMapping"] != "endpoint-independent" ||
		last["natFiltering"] != "address-and-port-dependent" || last["isFinal"] != true || last["outbound"] != "direct" ||
		last["server"] != defaultSTUNServer {
		t.Errorf("final line = %v", last)
	}

	// An unreachable server reports its error as the final line
	buf = syncBuffer{}
	runSTUN(&lineWriter{w: &buf}, addr, f.secret, "stun.example.com:3478", "direct")
	if !strings.Contains(buf.String(), "i/o timeout") || !strings.Contains(buf.String(), `"isFinal":true`) {
		t.Errorf("unreachable server = %s", buf.String())
	}

	buf = syncBuffer{}
	runSTUN(&lineWriter{w: &buf}, addr, f.secret, "", "nope")
	if !strings.Contains(buf.String(), "outbound not found") {
		t.Errorf("unknown outbound = %s", buf.String())
	}
}
