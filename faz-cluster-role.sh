#!/bin/sh
NS=ca-van3-01-socaas
VMS="faz-vm-poc-1 faz-vm-poc-2"
INTERVAL=5
SSH_USER=K8S-Eddie

API=https://kubernetes.default.svc
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat $SA/token)
k() { curl -s --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" "$@"; }

vm_ips() {
  k "$API/api/v1/namespaces/$NS/pods?labelSelector=vm.kubevirt.io/name=$1&fieldSelector=status.phase=Running" \
    | jq -r '.items[]?.status.podIP // empty'
}

role_of() {
  [ -z "$1" ] || [ "$1" = "null" ] && return
  printf 'diagnose ha status\nexit\n' \
    | timeout 10 ssh -tt -i /key/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR "$SSH_USER@$1" 2>/dev/null \
    | tr -d '\r' | awk -F': *' '/^HA-Status/{print $2; exit}'
}

set_role() {
  for p in $(k "$API/api/v1/namespaces/$NS/pods?labelSelector=vm.kubevirt.io/name=$1" \
           | jq -r '.items[].metadata.name'); do
    k -X PATCH -H 'Content-Type: application/merge-patch+json' \
      -d "{\"metadata\":{\"labels\":{\"faz-role\":\"$2\"}}}" \
      "$API/api/v1/namespaces/$NS/pods/$p" >/dev/null
  done
}

last=""
while true; do
  primary=""; n=0; summary=""
  for vm in $VMS; do
    r=""
    for ip in $(vm_ips "$vm"); do r=$(role_of "$ip"); [ -n "$r" ] && break; done
    summary="$summary $vm=${r:-unknown}"
    case "$r" in Primary*) primary=$vm; n=$((n+1));; esac
  done
  if [ "$n" -eq 1 ]; then
    for vm in $VMS; do [ "$vm" != "$primary" ] && set_role "$vm" secondary; done
    set_role "$primary" primary
    if [ "$primary" != "$last" ]; then
      echo "$(date -Iseconds) primary -> $primary |$summary"
      last=$primary
    fi
  else
    echo "$(date -Iseconds) no change ($n primaries) |$summary"
  fi
  sleep $INTERVAL
done
