# n8n Assistant sandbox on Synology DSM

n8n's Assistant runs generated code in a sandbox: a Docker-in-Docker runner
that starts one container per session. On a mainstream Linux kernel it comes up
from n8n's own Compose guide. Synology's DSM kernel is missing five features
that setup assumes, and each one surfaces only once the previous is fixed, in a
different place and with an unrelated error message.

This repo is what it took to get it running on a DS720+, what each workaround
costs, and which of n8n's security controls still work afterwards. Every
security claim here has a command behind it. [`verify.sh`](verify.sh) runs
those commands on your hardware and prints the answers for your kernel.

**This is not a drop-in deployment.** [`compose.yaml`](compose.yaml) is the
file running on my NAS with secrets replaced. It expects an external Postgres
and a shared Docker network you will not have. Take
[the five-line delta](#the-five-line-delta), not the file.

## If you arrived from an error message

| What you saw | Where | Gap |
|---|---|---|
| `NanoCPUs can not be set, as your kernel does not support CPU CFS scheduler or the cgroup is not mounted` | `sandbox-api` log | [4](SYNOLOGY.md#4-no-cpu-cfs-scheduler-no-pids-controller) |
| `The service couldn't be reached. Check the URL and network access, then try again.` | n8n's sandbox settings dialog | [4](SYNOLOGY.md#4-no-cpu-cfs-scheduler-no-pids-controller), and see below |
| `SANDBOX_RUNNER_DEFAULT_CPU_PERCENT must be a positive integer, got "0"` | runner log, crash loop | [4](SYNOLOGY.md#4-no-cpu-cfs-scheduler-no-pids-controller) |
| `create sandbox failed: no eligible runners` | `sandbox-api` log | the runner is crash-looping; read its log |
| `cannot restrict inter-container communication or run without the userland proxy: stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file or directory` | inner `dockerd.log` | [1](SYNOLOGY.md#1-bridge-netfilter-sysctl-is-not-visible-in-a-container) |
| `Module overlay not found`, and container create failing on `fstype: overlay` | `modprobe`, inner daemon | [2](SYNOLOGY.md#2-no-overlayfs-module) |
| Inner daemon cannot create bridge endpoints | inner `dockerd.log` | [3](SYNOLOGY.md#3-no-raw-iptables-table) |
| `seccomp is not enabled in your kernel, running container without default profile` | inner `dockerd.log` | [5](SYNOLOGY.md#5-no-seccomp), no fix |

That second row is worth calling out. n8n's dialog reports a network problem
when the network is fine. The API was reached, the runner was reached, and the
inner Docker daemon refused a flag. The dialog also truncates the real message
part way through. The log is authoritative:

```bash
sudo docker logs --since 15m sandbox-api 2>&1 | grep -iE "create sandbox|error" | tail -3
```

## The five-line delta

Everything DSM-specific is these five settings on the runner service, plus one
volume and one memory ceiling. If you already run n8n, this is all you need.

```yaml
services:
  sandbox-runner-1:
    environment:
      # Gap 1: the bridge-nf sysctl is not visible inside a container's
      # network namespace on DSM. The daemon refuses to start without it.
      DOCKER_IGNORE_BR_NETFILTER_ERROR: "1"

      # Gap 2: no overlayfs module. The inner daemon's default snapshotter
      # fails at container create. btrfs matches the host filesystem.
      DOCKER_DRIVER: btrfs

      # Gap 3: no `raw` iptables table. Docker 28+ writes raw rules for every
      # bridge endpoint. Requires inner Docker 28.0.2 or later.
      DOCKER_INSECURE_NO_IPTABLES_RAW: "1"

      # Gap 4: no CPU CFS scheduler, so --cpus is rejected at container
      # create. The runner refuses CPU_PERCENT=0, so all three per-sandbox
      # limits come off together.
      SANDBOX_RUNNER_ENABLE_CGROUPS: "false"

      # With no per-sandbox cap, this is the only limit on concurrent
      # sandboxes. Do not set it below 4; see SYNOLOGY.md.
      SANDBOX_RUNNER_CAPACITY_TOTAL: "4"

    volumes:
      # Gap 2 again: the inner daemon needs its own volume, or it writes to
      # the outer container's filesystem and overlay-on-overlay fails.
      - sandbox-docker:/var/lib/docker

    # The only memory limit that exists once cgroups are off. Verified to
    # cover the sandboxes nested inside the runner.
    mem_limit: 2g
```

Environment changes need `--force-recreate`, not a restart. Allow about 45
seconds before using the sandbox; the inner daemon is slow to start and the
runner registers only after it is up.

## Verified on

| Item | Value |
|---|---|
| Hardware | Synology DS720+, Celeron J4125, 9.8 GB RAM |
| Kernel | `4.4.302+ #86009 SMP Wed Nov 26 18:19:17 CST 2025 x86_64` |
| Host Docker storage driver | btrfs |
| n8n | 2.38.1 |
| Sandbox service (api, runner, sandbox) | 1.4.0 |
| Inner Docker daemon | 29.3.1 |
| Date | 20 September 2026 |

Proof of life, run through the Assistant:

```
uname -a && id && python3 -c "print(sum(range(1000)))"

Linux sandbox 4.4.302+ #86009 SMP Wed Nov 26 18:19:17 CST 2025 x86_64 GNU/Linux
uid=1000(user) gid=1000(user) groups=1000(user)
499500
```

**Running a different model?** Run [`verify.sh`](verify.sh) and open an issue
with the output. Your kernel may lack a different set of features, and the
table above should become a list, not a single row.

## Security

Eight controls, each one measured. Full method and commands in
[SECURITY.md](SECURITY.md).

| Control | On this kernel |
|---|---|
| Egress filtering (private ranges dropped) | intact, measured |
| Inter-sandbox isolation | intact, measured |
| Sandbox daemon ingress restriction | intact, rules present |
| Per-sandbox memory limit | lost, replaced at the runner, measured |
| Per-sandbox CPU limit | lost, no replacement possible |
| Per-sandbox process limit | lost, no replacement possible |
| seccomp syscall filtering | lost, no replacement possible |
| iptables `raw` table rules | lost, small blast radius given the above |

Five of the eight hold. Two of the gaps that look like security losses are not,
and establishing that took measurement, because the reasoning pointed the other
way. [CORRECTIONS.md](CORRECTIONS.md) has those and one more.

This is acceptable for one person on a private network driving the Assistant
with their own prompts, and not acceptable for a shared or internet-exposed
instance. n8n positions this self-hosted sandbox for local development and
testing and recommends Daytona for production, which none of the work here
changes.

The runner runs `privileged: true`. That is n8n's own fallback when
`sysbox-runc` is unavailable, not something DSM forced, and it means a sandbox
escape is root on the NAS.

## This may not be a Synology problem

None of these five gaps are specific to Synology. They are properties of an
old or restricted kernel. Proxmox LXC containers hit several of them, Docker
Desktop's linuxkit kernel omits the xfs quota support, and older NAS firmware
and some ARM boards are in the same position.

Run [`verify.sh`](verify.sh) on any host. The first section needs neither
Synology nor a running stack, and tells you which of the five you have.

## Files

| File | What it is |
|---|---|
| [SYNOLOGY.md](SYNOLOGY.md) | The five gaps in the order they appear: symptom, cause, fix, cost, what was tried and rejected |
| [SECURITY.md](SECURITY.md) | Control-by-control status, each with the command that establishes it |
| [CORRECTIONS.md](CORRECTIONS.md) | Conclusions that turned out to be wrong, and what settled them |
| [verify.sh](verify.sh) | Detection and verification, prints a table |
| [compose.yaml](compose.yaml) | The running file, sanitised. Reference, not a deployment |
| [.env.example](.env.example) | The variables that file expects |

## Expiry

Pinned to the versions in the table above. Any of these breaks it:

- A DSM update that changes the kernel.
- A sandbox service release that changes how the runner builds its container
  create command, or how `start-runner.sh` launches the inner daemon. The
  gap 3 fix works only because that script launches `dockerd` as a child
  process, so it inherits the container's environment. There is no other hook.
- An inner Docker release that drops `DOCKER_INSECURE_NO_IPTABLES_RAW`, which
  the Docker maintainers describe as not recommended for production.

Re-run `verify.sh` after any upgrade.

## Confidence

Every claim here was measured on the hardware above, with two exceptions,
stated so you can weigh them:

- The absence of the pids cgroup controller is inferred from `docker stats`
  reporting `PIDS 0` for a container running at least five processes. It was
  not measured directly.
- The verbatim error for gap 3 was not captured. The fix and the symptom are
  from the session where it was diagnosed; the error string is not quoted
  because I do not have it.

## Licence and attribution

Everything in this repo is MIT licensed. See [LICENSE](LICENSE).

The n8n sandbox service is not open source. It ships under n8n's
[Sustainable Use License](https://github.com/n8n-io/n8n-sandbox-service/blob/main/LICENSE.md),
which permits internal business, personal and non-commercial use. This repo
contains no n8n code and redistributes no n8n software. `compose.yaml` is my
own file; it references their published images by name and pulls them from
their registry at run time.

## References

- [n8n: Install using Docker Compose](https://docs.n8n.io/deploy/host-n8n/install-options/install-using-docker-compose)
- [n8n: Set up n8n Assistant](https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-n8n-assistant)
- [Sandbox service configuration reference](https://github.com/n8n-io/n8n-sandbox-service/blob/main/docs/configuration.md)
- [Docker Engine 28 release notes](https://docs.docker.com/engine/release-notes/28/), for the `raw` table opt-out in 28.0.2
- [moby/moby#49621](https://github.com/moby/moby/pull/49621), the pull request that added it
