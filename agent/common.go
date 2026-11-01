package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"github.com/cheebun/omarchy-plugin-sbdbar/agent/internal/daemonpb"
)

// errConfig marks errors that retrying cannot fix; streams exit with code 2 on them.
var errConfig = errors.New("config error")

func dial(daemonURL, secret string) (*grpc.ClientConn, daemonpb.StartedServiceClient, error) {
	target, err := grpcTarget(daemonURL, secret)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %v", errConfig, err)
	}
	conn, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithPerRPCCredentials(bearer(secret)),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %v", errConfig, err)
	}
	return conn, daemonpb.NewStartedServiceClient(conn), nil
}

// grpcTarget turns http://host:port into host:port. It refuses to send a
// secret over cleartext to a non-loopback host; TLS is not supported yet.
func grpcTarget(raw, secret string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		raw = defaultURL
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if u.Scheme != "http" {
		return "", fmt.Errorf("unsupported scheme %q: only http (h2c) is supported", u.Scheme)
	}
	if u.Host == "" {
		return "", fmt.Errorf("missing host in %q", raw)
	}
	if secret != "" && !isLoopback(u.Hostname()) {
		return "", fmt.Errorf("insecure transport rejected: refusing to send API secret over cleartext to non-loopback host %q", u.Hostname())
	}
	return u.Host, nil
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// bearer sends the secret as "authorization: Bearer <secret>" metadata.
type bearer string

func (b bearer) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	if b == "" {
		return nil, nil
	}
	return map[string]string{"authorization": "Bearer " + string(b)}, nil
}

func (bearer) RequireTransportSecurity() bool { return false }

// statusCode maps gRPC errors onto the HTTP-like codes the QML side checks.
func statusCode(err error) int {
	switch status.Code(err) {
	case codes.Unauthenticated, codes.PermissionDenied:
		return 401
	case codes.Unavailable, codes.DeadlineExceeded, codes.Canceled:
		return 0
	}
	return 500
}

func errorMessage(err error) string {
	if st, ok := status.FromError(err); ok {
		return st.Message()
	}
	return err.Error()
}

func offline(err error) map[string]any {
	return map[string]any{"type": "offline", "online": false, "status": statusCode(err), "error": errorMessage(err)}
}

// lineWriter serializes JSON lines so a line is never interleaved.
type lineWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lineWriter) emit(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := l.w.Write(append(b, '\n')); err != nil {
		// stdout is gone (reader exited); nothing left to serve.
		os.Exit(0)
	}
}

// stream runs session until ctx ends, reconnecting with exponential backoff
// and reporting each failure as an offline line. The backoff resets once a
// session delivered data. Config errors end the stream with exit code 2.
func stream(ctx context.Context, out *lineWriter, daemonURL, secret string, session func(context.Context, daemonpb.StartedServiceClient) (bool, error)) {
	watchParent()
	conn, client, err := dial(daemonURL, secret)
	if err != nil {
		out.emit(offline(err))
		os.Exit(2)
	}
	defer conn.Close()

	backoff := time.Second
	for ctx.Err() == nil {
		delivered, err := session(ctx, client)
		if ctx.Err() != nil {
			return
		}
		if err == nil {
			err = errors.New("stream closed by daemon")
		}
		out.emit(offline(err))
		if delivered {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}

// watchParent ends the agent when the process that started it goes away, so a
// crashed shell does not leave it running.
func watchParent() {
	ppid := os.Getppid()
	_, _, _ = syscall.RawSyscall(syscall.SYS_PRCTL, syscall.PR_SET_PDEATHSIG, uintptr(syscall.SIGTERM), 0)
	// PDEATHSIG fires on the parent thread's exit, not the process's; poll as a backstop.
	go func() {
		for range time.Tick(2 * time.Second) {
			if os.Getppid() != ppid {
				os.Exit(0)
			}
		}
	}()
}

func formatBytes(b int64) string {
	if b <= 0 {
		return "0 B"
	}
	units := []string{"B", "KB", "MB", "GB", "TB"}
	val := float64(b)
	i := 0
	for val >= 1024 && i < len(units)-1 {
		val /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f B", val)
	}
	return fmt.Sprintf("%.1f %s", val, units[i])
}

func formatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	d = d.Truncate(time.Second)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	switch {
	case h > 0:
		return fmt.Sprintf("%dh%dm%ds", h, m, s)
	case m > 0:
		return fmt.Sprintf("%dm%ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}
