#!/usr/bin/env bash
# Generate Go code for the sing-box daemon API from proto/ into agent/internal/daemonpb.
#
# The upstream go_package points at github.com/sagernet/sing-box/daemon; the M
# options remap every file to our own package so the agent does not depend on
# the sing-box module. Message and RPC names are unchanged, so the wire format
# stays compatible with upstream.
#
# Requires protoc, protoc-gen-go and protoc-gen-go-grpc on PATH:
#   go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11
#   go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.0
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
module="github.com/cheebun/omarchy-plugin-sbdbar/agent"
pkg="$module/internal/daemonpb"

cd "$root/proto"
files=(sing-box/daemon/*.proto)

m_opts=()
for f in "${files[@]}"; do
  m_opts+=("--go_opt=M$f=$pkg;daemonpb" "--go-grpc_opt=M$f=$pkg;daemonpb")
done

rm -f "$root"/agent/internal/daemonpb/*.pb.go
protoc -I . \
  --go_out="$root/agent" --go_opt=module="$module" \
  --go-grpc_out="$root/agent" --go-grpc_opt=module="$module" \
  "${m_opts[@]}" \
  "${files[@]}"
