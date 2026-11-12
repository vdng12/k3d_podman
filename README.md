# Kubernetes on Void Linux with Podman

Experimenting with local Kubernetes clusters on **Void Linux + Podman**
(runit init, no systemd). Started with [k3d](https://k3d.io/) (k3s clusters),
pivoted to [kind](https://kind.sigs.k8s.io/) (upstream Kubernetes) after
hitting Podman Docker API compatibility gaps.

**Current direction:** kind with its native Podman provider, avoiding the
Docker API translation layer entirely.

## What we created and tried

### Runit service for the rootful Podman API socket

`artifacts/podman-api.run` - an on-demand runit service that starts the rootful Docker-compatible API socket at `/run/podman/podman.sock`.

Installed at `/etc/sv/podman-api/`, controlled via `sudo sv up/down podman-api`.

###  Docker socket symlink

```bash
sudo ln -s /run/podman/podman.sock /var/run/docker.sock
```

So k3d could find the Podman socket at its default path without needing `DOCKER_HOST` in every command.

### Cluster lifecycle wrapper (`k3dctl`)

`artifacts/k3dctl` - a bash script encoding the full cluster lifecycle (preflight, API up, network cleanup, `k3d cluster create`, kubeconfig pull,
wait for Ready, stop, delete).

### Shell integration (`k3d.bashrc`)

`artifacts/k3d.bashrc` - merges k3d kubeconfigs into `KUBECONFIG`, wraps `k3d` with sudo + `DOCKER_HOST`, aliases `k` -> `kubectl`.

## What Failed and Why

### DNS: Network Created via Docker API Has no DNS

The Podman network was created through the Docker API compatibility layer,
which set `dns_enabled: true` but left `dns: null`. Without a DNS server
address, `aardvark-dns` couldn't serve hostname resolution. Containers
could not resolve each other's hostnames, so agent nodes never registered
with the server.

```bash
# k3d-lab network inspect:
{
  "dns_enabled": true,
  "dns": null
}

# Inside the agent container:
ping k3d-lab-server-0  ->  bad address
```

Fix workaround (not deployed): Create the network manually with
`sudo podman network create --dns <gateway> k3d-lab` before running k3d, 
so DNS is configured natively.

### Cgroup: rootless k3d blocked by no cgroup delegation

Void uses runit, not systemd. Without systemd's `user@.service`, there's
no user-owned cgroup tree. The k3d entrypoint's cgroup fix script tried
to create `/sys/fs/cgroup/init` inside the container and got:
`mkdir: cannot create directory: Permission denied`

Rootless k3d is not possible on this host.

### Loadbalancer: config volume never populated

k3d creates an ephemeral haproxy config file and mounts it into the
loadbalancer container. Through the Docker API, Podman creates the volume
but doesn't write the config data into it, so the loadbalancer exits
immediately with `no such file or directory`.

---

## Why `kind` over `k3d`

[Kind](https://kind.sigs.k8s.io/) has a **native Podman provider** -- it
does not need the Docker API compatibility socket at all. This avoids
all the translation-layer issues we hit:

| Issue with k3d | How kind handles it |
|---|---|
| Container DNS broken via API socket | Native Podman networking -- works |
| Loadbalancer config volume never populated | No loadbalancer needed |
| `podman system service` required | kind speaks Podman directly |
| cgroup delegation blocks rootless | Same limitation -- but no API layer compounding it |

The tradeoff is k3s (Rancher's minimal distro) vs upstream Kubernetes
(kubeadm). For local development the difference is marginal -- same
kubectl, same manifests, same API.

---

## Files in this repo

| Path | Description |
|---|---|
| `artifacts/k3d.yaml` | k3d cluster definition (1 server, 2 agents, port 8080:80) |
| `artifacts/podman-api.run` | Runit service for rootful Podman API socket |
| `artifacts/k3dctl` | Cluster lifecycle wrapper script |
| `artifacts/k3d.bashrc` | Shell integration (KUBECONFIG, k3d wrapper, k alias) |
| `docs/podman_migration.md` | Original design doc: Docker -> Podman migration |
| `docs/plan.md` | Learning plan for Kubernetes |
| `docs/op_11112026.md` | Operation log with all commands, debug steps, and results |

---

## Quick reclamation (undo all host changes)

```bash
sudo rm /var/service/podman-api
sudo rm -rf /etc/sv/podman-api
sudo rm /var/run/docker.sock
sudo sed -i '/mount --make-rshared \//d' /etc/rc.local
sudo mount --make-rslave /
rm -f ~/.kube/k3d-lab.yaml
```
