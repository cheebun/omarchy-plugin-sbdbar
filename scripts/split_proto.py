#!/usr/bin/env python3
"""Split upstream sing-box started_service.proto into per-domain files. See docs/proto-split.md."""
import re, sys, os
src, outdir = sys.argv[1], sys.argv[2]
text = open(src).read()
lines = text.split('\n')

DOMAINS = [
    ('status', ['Version', 'ServiceStatus', 'SubscribeStatusRequest', 'Status', 'StartedAt', 'DeprecatedWarnings', 'DeprecatedWarning']),
    ('log', ['LogLevel', 'Log', 'DefaultLogLevel']),
    ('outbound', ['Groups', 'Group', 'GroupItem', 'OutboundList', 'URLTestRequest', 'SelectOutboundRequest', 'SetGroupExpandRequest']),
    ('clash_mode', ['ClashMode', 'ClashModeStatus']),
    ('connection', ['SubscribeConnectionsRequest', 'ConnectionEventType', 'ConnectionEvent', 'ConnectionEvents', 'Connection', 'ProcessInfo', 'CloseConnectionRequest']),
    ('diagnostics', ['NetworkQualityTestRequest', 'NetworkQualityTestProgress', 'STUNTestRequest', 'STUNTestProgress']),
]
PREFIX = [
    ('taildrop', lambda n: 'Taildrop' in n),
    ('tailscale', lambda n: 'Tailscale' in n),
    ('usb', lambda n: n.startswith('USB')),
    ('openconnect', lambda n: n.startswith('OpenConnect')),
    ('openvpn', lambda n: n.startswith('OpenVPN')),
    ('notification', lambda n: n.startswith('Notification')),
]
ORDER = [d for d, _ in DOMAINS] + [d for d, _ in PREFIX]

def domain_of(name):
    for d, names in DOMAINS:
        if name in names:
            return d
    for d, f in PREFIX:
        if f(name):
            return d
    raise SystemExit(f'unassigned: {name}')

# collect top-level blocks verbatim, in source order
blocks, service, cur, depth = [], None, None, 0
for l in lines:
    if depth == 0:
        m = re.match(r'^(message|enum|service)\s+(\w+)', l)
        if m:
            cur = [m.group(1), m.group(2), []]
    if cur is not None:
        cur[2].append(l)
    depth += l.count('{') - l.count('}')
    if depth == 0 and cur is not None:
        if cur[0] == 'service':
            service = cur
        else:
            blocks.append(cur)
        cur = None

names = {b[1] for b in blocks}
dom = {b[1]: domain_of(b[1]) for b in blocks}

def refs(body):
    return {r for r in re.findall(r'\b([A-Z]\w*)\b', '\n'.join(body)) if r in names}

HEADER = 'syntax = "proto3";\n\npackage daemon;\noption go_package = "github.com/sagernet/sing-box/daemon";\n'

def write(fname, imports, bodies):
    out = HEADER
    if imports:
        out += '\n' + ''.join(f'import "{i}";\n' for i in imports)
    out += '\n' + '\n\n'.join('\n'.join(b) for b in bodies) + '\n'
    with open(os.path.join(outdir, fname), 'w') as f:
        f.write(out)

for d in ORDER:
    bs = [b for b in blocks if dom[b[1]] == d]
    deps = set()
    for b in bs:
        deps |= {dom[r] for r in refs(b[2][1:])} - {d}
    imps = [f'sing-box/daemon/{x}.proto' for x in ORDER if x in deps]
    if any('google.protobuf.Empty' in '\n'.join(b[2]) for b in bs):
        imps.insert(0, 'google/protobuf/empty.proto')
    write(f'{d}.proto', imps, [b[2] for b in bs])
    print(d, len(bs), imps)

svc_deps = {dom[r] for r in refs(service[2])}
imps = ['google/protobuf/empty.proto'] + [f'sing-box/daemon/{x}.proto' for x in ORDER if x in svc_deps]
write('started_service.proto', imps, [service[2]])
print('service imports', len(imps))
