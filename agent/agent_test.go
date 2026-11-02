package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

func TestGRPCTarget(t *testing.T) {
	cases := []struct {
		raw, secret, want string
		wantErr           bool
	}{
		{"http://127.0.0.1:9999", "s", "127.0.0.1:9999", false},
		{"127.0.0.1:9999", "s", "127.0.0.1:9999", false},
		{"", "", "127.0.0.1:9999", false},
		{"http://[::1]:9999", "s", "[::1]:9999", false},
		{"http://localhost:9999/", "s", "localhost:9999", false},
		{"http://10.0.0.1:9999", "", "10.0.0.1:9999", false},
		{"http://10.0.0.1:9999", "s", "", true},
		{"https://127.0.0.1:9999", "s", "", true},
	}
	for _, c := range cases {
		got, err := grpcTarget(c.raw, c.secret)
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("grpcTarget(%q, %q) = %q, %v", c.raw, c.secret, got, err)
		}
	}
}

func TestConfigRoundTripAndMigration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sbdbar", "config.json")
	t.Setenv("SBDBAR_CONFIG", path)

	if cfg := loadConfig(); cfg.URL != defaultURL || !cfg.ShowTraffic || cfg.Password != "" || cfg.GroupsView != "card" || cfg.IPProvider != "ip.sb" || cfg.STUNServer != defaultSTUNServer {
		t.Fatalf("defaults = %+v", cfg)
	}

	// A config left by the Python client: Clash URL in url, daemon URL in daemonUrl.
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	old := `{"url": "http://127.0.0.1:9090", "daemonUrl": "http://127.0.0.1:9998", "password": "p", "showTraffic": false}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := loadConfig()
	if cfg.URL != "http://127.0.0.1:9998" || cfg.Password != "p" || cfg.ShowTraffic {
		t.Fatalf("migrated = %+v", cfg)
	}

	cfg.URL = "http://127.0.0.1:9997"
	cfg.GroupsView = "list"
	if err := saveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("config mode = %v", info.Mode().Perm())
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "daemonUrl") {
		t.Errorf("saved config still has daemonUrl: %s", data)
	}
	if got := loadConfig(); got != cfg {
		t.Errorf("reloaded = %+v, want %+v", got, cfg)
	}
}

func TestResolveEndpointPrecedence(t *testing.T) {
	t.Setenv("SBDBAR_CONFIG", filepath.Join(t.TempDir(), "config.json"))
	if err := saveConfig(Config{URL: "http://127.0.0.1:1111", Password: "saved"}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BOX_API_URL", "")
	t.Setenv("BOX_API_SECRET", "")
	if u, s := resolveEndpoint(""); u != "http://127.0.0.1:1111" || s != "saved" {
		t.Errorf("config only: %q %q", u, s)
	}
	t.Setenv("BOX_API_URL", "http://127.0.0.1:2222")
	t.Setenv("BOX_API_SECRET", "env")
	if u, s := resolveEndpoint(""); u != "http://127.0.0.1:2222" || s != "env" {
		t.Errorf("env: %q %q", u, s)
	}
	if u, _ := resolveEndpoint("http://127.0.0.1:3333"); u != "http://127.0.0.1:3333" {
		t.Errorf("flag: %q", u)
	}
}

func conn(id string, created int64) *daemonpb.Connection {
	return &daemonpb.Connection{Id: id, CreatedAt: created, Network: "tcp", Destination: "1.2.3.4:443", Inbound: "tun-in", InboundType: "tun", Outbound: "node", ChainList: []string{"node", "Proxies"}}
}

func TestConnTable(t *testing.T) {
	tb := newConnTable(2 * time.Second)
	tb.apply(&daemonpb.ConnectionEvents{Reset_: true, Events: []*daemonpb.ConnectionEvent{
		{Type: daemonpb.ConnectionEventType_CONNECTION_EVENT_NEW, Id: "a", Connection: conn("a", 1)},
		{Type: daemonpb.ConnectionEventType_CONNECTION_EVENT_NEW, Id: "b", Connection: conn("b", 2)},
	}})
	tb.apply(&daemonpb.ConnectionEvents{Events: []*daemonpb.ConnectionEvent{
		{Type: daemonpb.ConnectionEventType_CONNECTION_EVENT_UPDATE, Id: "a", UplinkDelta: 2048, DownlinkDelta: 4096},
	}})
	snap := tb.snapshot()
	if len(snap) != 2 || snap[0].ID != "b" || snap[1].ID != "a" {
		t.Fatalf("order = %+v", snap)
	}
	if snap[1].UpRate != "↑ 1.0 KB/s" || snap[1].DownRate != "↓ 2.0 KB/s" || snap[1].Upload != 2048 {
		t.Errorf("rates over a 2s interval = %+v", snap[1])
	}

	// No update for "a" in the next batch: its rate drops to zero, totals stay.
	tb.apply(&daemonpb.ConnectionEvents{Events: []*daemonpb.ConnectionEvent{
		{Type: daemonpb.ConnectionEventType_CONNECTION_EVENT_CLOSED, Id: "b"},
	}})
	snap = tb.snapshot()
	if len(snap) != 1 || snap[0].UpRate != "↑ 0 B/s" || snap[0].Upload != 2048 {
		t.Errorf("after close = %+v", snap)
	}

	tb.apply(&daemonpb.ConnectionEvents{Reset_: true})
	if len(tb.snapshot()) != 0 {
		t.Error("reset did not clear the table")
	}
}

func TestConnToJSON(t *testing.T) {
	c := conn("x", 1)
	got := connToJSON(c)
	if got.Host != "1.2.3.4" || got.Network != "TCP" || got.Inbound != "tun/tun-in" || got.Route != "node" || got.Chain != "node / Proxies" {
		t.Errorf("ip destination = %+v", got)
	}
	c.Domain = "example.com"
	c.ChainList = nil
	c.Outbound = ""
	got = connToJSON(c)
	if got.Host != "example.com" || got.Route != "direct" {
		t.Errorf("domain/direct = %+v", got)
	}
}

func TestFilterLogs(t *testing.T) {
	msgs := []*daemonpb.Log_Message{
		{Level: daemonpb.LogLevel_ERROR, Message: "\x1b[31mERROR\x1b[0m[12] boom\n"},
		{Level: daemonpb.LogLevel_INFO, Message: "\x1b[36mINFO\x1b[0m[13] [\x1b[38;5;165m42\x1b[0m 0ms] hello"},
		{Level: daemonpb.LogLevel_DEBUG, Message: "DEBUG[14] noise"},
		{Level: daemonpb.LogLevel_WARN, Message: "plain warning"},
	}
	got := filterLogs(msgs, daemonpb.LogLevel_INFO)
	if len(got) != 3 {
		t.Fatalf("info filter kept %d entries", len(got))
	}
	if got[0].Level != "error" || got[0].Seq != "12" || got[0].Message != "boom" || got[0].Raw != "\x1b[31mERROR\x1b[0m[12] boom" {
		t.Errorf("error entry = %+v", got[0])
	}
	if got[1].Message != "[42 0ms] hello" {
		t.Errorf("ansi not stripped from message: %q", got[1].Message)
	}
	if got[2].Seq != "" || got[2].Message != "plain warning" {
		t.Errorf("unprefixed entry = %+v", got[2])
	}
	if lvl, ok := parseLogLevel("warn"); !ok || lvl != daemonpb.LogLevel_WARN {
		t.Error("parseLogLevel(warn)")
	}
	if _, ok := parseLogLevel("loud"); ok {
		t.Error("parseLogLevel accepted an unknown level")
	}
}

func TestFormatting(t *testing.T) {
	for in, want := range map[int64]string{0: "0 B", 512: "512 B", 1536: "1.5 KB", 5 << 20: "5.0 MB"} {
		if got := formatBytes(in); got != want {
			t.Errorf("formatBytes(%d) = %q, want %q", in, got, want)
		}
	}
	if got := formatDuration(31*time.Hour + 49*time.Minute + 3*time.Second); got != "31h49m3s" {
		t.Errorf("formatDuration = %q", got)
	}
	if got := formatDuration(65 * time.Second); got != "1m5s" {
		t.Errorf("formatDuration = %q", got)
	}
}

// fakeDaemon implements the RPCs the agent uses and checks the bearer secret.
type fakeDaemon struct {
	daemonpb.UnimplementedStartedServiceServer
	secret string

	mu        sync.Mutex
	mode      string
	selected  map[string]string
	urlTested []string
	closed    []string
	closedAll bool
}

func (f *fakeDaemon) auth(ctx context.Context) error {
	md, _ := metadata.FromIncomingContext(ctx)
	if got := md.Get("authorization"); len(got) == 0 || got[0] != "Bearer "+f.secret {
		return status.Error(codes.Unauthenticated, "invalid authorization")
	}
	return nil
}

func (f *fakeDaemon) groups() *daemonpb.Groups {
	f.mu.Lock()
	defer f.mu.Unlock()
	return &daemonpb.Groups{Group: []*daemonpb.Group{
		{Tag: "Proxies", Type: "selector", Selectable: true, Selected: f.selected["Proxies"], Items: []*daemonpb.GroupItem{{Tag: "a", Type: "vless", UrlTestDelay: 120}, {Tag: "b", Type: "trojan"}}},
		{Tag: "Auto", Type: "urltest", Selected: "a"},
	}}
}

func (f *fakeDaemon) GetVersion(ctx context.Context, _ *emptypb.Empty) (*daemonpb.Version, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	return &daemonpb.Version{Version: "1.14.3", ApiVersion: 4}, nil
}

func (f *fakeDaemon) GetStartedAt(ctx context.Context, _ *emptypb.Empty) (*daemonpb.StartedAt, error) {
	return &daemonpb.StartedAt{StartedAt: time.Now().Add(-90 * time.Second).UnixMilli()}, f.auth(ctx)
}

func (f *fakeDaemon) GetClashModeStatus(ctx context.Context, _ *emptypb.Empty) (*daemonpb.ClashModeStatus, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return &daemonpb.ClashModeStatus{ModeList: []string{"Rule", "Global", "Direct"}, CurrentMode: f.mode}, nil
}

func (f *fakeDaemon) SetClashMode(ctx context.Context, m *daemonpb.ClashMode) (*emptypb.Empty, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.mode = m.GetMode()
	f.mu.Unlock()
	return &emptypb.Empty{}, nil
}

func (f *fakeDaemon) SubscribeClashMode(_ *emptypb.Empty, st grpc.ServerStreamingServer[daemonpb.ClashMode]) error {
	if err := f.auth(st.Context()); err != nil {
		return err
	}
	<-st.Context().Done()
	return nil
}

func (f *fakeDaemon) SubscribeStatus(req *daemonpb.SubscribeStatusRequest, st grpc.ServerStreamingServer[daemonpb.Status]) error {
	if err := f.auth(st.Context()); err != nil {
		return err
	}
	for {
		if err := st.Send(&daemonpb.Status{Memory: 1 << 20, Uplink: 10, Downlink: 20, ConnectionsOut: 3}); err != nil {
			return err
		}
		select {
		case <-st.Context().Done():
			return nil
		case <-time.After(time.Duration(req.GetInterval())):
		}
	}
}

func (f *fakeDaemon) SubscribeGroups(_ *emptypb.Empty, st grpc.ServerStreamingServer[daemonpb.Groups]) error {
	if err := f.auth(st.Context()); err != nil {
		return err
	}
	// Send the same groups twice, then a change, as the daemon does during a URL test.
	for i := 0; i < 2; i++ {
		if err := st.Send(f.groups()); err != nil {
			return err
		}
	}
	changed := f.groups()
	changed.Group[0].Items[1].UrlTestDelay = 88
	if err := st.Send(changed); err != nil {
		return err
	}
	<-st.Context().Done()
	return nil
}

func (f *fakeDaemon) SelectOutbound(ctx context.Context, r *daemonpb.SelectOutboundRequest) (*emptypb.Empty, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.selected[r.GetGroupTag()] = r.GetOutboundTag()
	f.mu.Unlock()
	return &emptypb.Empty{}, nil
}

func (f *fakeDaemon) URLTest(ctx context.Context, r *daemonpb.URLTestRequest) (*emptypb.Empty, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.urlTested = append(f.urlTested, r.GetOutboundTag())
	f.mu.Unlock()
	return &emptypb.Empty{}, nil
}

func (f *fakeDaemon) CloseConnection(ctx context.Context, r *daemonpb.CloseConnectionRequest) (*emptypb.Empty, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.closed = append(f.closed, r.GetId())
	f.mu.Unlock()
	return &emptypb.Empty{}, nil
}

func (f *fakeDaemon) CloseAllConnections(ctx context.Context, _ *emptypb.Empty) (*emptypb.Empty, error) {
	if err := f.auth(ctx); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.closedAll = true
	f.mu.Unlock()
	return &emptypb.Empty{}, nil
}

func startFake(t *testing.T) (*fakeDaemon, string) {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDaemon{secret: "s3cret", mode: "Rule", selected: map[string]string{"Proxies": "a"}}
	srv := grpc.NewServer()
	daemonpb.RegisterStartedServiceServer(srv, f)
	go srv.Serve(lis)
	t.Cleanup(srv.Stop)
	return f, "http://" + lis.Addr().String()
}

func TestActions(t *testing.T) {
	f, addr := startFake(t)

	if res := runAction(addr, "wrong", "close-all", nil); res["success"] != false || res["status"] != 401 {
		t.Errorf("bad secret = %v", res)
	}
	if res := runAction(addr, f.secret, "select", []string{"Proxies", "b"}); res["success"] != true {
		t.Errorf("select = %v", res)
	}
	if res := runAction(addr, f.secret, "set-mode", []string{"global"}); res["success"] != true {
		t.Errorf("set-mode = %v", res)
	}
	if res := runAction(addr, f.secret, "set-mode", []string{"tunnel"}); res["success"] != false {
		t.Errorf("set-mode unknown = %v", res)
	}
	if res := runAction(addr, f.secret, "urltest", nil); res["success"] != true {
		t.Errorf("urltest all = %v", res)
	}
	if res := runAction(addr, f.secret, "close", []string{"c1"}); res["success"] != true {
		t.Errorf("close = %v", res)
	}
	if res := runAction(addr, f.secret, "close-all", nil); res["success"] != true {
		t.Errorf("close-all = %v", res)
	}
	if res := runAction(addr, f.secret, "select", []string{"Proxies"}); res["success"] != false {
		t.Errorf("select usage = %v", res)
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.selected["Proxies"] != "b" || f.mode != "Global" || !f.closedAll || len(f.closed) != 1 {
		t.Errorf("daemon state = %+v", f)
	}
	if len(f.urlTested) != 2 {
		t.Errorf("urltest all tested %v", f.urlTested)
	}
}

func TestWatchSession(t *testing.T) {
	f, addr := startFake(t)
	conn, client, err := dial(addr, f.secret)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	var buf syncBuffer
	out := &lineWriter{w: &buf}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	delivered, _ := watchSession(out, 100*time.Millisecond)(ctx, client)
	if !delivered {
		t.Fatal("no status delivered")
	}

	seen := map[string]map[string]any{}
	groupLines := 0
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("bad line %q: %v", line, err)
		}
		if m["type"] == "groups" {
			groupLines++
		}
		seen[m["type"].(string)] = m
	}
	// Three pushes, one a repeat: only two lines go out, the last with the new delay.
	if groupLines != 2 {
		t.Errorf("groups lines = %d, want 2", groupLines)
	}
	if d := seen["groups"]["groups"].([]any)[0].(map[string]any)["items"].([]any)[1].(map[string]any)["delay"]; d != float64(88) {
		t.Errorf("last groups delay = %v", d)
	}
	if seen["hello"]["version"] != "1.14.3" {
		t.Errorf("hello = %v", seen["hello"])
	}
	if seen["mode"]["mode"] != "Rule" {
		t.Errorf("mode = %v", seen["mode"])
	}
	if st := seen["status"]; st["uploadRate"] != float64(10) || st["connectionsCount"] != float64(3) || st["uptime"] == "" {
		t.Errorf("status = %v", st)
	}
	if g := seen["groups"]; g["activeNode"] != "a" || len(g["groups"].([]any)) != 2 {
		t.Errorf("groups = %v", g)
	}
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}
