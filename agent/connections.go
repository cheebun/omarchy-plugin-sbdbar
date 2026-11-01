package main

import (
	"context"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

const maxConnections = 150

func connectionsSession(out *lineWriter, interval time.Duration) func(context.Context, daemonpb.StartedServiceClient) (bool, error) {
	return func(ctx context.Context, client daemonpb.StartedServiceClient) (bool, error) {
		st, err := client.SubscribeConnections(ctx, &daemonpb.SubscribeConnectionsRequest{Interval: int64(interval)})
		if err != nil {
			return false, err
		}
		table := newConnTable(interval)
		delivered := false
		for {
			evs, err := st.Recv()
			if err != nil {
				return delivered, err
			}
			delivered = true
			table.apply(evs)
			list := table.snapshot()
			total := len(list)
			if len(list) > maxConnections {
				list = list[:maxConnections]
			}
			out.emit(map[string]any{"type": "connections", "online": true, "connections": list, "totalCount": total})
		}
	}
}

// connTable folds NEW/UPDATE/CLOSED events into the current set of live connections.
type connTable struct {
	conns    map[string]*daemonpb.Connection
	interval time.Duration
}

func newConnTable(interval time.Duration) *connTable {
	if interval <= 0 {
		interval = time.Second
	}
	return &connTable{conns: map[string]*daemonpb.Connection{}, interval: interval}
}

func (t *connTable) apply(evs *daemonpb.ConnectionEvents) {
	if evs.GetReset_() {
		t.conns = map[string]*daemonpb.Connection{}
	}
	// A connection without an UPDATE in this batch moved no traffic.
	for _, c := range t.conns {
		c.Uplink, c.Downlink = 0, 0
	}
	for _, ev := range evs.GetEvents() {
		id := ev.GetId()
		if id == "" && ev.GetConnection() != nil {
			id = ev.GetConnection().GetId()
		}
		switch ev.GetType() {
		case daemonpb.ConnectionEventType_CONNECTION_EVENT_CLOSED:
			delete(t.conns, id)
		case daemonpb.ConnectionEventType_CONNECTION_EVENT_NEW:
			if c := ev.GetConnection(); c != nil {
				t.conns[id] = c
			}
		case daemonpb.ConnectionEventType_CONNECTION_EVENT_UPDATE:
			// Updates carry traffic deltas; a full connection, when present, replaces ours.
			if c := ev.GetConnection(); c != nil {
				t.conns[id] = c
				continue
			}
			if c, ok := t.conns[id]; ok {
				c.Uplink = t.perSecond(ev.GetUplinkDelta())
				c.Downlink = t.perSecond(ev.GetDownlinkDelta())
				c.UplinkTotal += ev.GetUplinkDelta()
				c.DownlinkTotal += ev.GetDownlinkDelta()
			}
		}
	}
}

// perSecond turns a per-interval delta into a rate.
func (t *connTable) perSecond(delta int64) int64 {
	return int64(float64(delta) * float64(time.Second) / float64(t.interval))
}

type connJSON struct {
	ID          string `json:"id"`
	Host        string `json:"host"`
	Destination string `json:"destination"`
	Network     string `json:"network"`
	Status      string `json:"status"`
	Inbound     string `json:"inbound"`
	Outbound    string `json:"outbound"`
	Chain       string `json:"chain"`
	Route       string `json:"route"`
	Rule        string `json:"rule"`
	Process     string `json:"process"`
	UpRate      string `json:"upRate"`
	DownRate    string `json:"downRate"`
	UpTotal     string `json:"upTotal"`
	DownTotal   string `json:"downTotal"`
	Upload      int64  `json:"upload"`
	Download    int64  `json:"download"`
	CreatedAt   int64  `json:"createdAt"`
}

// snapshot returns live connections, newest first, in the shape the panel renders.
func (t *connTable) snapshot() []connJSON {
	conns := make([]*daemonpb.Connection, 0, len(t.conns))
	for _, c := range t.conns {
		conns = append(conns, c)
	}
	sort.Slice(conns, func(i, j int) bool {
		if conns[i].GetCreatedAt() != conns[j].GetCreatedAt() {
			return conns[i].GetCreatedAt() > conns[j].GetCreatedAt()
		}
		return conns[i].GetId() < conns[j].GetId()
	})
	list := make([]connJSON, 0, len(conns))
	for _, c := range conns {
		list = append(list, connToJSON(c))
	}
	return list
}

func connToJSON(c *daemonpb.Connection) connJSON {
	host := c.GetDomain()
	if host == "" {
		host = c.GetDestination()
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
	}
	inbound := c.GetInboundType()
	if c.GetInbound() != "" && c.GetInbound() != inbound {
		inbound = inbound + "/" + c.GetInbound()
	}
	chain := c.GetChainList()
	route := c.GetOutbound()
	if len(chain) > 0 {
		route = chain[0]
	}
	if route == "" {
		route = "direct"
	}
	chainText := strings.Join(chain, " / ")
	if chainText == "" {
		chainText = c.GetOutbound()
	}
	process := ""
	if p := c.GetProcessInfo(); p != nil {
		process = p.GetProcessPath()
	}
	return connJSON{
		ID:          c.GetId(),
		Host:        host,
		Destination: c.GetDestination(),
		Network:     strings.ToUpper(c.GetNetwork()),
		Status:      "Active",
		Inbound:     inbound,
		Outbound:    c.GetOutbound(),
		Chain:       chainText,
		Route:       route,
		Rule:        c.GetRule(),
		Process:     process,
		UpRate:      "↑ " + formatBytes(c.GetUplink()) + "/s",
		DownRate:    "↓ " + formatBytes(c.GetDownlink()) + "/s",
		UpTotal:     "↑ " + formatBytes(c.GetUplinkTotal()),
		DownTotal:   "↓ " + formatBytes(c.GetDownlinkTotal()),
		Upload:      c.GetUplinkTotal(),
		Download:    c.GetDownlinkTotal(),
		CreatedAt:   c.GetCreatedAt(),
	}
}
