# n8n Assistant sandbox on Synology DSM

Notes for running the n8n Assistant code sandbox (`sandbox-api` plus the
Docker-in-Docker `sandbox-runner-1`) on a Synology NAS. n8n publishes no
Synology guidance. Their Compose guide assumes a mainstream Linux kernel.
DSM's kernel is missing five things the sandbox expects, and each one fails
in a different place with a different message.

Plain n8n, the task runners, Postgres and Browserless need none of this.
Only the sandbox does.

## Tested on

| Item | Value |
|---|---|
| NAS | Synology DS720+, Celeron J4125, 9.8 GB RAM |
| Kernel | `4.4.302+ #86009 SMP Wed Nov 26 18:19:17 CST 2025 x86_64` |
| Host Docker storage | btrfs |
| n8n | 2.38.1 |
| Sandbox service (api, runner, sandbox image) | 1.4.0 |
| Inner Docker daemon | 29.3.1 |
| Verified | 20 Sep 2026 |

Verified result: the Assistant ran `uname -a && id && python3 -c ...` in a
sandbox. Output showed the DSM kernel, `uid=1000(user)`, exit code 0.

## The five kernel gaps

They appear in this order. Fixing one reveals the next.

### 1. Bridge netfilter sysctl is not visible in a container

Symptom: the runner crash-loops. Its log repeats:

```
Error response from daemon: cannot restrict inter-container communication or run without the userland proxy: stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file or directory: set environment variable DOCKER_IGNORE_BR_NETFILTER_ERROR=1 to ignore
```

Cause: DSM does not expose `/proc/sys/net/bridge` inside a container that
has its own network namespace.

Fix, on `sandbox-runner-1`:

```yaml
DOCKER_IGNORE_BR_NETFILTER_ERROR: "1"
```

Cost: none, as far as testing shows. The daemon warns "cannot restrict
inter-container communication", which reads like a loss of isolation. It is
not one here. Two containers on `runner-bridge` could not reach each other
in testing (TCP connect to port 8000, timed out), and the rule responsible
is present and being hit:

```
-A DOCKER-FORWARD -i runner-bridge -o runner-bridge -j DROP
```

The reason: on kernel 4.4 the `bridge-nf-*` sysctls are not
network-namespaced, so the host's setting applies everywhere. The host reads
`1` for `/proc/sys/net/bridge/bridge-nf-call-iptables`, bridged traffic goes
through iptables globally, and the inner daemon simply could not read the
file to confirm what was already true. The flag suppressed a verification
check, not the behaviour.

Do not carry this conclusion to a newer kernel. Sysctl namespacing arrived
well after 4.4, and on a host that has it the same flag would cost real
isolation. Test it there before relying on it.

Tried and rejected: `modprobe br_netfilter` on the host at boot. The module
loads and changes nothing the container can see, because the visibility is
the problem, not the module.

### 2. No overlayfs module

Symptom: the image pulls and the daemon starts, then every container create
fails with `fstype: overlay ... no such device`.

Cause: `modprobe overlay` returns "Module overlay not found". The host Docker
uses btrfs for the same reason.

Fix: give the inner daemon its own volume and the btrfs driver.

```yaml
environment:
  DOCKER_DRIVER: btrfs
volumes:
  - sandbox-docker:/var/lib/docker
```

Confirm in the inner daemon log:
`containerd-snapshotter=false storage-driver=btrfs`.

Alternative if a later inner Docker version ignores `DOCKER_DRIVER`: the
runner's start script supports `SANDBOX_RUNNER_DOCKER_STORAGE_DRIVER: btrfs`,
which writes a `daemon.json` with the driver and the containerd snapshotter
disabled. Not needed on 29.3.1.

### 3. No `raw` iptables table

Symptom: containers cannot join a bridge network. The daemon fails while
creating the endpoint. A test container on `runner-bridge`:

```bash
sudo docker exec sandbox-runner-1 docker run --rm \
  --network runner-bridge --user 1000:1000 \
  ghcr.io/n8n-io/n8n-sandbox-service-sandbox:1.4.0 true
```

```
docker: Error response from daemon: failed to set up container networking: failed to create endpoint naughty_hellman on network runner-bridge: Unable to enable DIRECT ACCESS FILTERING - DROP rule:  (iptables failed: iptables --wait -t raw -A PREROUTING -d 172.18.0.2 ! -i runner-bridge -j DROP: iptables v1.8.11 (legacy): can't initialize iptables table `raw': Table does not exist (do you need to insmod?)
Perhaps iptables or your kernel needs to be upgraded.
 (exit status 3))
```

Cause: `iptable_raw` is compiled out of the kernel. `filter`, `nat` and
`mangle` exist. Since Docker 28 the daemon writes `raw` table rules for each
bridge endpoint.

This is why nothing else on the NAS is affected. DSM ships Docker 24.0.2, which
predates those rules, so the host daemon never needs the table. The runner's
inner daemon is 29.3.1 and does.

Fix, on `sandbox-runner-1`. Needs inner Docker 28.0.2 or later:

```yaml
DOCKER_INSECURE_NO_IPTABLES_RAW: "1"
```

This works because `start-runner.sh` launches `dockerd` as a child process,
so the daemon inherits the container's environment. The script has no other
hook for daemon flags.

Cost: only the `raw` rules are skipped. Those rules stop hosts on the
daemon's own network from routing straight to container IPs. Here that
network is `sandbox-net`, where only n8n and `sandbox-api` live, and
sandboxes publish no ports.

Confirm in the inner daemon log:
`WARNING: DOCKER_INSECURE_NO_IPTABLES_RAW is set`.

### 4. No CPU CFS scheduler, no pids controller

Symptom: n8n's "Add a code sandbox" dialog says the service could not be
reached. The real error is in the `sandbox-api` log:
`NanoCPUs can not be set, as your kernel does not support CPU CFS scheduler`.

Cause: the runner creates every sandbox with
`--memory 512m --cpus 1.00 --pids-limit 256`. This kernel rejects `--cpus`.
The same gap makes Compose reject `cpus:` on any service.

Fix, on `sandbox-runner-1`:

```yaml
environment:
  SANDBOX_RUNNER_ENABLE_CGROUPS: "false"
mem_limit: 2g
```

Cost: this removes the CPU, memory and process limits together. The
`mem_limit` on the runner service is the only ceiling left. There is no way
to cap sandbox CPU on this kernel.

The pids cgroup controller is missing too: `/sys/fs/cgroup/pids` does not
exist, and `docker stats` reports `PIDS 0` for the runner while it runs at
least five processes. Nothing limits process count in a sandbox. A fork bomb
is stopped only by the memory ceiling.

Tried and rejected: `SANDBOX_RUNNER_DEFAULT_CPU_PERCENT: "0"`. The runner
exits with "must be a positive integer" and crash-loops. While it loops, the
API reports "no eligible runners".

Verified: the inner sandboxes count against `mem_limit`. A sandbox that
allocated 400 MB and slept 30 seconds moved the runner's `docker stats`
figure from 221 MiB to 627 MiB and back to 228 MiB. The runner itself
(dockerd, containerd, sandbox-runner) idles at about 220 MiB, so sandboxes
share roughly 1.8 GB.

When the ceiling is hit, the kernel's OOM killer picks the largest process
in the runner's cgroup. That is normally the sandbox workload. Nothing
guarantees it is not the inner dockerd, in which case the runner restarts
and n8n gets a fresh sandbox.

### 5. No seccomp

Symptom: a warning on every sandbox start: "seccomp is not enabled in your
kernel, running container without default profile".

No fix. Sandboxes run without a syscall filter.

## Harmless noise in the inner daemon log

- `nft: executable file not found`. The daemon uses the iptables backend.
- `ip6tables ... table nat does not exist`. Sandboxes are IPv4 only.
- `No blkio throttle ... support`. No disk I/O limits.
- `Failed to delete conntrack state`. Cosmetic.
- `cgroup v1 is deprecated`. Removal is planned for 2029 at the earliest.

## Because there are no per-sandbox limits

One runner setting matters more here than on a normal host. It goes under
`sandbox-runner-1` → `environment`.

```yaml
# Default 1000. With no per-sandbox limits, this is the only cap on how many
# sandboxes can exist at once. The docs call it "reported capacity for
# placement", so treat it as a backstop behind mem_limit, not a hard refusal.
# Not lower than 4: the n8n settings dialog creates one sandbox for its check
# and each Assistant chat appears to get its own, so one person can hold
# three at once. Below that, a new chat fails with "no eligible runners".
SANDBOX_RUNNER_CAPACITY_TOTAL: "4"
```

Leave `SANDBOX_RUNNER_IDLE_TTL_SECONDS` at its default of 3600. An idle
sandbox costs a few MiB (runner at 228 MiB with one alive, 221 MiB with
none). Reaping sooner saves nothing and discards the sandbox's files when a
chat is paused.

## The network controls survive, all of them

A sandbox on this host reaches the public internet and nothing else. Not the
LAN, not the router, not other Docker networks, not the host, not another
sandbox. Measured by TCP connect probe in every case, with the rule dump to
match.

The reason they survive is that the sandbox service implements them itself,
in the iptables `filter` table, rather than relying on anything the kernel is
missing. `filter` is one of the three tables this kernel has.

The measurements, the rules and the commands that reproduce them are in
[SECURITY.md](SECURITY.md), which is the authoritative place for all of it.
They are not repeated here, so there is one copy to keep correct.

Outbound internet access is deliberate: the Assistant installs packages.
Treat anything given to a sandbox as capable of leaving the network.

## What this setup does not give you

Three things are genuinely weaker than n8n's design:

- No syscall filtering (gap 5).
- No per-sandbox CPU or process limits (gap 4). Memory is capped at the
  runner, not per sandbox.
- No `raw` table hardening (gap 3).

Not on that list, and worth being clear about, because two of them looked
like losses until they were measured:

- Every network control is intact, as measured above.
- Inter-sandbox isolation is enforced despite the daemon's warning (gap 1).
- The runner running `privileged: true` is n8n's own fallback when
  `sysbox-runc` is unavailable, not something DSM forced. It still means a
  sandbox escape is root on the NAS.

Namespaces, `--cap-drop ALL`, `no-new-privileges` and the unprivileged
`1000:1000` user all apply inside each sandbox.

This is acceptable for one user on a private LAN whose own prompts drive the
Assistant. It is not acceptable for a shared or exposed instance. n8n's own
documentation positions this self-hosted sandbox for local development and
testing.

## If this stops being good enough

Move only the sandbox stack into a Debian VM under Virtual Machine Manager.
A stock kernel has all five features, so n8n's Compose guide works unchanged
and the runner can use `sysbox-runc` in place of `privileged: true`. n8n stays
on the NAS and points its sandbox Service URL at the VM. The cost is RAM and
CPU on a four-core Celeron.

## Checks

Runner registered and ready:

```bash
sudo docker logs --tail 5 sandbox-runner-1
# expect: "runner registration heartbeat sent" and "sandbox image ready"
```

Inner daemon health:

```bash
sudo docker exec sandbox-runner-1 tail -40 /var/log/dockerd.log
```

The real error behind a vague n8n message:

```bash
sudo docker logs --since 15m sandbox-api 2>&1 | grep -iE "create sandbox|error" | tail -3
```

Manual sandbox start, bypassing n8n:

```bash
sudo docker exec sandbox-runner-1 docker run --rm --network runner-bridge \
  --entrypoint sh ghcr.io/n8n-io/n8n-sandbox-service-sandbox:1.4.0 -c 'echo ok'
```

Which settings the runner binary understands:

```bash
sudo docker exec sandbox-runner-1 sh -c \
  "grep -ao 'SANDBOX_RUNNER_[A-Z_]*' /usr/local/bin/sandbox-runner | sort -u"
```

Env changes need a recreate, not a restart:

```bash
sudo docker compose up -d --force-recreate sandbox-runner-1
```

Wait about 45 seconds before using the sandbox. The inner daemon is slow to
start on this CPU and the runner registers only after it is up.

## References

- n8n Compose guide: https://docs.n8n.io/deploy/host-n8n/install-options/install-using-docker-compose
- n8n Assistant setup: https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-n8n-assistant
- Sandbox service configuration: https://github.com/n8n-io/n8n-sandbox-service/blob/main/docs/configuration.md
- Docker Engine 28 release notes (raw table opt-out, 28.0.2): https://docs.docker.com/engine/release-notes/28/
