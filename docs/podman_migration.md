# Migrate Container Workloads and K3d Backend to Podman from Docker

This file documents the migration from docker-based local infra setup to podman.

## Old Setup

### Docker

Docker is my default choice for containerized infra since day one. However, as I progress, I realized that it was not a well designed technology. Its architecture centers on a long running root daemon, `dockerd`. Docker CLI tools are all clients that send HTTP requests to `dockerd` over a Unix domain socket (`/var/run/docker`). `dockerd` delegates container lifecycle to `containerd`, which use `runc` to create the namespaces and cgroups that isolate each container.

This design has two consequences:

- Availability: the daemon is a single point of failure. By default, stopping or restarting `dockerd` stops every container, unless `live-restore` is enabled.

- Security: `dockerd` runs as root, so anyone who can write to its socket (including members of the `docker` group)  effectively has root on the host

### Kind

Kind is a tool for running local Kubernetes clusters using Docker containers as nodes. Each node runs upstream Kubernetes bootstrapped by `kubeadm`. It supports Docker, Podman, and nerdctl as node providers.

I use k3d instead, which runs k3s inside the node containers, mainly because i already know k3s.

### Existing MLOps infra

A local k3d cluster running SeaweedFS, PostgreSQL, MLFlow, Kafka, and Polaris. No state worth keeping.

When migrated, cluster will be recreated on Podman from the same `k3d.yaml` and manifests. Public images will be re-pulled, and custom images are going to be rebuilt from the existing Dockerfiles.

Done when: the existing tests pass on the same ports and configs.


## Podman-Backed Infra 

### Podman

Podman is a CLI on top of a library (libpod), not a client for a daemon. Each `podman` command is a normal process that does its work directly and exits.

- Container state lives in files and a small database (`/var/lib/containers` for rootful, `~/.local/share/containers` for rootless). That's why nothing has to stay running, and why a later `podman ps` just reads it back.

- Rootless mode runs all of this inside a user namespace, with your subuid/subguid range mapped in. pasta handles networking because creating veth pairs on the host requires root.

### k3d

k3d is a lightweight wrapper to run k3s (Rancher Lab's minimal Kubernetes distribution) in docker. k3d makes it very easy to create single- and multi-node k3s clusters in docker, for local development on Kubernetes.

But for some reason, their podman support is worse than kind. k3d works with Podman through Podman’s Docker-compatible API socket, and you have it running. The real limitation is that k3d has no native Podman provider the way kind does, so it always needs the API socket.

### Benefits and Learning Opportunities

Day to day, Podman is more hassle than Docker. On Void (no systemd), the
cgroup delegation, socket service, and helper binaries all had to be set up
by hand. The trade is worth it for what the setup teaches:

- **Closer to the OCI model.** No daemon sits between me and the runtime.
  The path is just image → OCI runtime (`crun`/`runc`) → process, supervised
  by `conmon`. Each layer is visible and debuggable on its own.
- **Security by default.** Rootless with user namespaces, and no root
  socket. Where root is still needed (k3d), it's an explicit, optional
  choice rather than the baseline.
- **Same design concepts as Kubernetes.** Podman pods share network and IPC
  namespaces through an infra container, the same pattern as k8s's `pause`
  container. `conmon` plays the role of containerd's shim. Podman shares its
  image and storage libraries with CRI-O, and runs or exports k8s YAML
  (`podman kube play/generate`).
- **Hands-on Linux internals.** Every failure during migration mapped to a
  real primitive: namespaces, cgroup v2 delegation, mount propagation, PID 1
  init, container DNS.

**k3d as a disposable lab.** Multi-node k3s clusters run as containers and
  are defined in one `k3d.yaml`, so they're cheap to break and recreate. The
  same k3s distro runs on the homelab, so manifests and habits carry over.
  Running it on Podman also made explicit what a Kubernetes node actually
  needs from its host: privileged access, cgroup control, shared mount
  propagation, an init process, and container DNS.


## Blockers & Caveats

The root blocker is the host's init system. Void uses runit, not systemd, so the things systemd normally handles for containers had to be done by hand: cgroup delegation, shared mount propagation, and API socket activation. Without cgroup delegation, the kubelet inside the k3d nodes can't manage pod cgroups, which rules out rootless k3d.

Two limitations follow from this. First, the cluster has to run on rootful Podman: lifecycle commands need sudo and an explicit `DOCKER_HOST`, images are split between the rootful and rootless stores, and none of rootless Podman's security benefit applies to the cluster. Second, as mentioned previously, k3d only talks to Podman through its Docker-compatible API socket, unlike kind's native Podman provider, so that socket has to be running for every lifecycle command.

Host-to-cluster networking is a separate, pre-existing issue rather than a migration blocker. NodePorts aren't reachable from the host without explicit port mappings set at create time, and the Podman subnet differs from Docker's, so hardcoded IPs break. These problems existed on the Docker setup too.

    k3s is a conformant Kubernetes distribution, so manifests and API behaviour
match upstream. Its bundled defaults, and k3d's single-host setup, hide
problems that production surfaces:
- local-path storage never produces zone or multi-attach failures;
- servicelb hands out LoadBalancer IPs instantly;
- unset resource requests never cause scheduling trouble on a laptop;
- running as cluster-admin with no Pod Security enforcement hides
  permission problems;
- a single bridge network has no latency or DNS edge cases.

This setup therefore validates manifests and service wiring, not storage
durability, failover, or performance. Workloads stay portable when they
avoid k3s-specific resources (Traefik CRDs, the `HelmChart` CRD), keep
storage and ingress classes in overlays, set realistic resource requests,
pull images from a registry, and pin the k3s version to match production.

## Infra Design Choices 

Rootful Podman for k3d, rootless for everything else. Without cgroup
delegation on runit, rootless k3d isn't possible. Rather than block on that,
only the cluster runs rootful. Builds, ad-hoc containers, and everything
else stay rootless.

Podman API as an on-demand runit service. The rootful socket runs under
runit (`/etc/sv/podman-api`), with a `down` file so it doesn't start at
boot. It starts with `sv up` when cluster operations need it, and logs to
`/var/log/podman-api` via `svlogd`. The API never owns the containers
(`conmon` does), so stopping it doesn't affect a running cluster.

One wrapper script for the cluster lifecycle. `k3dctl` encodes the
manual steps in order: preflight checks, starting the API, cleaning up stale
networks, running k3d as root with `DOCKER_HOST`, writing the kubeconfig,
and waiting for nodes to be Ready. Day-to-day use comes down to `k3dctl
create/start/stop/delete`.

Root only for lifecycle, never for usage. k3d runs as root, but its
kubeconfig is copied to `~/.kube/k3d-<name>.yaml` and merged into
`KUBECONFIG`. kubectl, Helm, and k9s all run as the normal user.

Fully qualified image names. Dockerfiles and manifests use full
references (`docker.io/library/...`, `localhost/app:dev`) with non-`latest`
tags. This avoids short-name resolution differences between the rootful
and rootless registry configs, and stops k3s from trying to pull local
images from Docker Hub.

Ingress and LoadBalancer over NodePort. Host access goes through the
k3d load balancer's port mappings. NodePorts are mapped individually in
`k3d.yaml` only where tests require them.

## Migration Process

###  Step-by-step sequence

1. Disable Docker. Mark the service down (`sv down docker`, then
   `touch /etc/sv/docker/down`). Stop host containerd. Remove the user from
   the `docker` group.

2. Install Podman and its helpers: `podman`, `passt`, `catatonit`,
   `netavark`, `aardvark-dns`. Set `unqualified-search-registries` for
   short-name pulls.

3. Verify the rootless prerequisites: `XDG_RUNTIME_DIR`, subuid/subgid,
   cgroup v2. The cgroup limit test (`--memory`) fails because there is no
   delegation, so k3d goes rootful.

4. Prepare the host for rootful k3d. Run `mount --make-rshared /`
   (persisted in `/etc/rc.local`) and create `/run/podman`.

5. Start the rootful Podman API on `/run/podman/podman.sock` and point
   k3d at it through `DOCKER_HOST` / `DOCKER_SOCK`.

6. Recreate the cluster from `k3d.yaml`. Remove any stale `k3d-<name>`
   network first so container DNS is enabled.

7. Hand over the kubeconfig to `~/.kube/k3d-<name>.yaml` for
   non-root kubectl.

8. Redeploy the workloads. Public images are re-pulled. Custom images
   are rebuilt rootless and pushed to the k3d-managed registry.

9. Validate. nodes and pods are Ready, and the existing tests pass on
   the same ports and configs.

### 2. Automation

The manual sequence is encoded in three pieces:

- **`k3dctl`** (`~/.local/bin`) handles the cluster lifecycle
  (`create/start/stop/delete/status`). It runs steps 4–7 in order: preflight
  checks, starting the API, cleaning up the network, running k3d as root,
  writing the kubeconfig, and waiting for Ready. `stop` and `delete` shut the
  cluster down before the API.

- **`podman-api`** (`/etc/sv/podman-api`) is a runit service for the rootful
  socket. It is on demand (`down` file), logs via `svlogd` to
  `/var/log/podman-api`, and is used automatically by `k3dctl` when present.

- **`~/.bashrc` snippet**: merges every `k3d-*.yaml` into `KUBECONFIG`,
  defines a `k3d` wrapper (sudo + `DOCKER_HOST`) for one-off commands such as
  `k3d image import`, and sets the `k` alias with completion.

After a reboot, `k3dctl start` restores the full setup.
