package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

// ipProviders maps the provider names shown in Settings to their JSON endpoints.
// The request goes through the system network, so with sing-box in TUN mode the
// answer is the proxy egress address that websites see.
var ipProviders = map[string]string{
	"ip.sb":    "https://api.ip.sb/geoip",
	"ipwho.is": "https://ipwho.is/",
	"ipapi.is": "https://api.ipapi.is/",
}

const defaultIPProvider = "ip.sb"

// ipInfo is the provider-independent shape returned by the ip command.
type ipInfo struct {
	Success     bool   `json:"success"`
	Provider    string `json:"provider"`
	IP          string `json:"ip"`
	Country     string `json:"country"`
	CountryCode string `json:"countryCode"`
	Region      string `json:"region"`
	City        string `json:"city"`
	ASN         string `json:"asn"`
	Org         string `json:"org"`
	Error       string `json:"error,omitempty"`
}

func lookupIP(ctx context.Context, client *http.Client, provider string) ipInfo {
	endpoint, ok := ipProviders[provider]
	if !ok {
		return ipInfo{Provider: provider, Error: fmt.Sprintf("unknown provider %q", provider)}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return ipInfo{Provider: provider, Error: err.Error()}
	}
	req.Header.Set("User-Agent", "sbdbar-agent")
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return ipInfo{Provider: provider, Error: err.Error()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return ipInfo{Provider: provider, Error: err.Error()}
	}
	if resp.StatusCode != http.StatusOK {
		return ipInfo{Provider: provider, Error: fmt.Sprintf("%s returned HTTP %d", provider, resp.StatusCode)}
	}
	info, err := parseIPResponse(provider, body)
	if err != nil {
		return ipInfo{Provider: provider, Error: err.Error()}
	}
	return info
}

// parseIPResponse normalizes the three providers' JSON into ipInfo.
func parseIPResponse(provider string, body []byte) (ipInfo, error) {
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		return ipInfo{}, fmt.Errorf("%s: invalid JSON: %w", provider, err)
	}
	str := func(m map[string]any, key string) string {
		switch v := m[key].(type) {
		case string:
			return v
		case float64:
			return strconv.FormatFloat(v, 'f', -1, 64)
		}
		return ""
	}
	sub := func(key string) map[string]any {
		m, _ := raw[key].(map[string]any)
		if m == nil {
			m = map[string]any{}
		}
		return m
	}

	info := ipInfo{Provider: provider, IP: str(raw, "ip")}
	switch provider {
	case "ip.sb":
		info.Country, info.CountryCode = str(raw, "country"), str(raw, "country_code")
		info.Region, info.City = str(raw, "region"), str(raw, "city")
		info.ASN, info.Org = str(raw, "asn"), str(raw, "organization")
	case "ipwho.is":
		if ok, present := raw["success"].(bool); present && !ok {
			return ipInfo{}, fmt.Errorf("ipwho.is: %s", str(raw, "message"))
		}
		conn := sub("connection")
		info.Country, info.CountryCode = str(raw, "country"), str(raw, "country_code")
		info.Region, info.City = str(raw, "region"), str(raw, "city")
		info.ASN, info.Org = str(conn, "asn"), str(conn, "org")
	case "ipapi.is":
		// The free tier answers with nested objects; tolerate the flat form too.
		loc, asn := sub("location"), sub("asn")
		info.Country, info.CountryCode = firstNonEmpty(str(loc, "country"), str(raw, "country")), str(loc, "country_code")
		info.Region, info.City = firstNonEmpty(str(loc, "state"), str(raw, "region")), firstNonEmpty(str(loc, "city"), str(raw, "city"))
		info.ASN, info.Org = str(asn, "asn"), firstNonEmpty(str(asn, "org"), str(sub("company"), "name"))
		if info.ASN == "" {
			// Flat form: "asn": "AS3258 xTom Japan Corporation"
			if s, ok := raw["asn"].(string); ok {
				num, org, _ := strings.Cut(s, " ")
				info.ASN, info.Org = strings.TrimPrefix(num, "AS"), firstNonEmpty(info.Org, org)
			}
		}
		info.Org = firstNonEmpty(info.Org, str(raw, "company"))
	}
	info.ASN = strings.TrimPrefix(info.ASN, "AS")
	if info.IP == "" {
		return ipInfo{}, errors.New(provider + ": no ip in response")
	}
	info.Success = true
	return info, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func runIP(provider string) ipInfo {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	return lookupIP(ctx, &http.Client{}, provider)
}

var stunPhases = []string{"binding", "nat-mapping", "nat-filtering", "done"}

var natBehaviors = []string{"unknown", "endpoint-independent", "address-dependent", "address-and-port-dependent"}

func enumName(names []string, v int32) string {
	if v >= 0 && int(v) < len(names) {
		return names[v]
	}
	return "unknown"
}

// stunLine maps a STUNTestProgress onto the JSON line QML reads.
func stunLine(p *daemonpb.STUNTestProgress, outbound string) map[string]any {
	return map[string]any{
		"type":             "stun",
		"outbound":         outbound,
		"phase":            enumName(stunPhases, p.GetPhase()),
		"externalAddr":     p.GetExternalAddr(),
		"latencyMs":        p.GetLatencyMs(),
		"natMapping":       enumName(natBehaviors, p.GetNatMapping()),
		"natFiltering":     enumName(natBehaviors, p.GetNatFiltering()),
		"natTypeSupported": p.GetNatTypeSupported(),
		"isFinal":          p.GetIsFinal(),
		"error":            p.GetError(),
	}
}

// defaultSTUNServer is used when none is configured. sing-box's own default
// (stun.voipgate.com) times out on direct connections in mainland China;
// stun.miwifi.com answers quickly there and also detects NAT type.
const defaultSTUNServer = "stun.miwifi.com:3478"

// runSTUN asks sing-box to run a STUN test through one outbound and streams
// its progress. Through "direct" the external address is the host's real
// public IP; through a proxy outbound it is that proxy's UDP egress.
func runSTUN(out *lineWriter, daemonURL, secret, server, outbound string) {
	conn, client, err := dial(daemonURL, secret)
	if err != nil {
		out.emit(map[string]any{"type": "stun", "outbound": outbound, "isFinal": true, "error": errorMessage(err)})
		return
	}
	defer conn.Close()
	if server == "" {
		server = defaultSTUNServer
	}
	stunOnce(client, server, outbound, func(line map[string]any) { out.emit(line) })
}

// stunOnce runs one STUN test and returns its final line.
func stunOnce(client daemonpb.StartedServiceClient, server, outbound string, emit func(map[string]any)) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	fail := func(err error) map[string]any {
		line := map[string]any{"type": "stun", "outbound": outbound, "server": server, "isFinal": true, "error": errorMessage(err)}
		emit(line)
		return line
	}
	st, err := client.StartSTUNTest(ctx, &daemonpb.STUNTestRequest{Server: server, OutboundTag: outbound})
	if err != nil {
		return fail(err)
	}
	for {
		p, err := st.Recv()
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = errors.New("STUN test ended without a result")
			}
			return fail(err)
		}
		line := stunLine(p, outbound)
		line["server"] = server
		emit(line)
		if p.GetIsFinal() {
			return line
		}
	}
}
