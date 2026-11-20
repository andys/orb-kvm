#!/usr/bin/env bash
# dispatch.sh — Amp self-hosted orb dispatch program for KVM/QEMU on this host.
#
#   amp orb provider /abs/path/to/dispatch.sh
#
# The provider runs this once per job with the job in the environment:
#   ORB_OPERATION  spawn | pause | delete
#   ORB_ID         stable orb name (amp-<thread id>)
#   ORB_IMAGE      spawn: OCI image to boot (converted to a qcow2 base once)
#   ORB_SNAPSHOT_ID  spawn: boot from this project snapshot if we have it
#                    pause: also save the disk under this ID
#   ORB_TYPE       spawn: orb type name -> CPUs/RAM (see config.sh)
#   ORB_TOKEN, AMP_URL  spawn: passed to `amp orb bootstrap` in the guest
#
# Every operation is idempotent and serialized per orb.
source "$(dirname "$(readlink -f "$0")")/lib.sh"
need "$QEMU" "$QEMU_IMG" socat jq flock

: "${ORB_OPERATION:?ORB_OPERATION is required}"
: "${ORB_ID:?ORB_ID is required}"
orb_paths "$ORB_ID"
lock "orb-$OKEY" 280

case $ORB_OPERATION in
spawn)
	: "${ORB_TOKEN:?ORB_TOKEN is required for spawn}"
	if ! orb_exists; then
		rm -rf "$ODIR"
		if [[ -n ${ORB_SNAPSHOT_ID-} ]] && snap_exists "$ORB_SNAPSHOT_ID"; then
			orb_create_from_snapshot "$ORB_SNAPSHOT_ID" "${ORB_TYPE-}" "$ORB_SNAPSHOT_MEMORY"
		else
			[[ -z ${ORB_SNAPSHOT_ID-} ]] || log "snapshot $ORB_SNAPSHOT_ID not on this host; using image"
			orb_create_from_image "${ORB_IMAGE:-$ORB_DEFAULT_IMAGE}" "${ORB_TYPE-}"
		fi
	fi
	orb_up
	guest_bootstrap
	;;
pause)
	if ! orb_exists; then
		log "no such orb; nothing to pause"
		exit 0
	fi
	orb_down
	if [[ -n ${ORB_SNAPSHOT_ID-} ]]; then
		snapshot_offline "$ORB_SNAPSHOT_ID" "$ORB_SNAPSHOT_MEMORY"
	fi
	log "paused"
	;;
delete)
	qemu_kill
	rm -rf "$ODIR" "$RDIR"
	log "deleted"
	;;
*)
	die "unknown ORB_OPERATION '$ORB_OPERATION'"
	;;
esac
