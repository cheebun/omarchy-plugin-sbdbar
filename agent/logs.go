package main

import (
	"context"
	"regexp"
	"strings"

	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

func logsSession(out *lineWriter, level daemonpb.LogLevel) func(context.Context, daemonpb.StartedServiceClient) (bool, error) {
	return func(ctx context.Context, client daemonpb.StartedServiceClient) (bool, error) {
		st, err := client.SubscribeLog(ctx, &emptypb.Empty{})
		if err != nil {
			return false, err
		}
		delivered := false
		for {
			l, err := st.Recv()
			if err != nil {
				return delivered, err
			}
			delivered = true
			entries := filterLogs(l.GetMessages(), level)
			// The first batch replays the daemon's whole buffer; the panel only shows the tail.
			if len(entries) > maxLogEntries {
				entries = entries[len(entries)-maxLogEntries:]
			}
			if len(entries) == 0 && !l.GetReset_() {
				continue
			}
			out.emit(map[string]any{"type": "logs", "online": true, "reset": l.GetReset_(), "entries": entries})
		}
	}
}

const maxLogEntries = 300

var (
	ansiRe    = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	logLineRe = regexp.MustCompile(`^[A-Z]+\[([0-9]+)\]\s*(.*)$`)
)

// logJSON matches the old Python output: raw keeps sing-box's ANSI colors for
// rendering, message is the plain text after the "LEVEL[seq]" prefix for search.
type logJSON struct {
	Level   string `json:"level"`
	Seq     string `json:"seq"`
	Message string `json:"message"`
	Raw     string `json:"raw"`
}

// filterLogs keeps messages at or above the requested severity (PANIC=0 is most severe).
func filterLogs(msgs []*daemonpb.Log_Message, level daemonpb.LogLevel) []logJSON {
	entries := make([]logJSON, 0, len(msgs))
	for _, m := range msgs {
		if m.GetLevel() > level {
			continue
		}
		raw := strings.TrimRight(m.GetMessage(), "\n")
		entry := logJSON{Level: strings.ToLower(m.GetLevel().String()), Message: ansiRe.ReplaceAllString(raw, ""), Raw: raw}
		if sm := logLineRe.FindStringSubmatch(entry.Message); sm != nil {
			entry.Seq, entry.Message = sm[1], sm[2]
		}
		entries = append(entries, entry)
	}
	return entries
}

func parseLogLevel(s string) (daemonpb.LogLevel, bool) {
	v, ok := daemonpb.LogLevel_value[strings.ToUpper(strings.TrimSpace(s))]
	return daemonpb.LogLevel(v), ok
}
