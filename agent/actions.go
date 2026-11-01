package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

// runAction performs one RPC and returns the JSON result the panel expects.
func runAction(daemonURL, secret, name string, args []string) map[string]any {
	conn, client, err := dial(daemonURL, secret)
	if err != nil {
		return failure(err)
	}
	defer conn.Close()

	timeout := 5 * time.Second
	if name == "urltest" {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	switch name {
	case "select":
		if len(args) < 2 {
			return failure(errors.New("usage: select <group> <node>"))
		}
		_, err = client.SelectOutbound(ctx, &daemonpb.SelectOutboundRequest{GroupTag: args[0], OutboundTag: args[1]})
	case "set-mode":
		if len(args) < 1 {
			return failure(errors.New("usage: set-mode <mode>"))
		}
		err = setMode(ctx, client, args[0])
		if err == nil {
			return map[string]any{"success": true, "mode": args[0]}
		}
	case "urltest":
		if len(args) > 0 && args[0] != "" {
			_, err = client.URLTest(ctx, &daemonpb.URLTestRequest{OutboundTag: args[0]})
		} else {
			err = urlTestAll(ctx, client)
		}
	case "close":
		if len(args) < 1 {
			return failure(errors.New("usage: close <id>"))
		}
		_, err = client.CloseConnection(ctx, &daemonpb.CloseConnectionRequest{Id: args[0]})
	case "close-all":
		_, err = client.CloseAllConnections(ctx, &emptypb.Empty{})
	default:
		return failure(fmt.Errorf("unknown action %q", name))
	}
	if err != nil {
		return failure(err)
	}
	return map[string]any{"success": true}
}

// setMode matches the requested mode case-insensitively against the daemon's
// list, so "global" from the UI selects a mode configured as "Global".
func setMode(ctx context.Context, client daemonpb.StartedServiceClient, mode string) error {
	st, err := client.GetClashModeStatus(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	for _, m := range st.GetModeList() {
		if strings.EqualFold(m, mode) {
			_, err = client.SetClashMode(ctx, &daemonpb.ClashMode{Mode: m})
			return err
		}
	}
	return fmt.Errorf("mode %q not available; add a clash_mode rule for it in the sing-box config", mode)
}

// urlTestAll tests every group concurrently; the first Groups message is the current set.
func urlTestAll(ctx context.Context, client daemonpb.StartedServiceClient) error {
	gctx, gcancel := context.WithCancel(ctx)
	st, err := client.SubscribeGroups(gctx, &emptypb.Empty{})
	if err != nil {
		gcancel()
		return err
	}
	groups, err := st.Recv()
	gcancel()
	if err != nil {
		return err
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failed []string
	for _, g := range groups.GetGroup() {
		wg.Add(1)
		go func(tag string) {
			defer wg.Done()
			if _, err := client.URLTest(ctx, &daemonpb.URLTestRequest{OutboundTag: tag}); err != nil {
				mu.Lock()
				failed = append(failed, tag)
				mu.Unlock()
			}
		}(g.GetTag())
	}
	wg.Wait()
	if len(failed) > 0 {
		return fmt.Errorf("URL test failed for: %s", strings.Join(failed, ", "))
	}
	return nil
}

func failure(err error) map[string]any {
	return map[string]any{"success": false, "status": statusCode(err), "error": errorMessage(err)}
}
