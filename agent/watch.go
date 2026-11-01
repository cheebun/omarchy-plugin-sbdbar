package main

import (
	"bytes"
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

// watchSession streams everything the bar and the overview/groups tabs need:
// version, status, groups and clash mode. Any stream failing ends the session
// so they reconnect together.
func watchSession(out *lineWriter, interval time.Duration) func(context.Context, daemonpb.StartedServiceClient) (bool, error) {
	return func(parent context.Context, client daemonpb.StartedServiceClient) (bool, error) {
		ctx, cancel := context.WithCancel(parent)
		defer cancel()

		rctx, rcancel := context.WithTimeout(ctx, 3*time.Second)
		ver, err := client.GetVersion(rctx, &emptypb.Empty{})
		if err != nil {
			rcancel()
			return false, err
		}
		modeStatus, err := client.GetClashModeStatus(rctx, &emptypb.Empty{})
		if err != nil {
			rcancel()
			return false, err
		}
		var startedAt time.Time
		if s, err := client.GetStartedAt(rctx, &emptypb.Empty{}); err == nil && s.GetStartedAt() > 0 {
			startedAt = time.UnixMilli(s.GetStartedAt())
		}
		rcancel()

		out.emit(map[string]any{"type": "hello", "version": ver.GetVersion(), "apiVersion": ver.GetApiVersion()})
		modeList := modeStatus.GetModeList()
		out.emit(modeLine(modeStatus.GetCurrentMode(), modeList))

		var delivered atomic.Bool
		var once sync.Once
		var firstErr error
		fail := func(err error) {
			once.Do(func() { firstErr = err; cancel() })
		}
		var wg sync.WaitGroup
		wg.Add(3)

		go func() {
			defer wg.Done()
			st, err := client.SubscribeStatus(ctx, &daemonpb.SubscribeStatusRequest{Interval: int64(interval)})
			if err != nil {
				fail(err)
				return
			}
			for {
				s, err := st.Recv()
				if err != nil {
					fail(err)
					return
				}
				delivered.Store(true)
				out.emit(statusLine(s, startedAt))
			}
		}()

		go func() {
			defer wg.Done()
			st, err := client.SubscribeGroups(ctx, &emptypb.Empty{})
			if err != nil {
				fail(err)
				return
			}
			// During a URL test the daemon pushes every 250ms, often unchanged; skip repeats.
			var last []byte
			for {
				g, err := st.Recv()
				if err != nil {
					fail(err)
					return
				}
				line := groupsLine(g)
				b, _ := json.Marshal(line)
				if bytes.Equal(b, last) {
					continue
				}
				last = b
				out.emit(line)
			}
		}()

		go func() {
			defer wg.Done()
			st, err := client.SubscribeClashMode(ctx, &emptypb.Empty{})
			if err != nil {
				fail(err)
				return
			}
			for {
				m, err := st.Recv()
				if err != nil {
					fail(err)
					return
				}
				out.emit(modeLine(m.GetMode(), modeList))
			}
		}()

		wg.Wait()
		return delivered.Load(), firstErr
	}
}

// statusLine keeps the field names the QML side has always used.
func statusLine(s *daemonpb.Status, startedAt time.Time) map[string]any {
	line := map[string]any{
		"type":             "status",
		"online":           true,
		"apiType":          "daemon-grpc",
		"memory":           s.GetMemory(),
		"goroutines":       s.GetGoroutines(),
		"connectionsIn":    s.GetConnectionsIn(),
		"connectionsOut":   s.GetConnectionsOut(),
		"connectionsCount": s.GetConnectionsOut(),
		"trafficAvailable": s.GetTrafficAvailable(),
		"uploadRate":       s.GetUplink(),
		"downloadRate":     s.GetDownlink(),
		"uploadTotal":      s.GetUplinkTotal(),
		"downloadTotal":    s.GetDownlinkTotal(),
		"uptime":           "",
	}
	if !startedAt.IsZero() {
		line["uptime"] = formatDuration(time.Since(startedAt))
	}
	return line
}

type groupItemJSON struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Delay int32  `json:"delay"`
}

type groupJSON struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Selected   string          `json:"selected"`
	Selectable bool            `json:"selectable"`
	Items      []groupItemJSON `json:"items"`
}

func groupsLine(g *daemonpb.Groups) map[string]any {
	groups := make([]groupJSON, 0, len(g.GetGroup()))
	activeNode := ""
	for _, grp := range g.GetGroup() {
		items := make([]groupItemJSON, 0, len(grp.GetItems()))
		for _, it := range grp.GetItems() {
			items = append(items, groupItemJSON{Name: it.GetTag(), Type: it.GetType(), Delay: it.GetUrlTestDelay()})
		}
		groups = append(groups, groupJSON{
			Name:       grp.GetTag(),
			Type:       grp.GetType(),
			Selected:   grp.GetSelected(),
			Selectable: grp.GetSelectable(),
			Items:      items,
		})
		if activeNode == "" {
			activeNode = grp.GetSelected()
		}
	}
	return map[string]any{"type": "groups", "groups": groups, "activeNode": activeNode}
}

func modeLine(mode string, modeList []string) map[string]any {
	if modeList == nil {
		modeList = []string{}
	}
	return map[string]any{"type": "mode", "mode": mode, "modeList": modeList}
}
