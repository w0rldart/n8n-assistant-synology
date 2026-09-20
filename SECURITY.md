# Security status, measured

Eight controls the n8n sandbox service relies on. For each: what it is
supposed to do, whether it does it on this kernel, and the command that
establishes the answer.

Measured on a DS720+, kernel `4.4.302+`, n8n 2.38.1, sandbox service 1.4.0,
inner Docker 29.3.1, on 20 September 2026.

[`verify.sh`](verify.sh) runs all of this on your own hardware.

## Summary

| Control | Status | How it was established |
|---|---|---|
| Egress filtering | intact | TCP connect probes plus the rule dump |
| Inter-sandbox isolation | intact | TCP connect between two containers |
| Sandbox daemon ingress | intact | rule dump |
| Per-sandbox memory limit | lost, relocated | `docker stats` during an allocation |
| Per-sandbox CPU limit | lost | container create is rejected |
| Per-sandbox process limit | lost | inferred from `docker stats` |
| seccomp | lost | daemon warning at container start |
| `raw` table rules | lost | deliberately disabled to start the daemon |

## Egress filtering: intact

Sandboxes should reach the public internet and nothing on the local network.
The API records the mode as `"egress":"public"` when it creates a sandbox.

Probed from a container on `runner-bridge`, using the sandbox image, with a
four second timeout on each TCP connect:

| Target | Result |
|---|---|
| `1.1.1.1:53`, public internet | connected |
| Postgres on the host's other Docker network, no published port | timed out |
| LAN router, ports 80 and 53 | timed out |
| the NAS's own LAN address, port 7090 | timed out |

```bash
sudo docker exec sandbox-runner-1 docker run --rm --network runner-bridge \
  --entrypoint python3 ghcr.io/n8n-io/n8n-sandbox-service-sandbox:1.4.0 \
  -c "import socket; s=socket.socket(); s.settimeout(4); print(s.connect_ex(('10.0.0.1',80)))"
```

`0` means connected. With a timeout set, a silently dropped packet surfaces as
errno 11. That distinction matters: a missing route returns 101 or 113
immediately and a refusal returns 111, so a timeout is evidence of a firewall
rule rather than an unroutable address.

The rules themselves:

```bash
sudo docker exec sandbox-runner-1 iptables -t filter -S | grep N8N-SB
```

```
-A N8N-SB-BR-EGRESS -d 10.0.0.0/8 -j DROP
-A N8N-SB-BR-EGRESS -d 172.16.0.0/12 -j DROP
-A N8N-SB-BR-EGRESS -d 192.168.0.0/16 -j DROP
-A N8N-SB-BR-EGRESS -d 169.254.0.0/16 -j DROP
-A N8N-SB-BR-EGRESS -d 127.0.0.0/8 -j DROP
-A N8N-SB-BR-EGRESS -d 100.64.0.0/10 -j DROP
-A N8N-SB-BR-EGRESS -d 198.18.0.0/15 -j DROP
-A N8N-SB-BR-EGRESS -d 240.0.0.0/4 -j DROP
-A N8N-SB-BR-HOST -j DROP
```

All three RFC1918 ranges, link-local, loopback, CGNAT, benchmark and reserved
space, plus a separate chain dropping traffic to the host. These live in the
`filter` table, which is one of the three this kernel has, which is why this
control is unaffected by any of the five gaps.

Outbound internet access is deliberate: the Assistant installs packages.
Treat anything handed to a sandbox as capable of leaving the network. A
`br-no-egress` bridge with its own DROP rules also exists, so the service
supports sandboxes with no outbound at all.

## Inter-sandbox isolation: intact

The runner creates `runner-bridge` with `enable_icc=false`. The inner daemon
warns at startup that it cannot restrict inter-container communication, which
reads like the rule is not being applied. It is being applied.

```bash
# listener
sudo docker exec sandbox-runner-1 docker run -d --name icctest --network runner-bridge \
  --entrypoint python3 ghcr.io/n8n-io/n8n-sandbox-service-sandbox:1.4.0 -m http.server 8000

sudo docker exec sandbox-runner-1 docker inspect icctest \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# from a second container, substituting that address
sudo docker exec sandbox-runner-1 docker run --rm --network runner-bridge \
  --entrypoint python3 ghcr.io/n8n-io/n8n-sandbox-service-sandbox:1.4.0 \
  -c "import socket; s=socket.socket(); s.settimeout(4); print(s.connect_ex(('A.B.C.D',8000)))"

sudo docker exec sandbox-runner-1 docker rm -f icctest
```

Result: errno 11. Blocked. The rule doing it:

```
-A DOCKER-FORWARD -i runner-bridge -o runner-bridge -j DROP
```

Why it works despite the warning: on kernel 4.4 the `bridge-nf-*` sysctls are
not network-namespaced, so the host's setting applies everywhere. The host
reads `1`:

```bash
cat /proc/sys/net/bridge/bridge-nf-call-iptables
```

The inner daemon could not read that file from inside its own namespace, so it
could not verify the setting, and warned. The behaviour was never in question.
`DOCKER_IGNORE_BR_NETFILTER_ERROR=1` suppresses the check, not the enforcement.

Do not carry this conclusion to a newer kernel. Sysctl namespacing arrived
well after 4.4. On a host that has it, the same flag would cost real
isolation. `verify.sh` reports the host value so you can tell which case you
are in.

## Sandbox daemon ingress: intact

Each sandbox runs a daemon on port 8081 that handles exec and file operations.
Only the runner should reach it. Each sandbox gets its own chain:

```
-A DOCKER-USER -d 172.18.0.3/32 -p tcp -m tcp --dport 8081 -j N8N-SB-<id>-IN
-A N8N-SB-<id>-IN -s 172.18.0.1/32 ! -i runner-bridge -j ACCEPT
-A N8N-SB-<id>-IN -j DROP
```

Accept from the bridge gateway, which is the runner, and only when the traffic
did not arrive over the bridge. Drop everything else. Present and correct.

## Per-sandbox memory limit: lost, relocated to the runner

The runner normally starts each sandbox with `--memory 512m`. Turning off
cgroups to work around the CPU gap removes that along with the CPU and process
limits, because the three cannot be separated. See gap 4 in
[SYNOLOGY.md](SYNOLOGY.md).

The replacement is `mem_limit: 2g` on the runner service itself. That only
helps if the nested sandboxes count against the runner's cgroup, which had to
be established, not assumed:

```bash
# in the Assistant
python3 -c "b=bytearray(400*1024*1024); import time; time.sleep(30); print(len(b))"

# on the host, while that runs
sudo docker stats --no-stream sandbox-runner-1
```

| Moment | Runner memory |
|---|---|
| idle | 221.1 MiB |
| during a 400 MB allocation | 627.1 MiB |
| after | 228.3 MiB |

A rise of 406 MiB for a 400 MB allocation. The ceiling covers the sandboxes.

The runner's own processes idle at about 220 MiB, so sandboxes share roughly
1.8 GB. When that is exhausted, the kernel's OOM killer picks the largest
process in the cgroup, which is normally the sandbox workload. Nothing
guarantees it will not pick the inner dockerd instead, in which case the
runner restarts and n8n gets a fresh sandbox.

## Per-sandbox CPU limit: lost, no replacement

The kernel has no CPU CFS scheduler, so `--cpus` is rejected at container
create and Compose rejects `cpus:` on any service. There is no CPU control
available at any layer on this host.

Operationally this is the real risk on a four-core Celeron: a sandbox running
generated code competes with everything else on the NAS, and nothing caps it.

## Per-sandbox process limit: lost, no replacement

`--pids-limit 256` comes off with the other two. `docker stats` reports
`PIDS 0` for the runner, a container running at least five processes, which
indicates the pids cgroup controller is absent rather than merely unused.

This is an inference, not a measurement. A fork bomb inside a sandbox is
bounded by the memory ceiling and nothing else.

## seccomp: lost, no replacement

Every sandbox start logs:

```
seccomp is not enabled in your kernel, running container without default profile
```

Sandboxes run with no syscall filter. Namespaces, `--cap-drop ALL`,
`no-new-privileges` and the unprivileged `1000:1000` user still apply.

## iptables `raw` table rules: lost, deliberately

Since Docker 28 the daemon writes rules in the `raw` table for every bridge
endpoint. This kernel has `filter`, `nat` and `mangle` but not `raw`, so the
daemon cannot create bridge endpoints at all until those rules are skipped.

`DOCKER_INSECURE_NO_IPTABLES_RAW=1` skips them. Docker's own documentation
calls this not recommended for production, because it lets other hosts on the
daemon's network route directly to container addresses even when a port is
published to loopback.

The blast radius here is small. The only network involved is the one carrying
n8n and the sandbox API, sandboxes publish no ports, and the egress and
inter-sandbox controls above are unaffected because they live in `filter`.

Confirm the flag took:

```bash
sudo docker exec sandbox-runner-1 grep IPTABLES_RAW /var/log/dockerd.log
```

## What none of this addresses

The runner runs `privileged: true`. A sandbox escape is root on the NAS.

That is not a Synology compromise. n8n's own design runs the runner under
`sysbox-runc` where available and falls back to privileged where it is not,
and `sysbox-runc` is not available here. The consequence is the same either
way, and it sits above every control on this page.
