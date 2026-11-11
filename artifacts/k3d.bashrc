# --- k3d on rootful Podman: append to ~/.bashrc ---

# merge default kubeconfig with every cluster kubeconfig k3dctl has written
_kc="$HOME/.kube/config"
for _f in "$HOME"/.kube/k3d-*.yaml; do [[ -e $_f ]] && _kc+=":$_f"; done
export KUBECONFIG=$_kc
unset _kc _f

# plain `k3d ...` also goes to rootful Podman (for one-off commands outside k3dctl)
k3d() {
  sudo DOCKER_HOST=unix:///run/podman/podman.sock \
       DOCKER_SOCK=/run/podman/podman.sock \
       "$(type -P k3d)" "$@"
}

alias k=kubectl
complete -o default -F __start_kubectl k 2>/dev/null
