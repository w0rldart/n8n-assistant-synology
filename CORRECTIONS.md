# Corrections

Three conclusions from this work that turned out to be wrong. They are here
because a repo showing only the path that worked is not much help to anyone
debugging the same thing, and because in two of the three cases the reasoning
was sound and the answer was still wrong.

## Inter-sandbox isolation is not lost

The inner daemon warns at startup that it cannot restrict inter-container
communication. It cannot read `/proc/sys/net/bridge/bridge-nf-call-iptables`
from inside its own network namespace, and bridged traffic reaches the iptables
FORWARD chain only when bridge netfilter is active. So `enable_icc=false` on
`runner-bridge` looked decorative, and two sandboxes on that bridge looked able
to reach each other. That went into the working notes and into the first draft
of this repo's security section.

It is wrong. Stand up two containers on `runner-bridge`, try to connect between
them, and the connection times out. The DROP rule is sitting in the chain dump.

On kernel 4.4 the `bridge-nf-*` sysctls are not network-namespaced; namespacing
arrived much later. The host's value applies everywhere, the host reads `1`,
and bridged traffic does go through iptables. The daemon could not read the
file to confirm a setting that was already in force, so it warned.
`DOCKER_IGNORE_BR_NETFILTER_ERROR=1` suppresses that check and nothing else.

The warning was accurate about what the daemon could not verify, and said
nothing about what was actually happening. On an ordinary kernel those amount
to the same thing. Here they did not, and only the behaviour showed which was
which.

## Sandboxes cannot reach the LAN

`sandbox-net` is a bridge with a gateway and is not marked internal, because
the runner has to pull its sandbox image. Sandbox traffic NATs out through the
runner onto that network and then to the host, and nothing in that path
obviously stops it reaching `192.168.0.0/16`. A host firewall rule looked
necessary, and the compose comment calling the network separation tidiness was
written on that basis.

Probes settled it. From a container on `runner-bridge`, the LAN router, the
NAS's own address, and a Postgres container on another Docker network with no
published port all timed out. Only a public address connected. The rule dump
then showed why, and the API had been logging `"egress":"public"` on every
sandbox create the whole time.

The error was reading the platform's constraints and stopping there. The
sandbox service implements egress filtering itself, in the `filter` table,
which this kernel has.

## Capacity of 2 was too low

Two looked like a sensible ceiling on concurrent sandboxes for one person. It
is not. The settings dialog creates one sandbox to validate the connection and
each Assistant conversation gets its own, so one person holds three without
trying, and the next one fails with `no eligible runners`. It is set to 4, and
the memory ceiling on the runner is the control that actually matters.

## Two things still not measured

Both are stated here instead of buried, because the rest of this repo claims to
be measured and these are not.

The pids cgroup controller is **inferred** to be absent, from `docker stats`
reporting `PIDS 0` for a container running at least five processes. That is a
strong inference and not a measurement.

The verbatim error for the missing `raw` iptables table was never captured. The
symptom and the fix are recorded from the session where it was diagnosed. The
error string appears nowhere in this repo because it is not in hand.
