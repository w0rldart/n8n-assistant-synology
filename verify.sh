#!/usr/bin/env bash
#
# verify.sh - report which kernel features this host has, and which of the
# n8n sandbox service's security controls are actually working on it.
#
# Read-only except for two short-lived probe containers, which are removed.
# Always exits 0. This is a report, not a test suite.
#
#   ./verify.sh
#
# The host section works anywhere, with or without the sandbox stack running.
# The sandbox section is skipped unless the runner container is up.

RUNNER=${RUNNER:-sandbox-runner-1}
BRIDGE=${BRIDGE:-runner-bridge}

row() { printf '  %-32s %-11s %s\n' "$1" "$2" "$3"; }
section() { printf '\n%s\n%s\n' "$1" "-------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Docker access. Never expand an empty variable into a command position: an
# empty $DOCKER followed by "exec" would hit the shell's own exec builtin and
# replace this script. Everything goes through dk().
# ---------------------------------------------------------------------------

DOCKER_PREFIX=""
DOCKER_BIN=""
DOCKER_OK=no

# Find the binary before trying to use it. sudo often resets PATH via
# secure_path, and Synology keeps docker in /usr/local/bin, so `command -v`
# alone makes the whole script report SKIP under sudo while looking healthy.
for candidate in docker /usr/local/bin/docker /usr/bin/docker /opt/bin/docker; do
	if command -v "$candidate" >/dev/null 2>&1; then
		DOCKER_BIN=$(command -v "$candidate")
		break
	fi
done

if [ -n "$DOCKER_BIN" ]; then
	if "$DOCKER_BIN" info >/dev/null 2>&1; then
		DOCKER_OK=yes
	elif sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then
		DOCKER_PREFIX="sudo"
		DOCKER_OK=yes
	else
		echo "Found docker at $DOCKER_BIN but it needs a password." >&2
		echo "Re-run as: sudo $0" >&2
	fi
else
	echo "No docker binary found. Host checks will still run." >&2
fi

dk() {
	[ "$DOCKER_OK" = yes ] || return 127
	if [ -n "$DOCKER_PREFIX" ]; then
		"$DOCKER_PREFIX" "$DOCKER_BIN" "$@"
	else
		"$DOCKER_BIN" "$@"
	fi
}

# Run a command inside the runner container.
rex() { dk exec "$RUNNER" "$@" 2>/dev/null; }

runner_up() {
	[ "$DOCKER_OK" = yes ] || return 1
	[ "$(dk inspect "$RUNNER" --format '{{.State.Status}}' 2>/dev/null)" = "running" ]
}

# ---------------------------------------------------------------------------
# Host kernel
# ---------------------------------------------------------------------------

section "Host kernel"
row "uname" "" "$(uname -sr 2>/dev/null) $(uname -m 2>/dev/null)"

# overlayfs. Without it the inner daemon cannot create containers on its
# default snapshotter and needs an explicit storage driver.
if grep -qw overlay /proc/filesystems 2>/dev/null; then
	row "overlayfs" "present" "inner daemon can use its default driver"
else
	row "overlayfs" "ABSENT" "set DOCKER_DRIVER on the runner (btrfs on DSM)"
fi

# iptables raw table. Docker 28+ writes raw rules for every bridge endpoint.
# Probe inside the runner when it exists, since that is the namespace that
# matters, and fall back to the host.
IPTABLES_BIN=""
for candidate in iptables /sbin/iptables /usr/sbin/iptables /usr/local/sbin/iptables; do
	if command -v "$candidate" >/dev/null 2>&1; then
		IPTABLES_BIN=$(command -v "$candidate")
		break
	fi
done

RAW_RESULT=unknown
if runner_up && rex iptables -t raw -L -n >/dev/null 2>&1; then
	RAW_RESULT=present
elif runner_up; then
	RAW_RESULT=absent
elif [ -n "$IPTABLES_BIN" ]; then
	if "$IPTABLES_BIN" -t raw -L -n >/dev/null 2>&1 ||
		sudo -n "$IPTABLES_BIN" -t raw -L -n >/dev/null 2>&1; then
		RAW_RESULT=present
	else
		RAW_RESULT=absent
	fi
fi
case "$RAW_RESULT" in
present) row "iptables raw table" "present" "no workaround needed" ;;
absent) row "iptables raw table" "ABSENT" "needs DOCKER_INSECURE_NO_IPTABLES_RAW=1 (Docker 28.0.2+)" ;;
*) row "iptables raw table" "unknown" "iptables not callable from this shell" ;;
esac

# CPU CFS scheduler. Without it --cpus is rejected at container create.
if [ -e /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] ||
	grep -qw cpu /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
	row "CPU CFS scheduler" "present" "--cpus works"
else
	row "CPU CFS scheduler" "ABSENT" "--cpus rejected; needs ENABLE_CGROUPS=false"
fi

# pids controller. Without it --pids-limit cannot be enforced.
if [ -d /sys/fs/cgroup/pids ] ||
	grep -qw pids /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
	row "pids cgroup controller" "present" "--pids-limit works"
else
	row "pids cgroup controller" "ABSENT" "no process-count limit available"
fi

# seccomp. A kernel built without CONFIG_SECCOMP has no Seccomp line at all.
if grep -q '^Seccomp:' /proc/self/status 2>/dev/null; then
	row "seccomp" "present" "default profile applies to containers"
else
	row "seccomp" "ABSENT" "containers run with no syscall filter"
fi

# bridge netfilter. Decides whether enable_icc=false can be enforced. Note
# that before sysctl namespacing (roughly kernel 5.3) the host value applies
# globally even where a container cannot read the file.
BRNF=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)
case "$BRNF" in
1) row "bridge-nf-call-iptables" "on" "bridged traffic traverses iptables" ;;
0) row "bridge-nf-call-iptables" "OFF" "inter-container rules not enforced" ;;
*) row "bridge-nf-call-iptables" "unreadable" "br_netfilter not loaded, or not visible here" ;;
esac

# xfs quota, only relevant for per-sandbox disk limits.
if zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_XFS_QUOTA=[ym]' ||
	grep -q '^CONFIG_XFS_QUOTA=[ym]' "/boot/config-$(uname -r)" 2>/dev/null; then
	row "CONFIG_XFS_QUOTA" "present" "per-sandbox disk quotas can be enforced"
else
	row "CONFIG_XFS_QUOTA" "unknown" "kernel config unreadable; leave disk quota at 0"
fi

# ---------------------------------------------------------------------------
# Host Docker
# ---------------------------------------------------------------------------

section "Host Docker"
if [ "$DOCKER_OK" != yes ]; then
	row "daemon" "SKIP" "docker not reachable from this shell"
else
	row "version" "" "$(dk version --format '{{.Server.Version}}' 2>/dev/null)"
	row "storage driver" "" "$(dk info --format '{{.Driver}}' 2>/dev/null)"
	SECOPTS=$(dk info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null)
	row "security options" "" "${SECOPTS:-none reported}"
fi

# ---------------------------------------------------------------------------
# Sandbox stack
# ---------------------------------------------------------------------------

section "Sandbox stack"

if [ "$DOCKER_OK" != yes ] || ! dk inspect "$RUNNER" >/dev/null 2>&1; then
	row "$RUNNER" "SKIP" "container not found; start the stack and re-run"
	printf '\n'
	exit 0
fi

if ! runner_up; then
	row "$RUNNER" "NOT RUNNING" "state: $(dk inspect "$RUNNER" --format '{{.State.Status}}' 2>/dev/null)"
	printf '\n'
	exit 0
fi
row "$RUNNER" "running" ""

# The image the runner starts sandboxes from. Reused for the probes below so
# this script never pulls anything.
IMAGE=$(rex printenv SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE)
row "sandbox image" "" "${IMAGE:-unknown}"

CGROUPS=$(rex printenv SANDBOX_RUNNER_ENABLE_CGROUPS)
row "per-sandbox limits" "" "ENABLE_CGROUPS=${CGROUPS:-true (default)}"

RUNNERMEM=$(dk inspect "$RUNNER" --format '{{.HostConfig.Memory}}' 2>/dev/null)
case "$RUNNERMEM" in
'' | 0) row "runner memory ceiling" "NONE" "a runaway sandbox can take the host's memory" ;;
*[!0-9]*) row "runner memory ceiling" "unknown" "unexpected value: $RUNNERMEM" ;;
*) row "runner memory ceiling" "set" "$((RUNNERMEM / 1024 / 1024)) MiB" ;;
esac

CAPACITY=$(rex printenv SANDBOX_RUNNER_CAPACITY_TOTAL)
row "reported capacity" "" "${CAPACITY:-1000 (default)}"

INNERVER=$(rex docker version --format '{{.Server.Version}}')
row "inner Docker" "" "${INNERVER:-unreachable}"
row "inner storage driver" "" "$(rex docker info --format '{{.Driver}}')"

if [ -z "$INNERVER" ]; then
	row "inner daemon" "UNREACHABLE" "check /var/log/dockerd.log inside the runner"
	printf '\n'
	exit 0
fi

# ---------------------------------------------------------------------------
# Network controls, measured rather than assumed
# ---------------------------------------------------------------------------

section "Network controls (measured)"

RULES=$(rex iptables -t filter -S)

if printf '%s' "$RULES" | grep -q 'N8N-SB-BR-EGRESS'; then
	NDROP=$(printf '%s' "$RULES" | grep -c 'N8N-SB-BR-EGRESS.*-j DROP')
	row "egress DROP chain" "present" "$NDROP private ranges dropped"
else
	row "egress DROP chain" "ABSENT" "sandboxes may reach your network"
fi

if printf '%s' "$RULES" | grep -q -- "-i $BRIDGE -o $BRIDGE -j DROP"; then
	row "inter-sandbox DROP rule" "present" "rule exists; behaviour tested below"
else
	row "inter-sandbox DROP rule" "ABSENT" "sandboxes can reach each other"
fi

# connect_ex returns 0 on success. With a timeout set, a silently dropped
# packet surfaces as errno 11, a refusal as 111, an unroutable address as
# 101 or 113. A drop means a firewall rule; the others mean no route.
probe() {
	rex docker run --rm --network "$BRIDGE" --entrypoint python3 "$IMAGE" \
		-c "import socket;s=socket.socket();s.settimeout(4);print(s.connect_ex(('$1',$2)))"
}

blocked_verdict() {
	case "$1" in
	0) echo "REACHABLE" ;;
	'') echo "ERROR" ;;
	*) echo "blocked" ;;
	esac
}

GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
if [ -n "$GW" ]; then
	R=$(probe "$GW" 80)
	row "reach LAN gateway" "$(blocked_verdict "$R")" "errno ${R:-none}, want blocked"
else
	row "reach LAN gateway" "SKIP" "no default route found"
fi

R=$(probe 10.0.0.1 80)
row "reach 10.0.0.1" "$(blocked_verdict "$R")" "errno ${R:-none}, want blocked"

R=$(probe 1.1.1.1 53)
case "$R" in
0) row "reach public internet" "yes" "expected; the Assistant installs packages" ;;
'') row "reach public internet" "ERROR" "probe did not run" ;;
*) row "reach public internet" "no" "errno $R; package installs will fail" ;;
esac

PEER="verify-icc-$$"
rex docker rm -f "$PEER" >/dev/null 2>&1
if rex docker run -d --name "$PEER" --network "$BRIDGE" \
	--entrypoint python3 "$IMAGE" -m http.server 8000 >/dev/null 2>&1; then
	sleep 2
	PEERIP=$(rex docker inspect "$PEER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
	if [ -n "$PEERIP" ]; then
		R=$(probe "$PEERIP" 8000)
		row "sandbox to sandbox" "$(blocked_verdict "$R")" "errno ${R:-none}, want blocked"
	else
		row "sandbox to sandbox" "SKIP" "peer container had no address"
	fi
	rex docker rm -f "$PEER" >/dev/null 2>&1
else
	row "sandbox to sandbox" "SKIP" "could not start the peer container"
fi

cat <<'EOF'

Paste this output into an issue to add your hardware to the verified-on table.
It includes your LAN gateway address. Redact it if you would rather not share it.

EOF

exit 0
