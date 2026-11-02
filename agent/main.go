// sbdbar-agent is the plugin's only backend. It talks to the sing-box daemon
// gRPC API (sing-box 1.14+, services type "api") and to the plugin config file.
//
// Streams write one JSON object per line until killed, for QML's SplitParser:
//
//	watch [--interval 2s]        hello, status, groups, mode lines
//	connections [--interval 1s]  connections snapshots
//	logs [--level info]          logs batches (reset: true replaces the list)
//
// Every stream may also write {"type":"offline",...} and then reconnects.
//
// One-shot commands print a single JSON object:
//
//	select <group> <node> | urltest [group] | set-mode <mode> | close <id> | close-all
//	get-config | save-config [--url URL] [--traffic bool] | set-traffic <bool>
//	set-pref <groupsView|ipProvider|stunServer> <value>
//	ip [--provider ip.sb|ipwho.is|ipapi.is]   public egress IP over HTTP
//	stun [--server host:port] [--outbound tag]  STUN test via sing-box; one line per phase
//	                                             (QML always passes --outbound direct; flag kept for manual use)
//
// The daemon URL comes from --url, then BOX_API_URL, then the config file;
// the secret from BOX_API_SECRET, then the config file.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	global := flag.NewFlagSet("sbdbar-agent", flag.ExitOnError)
	flagURL := global.String("url", "", "sing-box daemon API URL")
	global.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: sbdbar-agent [--url URL] <watch|connections|logs|select|urltest|set-mode|close|close-all|ip|stun|get-config|save-config|set-traffic|set-pref> [args]")
	}
	_ = global.Parse(os.Args[1:])
	if global.NArg() == 0 {
		global.Usage()
		os.Exit(2)
	}
	cmd, args := global.Arg(0), global.Args()[1:]
	out := &lineWriter{w: os.Stdout}

	switch cmd {
	case "watch", "connections", "logs":
		runStream(out, *flagURL, cmd, args)
	case "select", "urltest", "set-mode", "close", "close-all":
		daemonURL, secret := resolveEndpoint(*flagURL)
		out.emit(runAction(daemonURL, secret, cmd, args))
	case "get-config":
		out.emit(loadConfig())
	case "save-config":
		fs := flag.NewFlagSet("save-config", flag.ExitOnError)
		u := fs.String("url", "", "daemon API URL")
		traffic := fs.String("traffic", "", "show traffic in the bar (true/false)")
		_ = fs.Parse(args)
		cfg := loadConfig()
		if *u != "" {
			cfg.URL = *u
		}
		if *traffic != "" {
			cfg.ShowTraffic = parseBool(*traffic)
		}
		// The secret travels via the environment so it never shows up in ps.
		if secret, ok := os.LookupEnv("BOX_API_SECRET"); ok {
			cfg.Password = secret
		}
		writeConfig(out, cfg)
	case "set-traffic":
		cfg := loadConfig()
		cfg.ShowTraffic = len(args) == 0 || parseBool(args[0])
		writeConfig(out, cfg)
	case "set-pref":
		cfg := loadConfig()
		if len(args) != 2 {
			out.emit(map[string]any{"success": false, "error": "usage: set-pref <key> <value>"})
			os.Exit(2)
		}
		if err := setPref(&cfg, args[0], args[1]); err != nil {
			out.emit(map[string]any{"success": false, "error": err.Error()})
			os.Exit(2)
		}
		writeConfig(out, cfg)
	case "ip":
		fs := flag.NewFlagSet("ip", flag.ExitOnError)
		provider := fs.String("provider", "", "ip.sb, ipwho.is or ipapi.is (default: config)")
		_ = fs.Parse(args)
		if *provider == "" {
			*provider = loadConfig().IPProvider
		}
		out.emit(runIP(*provider))
	case "stun":
		cfg := loadConfig()
		fs := flag.NewFlagSet("stun", flag.ExitOnError)
		server := fs.String("server", cfg.STUNServer, "STUN server host:port")
		outbound := fs.String("outbound", "direct", "outbound tag (empty: default outbound)")
		_ = fs.Parse(args)
		daemonURL, secret := resolveEndpoint(*flagURL)
		runSTUN(out, daemonURL, secret, *server, *outbound)
	default:
		global.Usage()
		os.Exit(2)
	}
}

func runStream(out *lineWriter, flagURL, cmd string, args []string) {
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	interval := fs.Duration("interval", time.Second, "push interval")
	level := fs.String("level", "info", "minimum log level")
	_ = fs.Parse(args)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	daemonURL, secret := resolveEndpoint(flagURL)

	switch cmd {
	case "watch":
		stream(ctx, out, daemonURL, secret, watchSession(out, *interval))
	case "connections":
		stream(ctx, out, daemonURL, secret, connectionsSession(out, *interval))
	case "logs":
		lvl, ok := parseLogLevel(*level)
		if !ok {
			fmt.Fprintf(os.Stderr, "unknown log level %q\n", *level)
			os.Exit(2)
		}
		stream(ctx, out, daemonURL, secret, logsSession(out, lvl))
	}
}

func writeConfig(out *lineWriter, cfg Config) {
	if err := saveConfig(cfg); err != nil {
		out.emit(map[string]any{"success": false, "error": err.Error()})
		os.Exit(1)
	}
	out.emit(cfg)
}

func parseBool(s string) bool {
	switch s {
	case "1", "yes", "on":
		return true
	}
	b, _ := strconv.ParseBool(s)
	return b
}
