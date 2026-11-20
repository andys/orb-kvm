#!/usr/bin/env bash
# build-image.sh [--pull] [--force] [IMAGE]
#
# Converts an orb OCI image (default: $ORB_IMAGE or Amp's image) into a
# bootable base layer: an ext4 root filesystem in a qcow2 file plus the
# kernel/initramfs to boot it directly. Needs Docker; root is not needed on
# the host because the filesystem is assembled inside a container.
source "$(dirname "$(readlink -f "$0")")/lib.sh"
need docker "$QEMU_IMG" jq sha256sum

pull=0 force=0
while [[ $# -gt 0 ]]; do
	case $1 in
	--pull) pull=1; shift ;;
	--force) force=1; shift ;;
	-h | --help) sed -n '2,8p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
image=${1:-${ORB_IMAGE:-$ORB_DEFAULT_IMAGE}}
ikey=$(key "$image")
lock "image-$ikey" 1800

if [[ $pull == 1 ]] || ! docker image inspect "$image" >/dev/null 2>&1; then
	log "pulling $image"
	docker pull --platform linux/amd64 "$image" >&2
fi
digest=$(docker image inspect -f '{{.Id}}' "$image")
ienv=$IMAGES/$ikey/image.env
if [[ $force == 0 && -f $ienv && $(kv_get "$ienv" DIGEST) == "$digest" ]]; then
	log "base disk for $image ($digest) is up to date"
	exit 0
fi

work=$ORBS_HOME/build/$(newid)
mkdir -p "$work"
tag=kvm-orbs-vm:$(hash12 "$digest")
cid=''
cleanup() {
	[[ -z $cid ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
	docker image rm "$tag" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

# Default user and environment from the image config.
OUSER=$(docker image inspect -f '{{.Config.User}}' "$image")
OUSER=${OUSER%%:*}
OUSER=${OUSER:-user}
docker image inspect "$image" | jq -r '.[0].Config.Env // [] | .[]' |
	while IFS= read -r kv; do
		k=${kv%%=*} v=${kv#*=}
		case $k in HOME | USER | LOGNAME | HOSTNAME | PWD | SHLVL | TERM) continue ;; esac
		[[ $v != *"'"* ]] || { log "skipping env $k (contains a quote)"; continue; }
		printf "%s='%s'\n" "$k" "$v"
	done >"$work/image.env"

log "adding kernel, systemd networking and guest agent to $image"
docker build -q --platform linux/amd64 --build-arg BASE="$image" -t "$tag" "$ORBSYS_DIR/guest" >&2

log "assembling root filesystem ($ORB_DISK_SIZE, sparse)"
cid=$(docker create --platform linux/amd64 "$tag" /bin/true)
# shellcheck disable=SC2016
docker export "$cid" | docker run --rm -i --platform linux/amd64 --user 0 --network none \
	--entrypoint /bin/bash -v "$work:/out" \
	-e SIZE="$ORB_DISK_SIZE" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$tag" -c '
	set -euo pipefail
	mkdir /r
	tar -x -p --numeric-owner --xattrs --xattrs-include="*" -C /r -f -
	rm -f /r/.dockerenv /r/etc/hostname /r/etc/hosts /r/etc/resolv.conf
	echo orb >/r/etc/hostname
	printf "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n" >/r/etc/hosts
	echo "nameserver 10.0.2.3" >/r/etc/resolv.conf
	: >/r/etc/machine-id
	mkdir -p /r/etc/orb
	install -m 0644 /out/image.env /r/etc/orb/image.env
	k=$(ls /r/boot/vmlinuz-* | sort -V | tail -1)
	cp "$k" /out/vmlinuz
	cp "/r/boot/initrd.img-${k#/r/boot/vmlinuz-}" /out/initrd.img
	mkfs.ext4 -q -F -L orbroot -E lazy_itable_init=1,discard -d /r /out/root.raw "$SIZE"
	chown "$HOST_UID:$HOST_GID" /out/*
' >&2
docker rm -f "$cid" >/dev/null
cid=''

log "converting to qcow2"
lid=$(newid)
"$QEMU_IMG" convert -f raw -O qcow2 -o cluster_size=65536 "$work/root.raw" "$(layer_path "$lid").tmp"
mv "$(layer_path "$lid").tmp" "$(layer_path "$lid")"
layer_meta "$lid" image "$image@$digest"

kid=$(cat "$work/vmlinuz" "$work/initrd.img" | sha256sum | cut -c1-16)
if [[ ! -f $KERNELS/$kid/vmlinuz ]]; then
	mkdir -p "$KERNELS/$kid.tmp"
	mv "$work/vmlinuz" "$work/initrd.img" "$KERNELS/$kid.tmp/"
	rm -rf "$KERNELS/$kid"
	mv "$KERNELS/$kid.tmp" "$KERNELS/$kid"
fi

mkdir -p "$IMAGES/$ikey"
IMAGE=$image DIGEST=$digest LAYER=$lid KERNEL=$kid BUILT=$(date -u +%FT%TZ)
kv_write "$ienv" IMAGE DIGEST LAYER KERNEL OUSER BUILT
log "base disk ready: layer $lid ($(du -h "$(layer_path "$lid")" | cut -f1) on disk), kernel $kid, user $OUSER"
