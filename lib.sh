# lib.sh — shared code for dispatch.sh and orbctl. Source it; do not run it.
#
# On-disk layout ($ORBS_HOME):
#
#   layers/<lid>.qcow2     immutable, read-only qcow2 layers. Each one is either
#   layers/<lid>.json      a base image (no backing file) or a COW delta whose
#                          backing file is another layer (absolute path).
#   kernels/<kid>/         vmlinuz + initrd.img extracted from a base image.
#   images/<key>/image.env OCI image -> base layer + kernel + default user.
#   snapshots/<key>/       snap.env (name -> layer, kernel, ...) and, for
#                          memory snapshots, memory.state[.zst] + vm.env.
#   orbs/<orb>/            vm.env, disk.qcow2 -> top-*.qcow2 (the orb's only
#                          writable layer), memory.state[.zst] while paused
#                          with RAM saved, console.log.
#   locks/                 flock files.
#
# Runtime ($ORBS_RUN, short path because of the 108-byte unix socket limit):
#   <hash>/qmp.sock qga.sock serial.sock qemu.pid
#
# Saving a state never copies a disk: the orb's top overlay is turned into a
# new read-only layer and the orb continues on a fresh, empty overlay on top
# of it. Forks are just more overlays on the same layer.

set -euo pipefail
shopt -s nullglob

ORBSYS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
source "$ORBSYS_DIR/config.sh"

: "${ORBS_RUN:=${XDG_RUNTIME_DIR:-/tmp}/kvm-orbs-$(id -u)}"
: "${QEMU:=qemu-system-x86_64}"
: "${QEMU_IMG:=qemu-img}"
: "${ORB_ACCEL:=kvm}"
ORB_DEFAULT_IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest

LAYERS=$ORBS_HOME/layers
KERNELS=$ORBS_HOME/kernels
IMAGES=$ORBS_HOME/images
SNAPS=$ORBS_HOME/snapshots
ORBS=$ORBS_HOME/orbs
LOCKS=$ORBS_HOME/locks
mkdir -p "$LAYERS" "$KERNELS" "$IMAGES" "$SNAPS" "$ORBS" "$LOCKS" "$ORBS_RUN"
chmod 700 "$ORBS_RUN"

export LC_ALL=C

# ---------------------------------------------------------------- utilities

log() { printf '[kvm-orbs%s] %s\n' "${ORB_ID:+ $ORB_ID}" "$*" >&2; }
die() { log "error: $*"; exit 1; }

need() {
	local c
	for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done
}

hash12() { printf %s "$1" | sha256sum | cut -c1-12; }

# Turn an arbitrary name (snapshot IDs, image refs) into a safe file name.
key() {
	local s
	s=$(printf %s "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)
	printf '%s-%s' "$s" "$(hash12 "$1")"
}

newid() { printf '%s-%s' "$(date -u +%Y%m%d%H%M%S)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

# Write "NAME=value" lines safely quoted: kv_write FILE VAR...
kv_write() {
	local f=$1 v
	shift
	{ for v in "$@"; do printf '%s=%q\n' "$v" "${!v-}"; done; } >"$f.tmp"
	mv -f "$f.tmp" "$f"
}

# Read one variable from a kv file without polluting the caller.
kv_get() { (set +u; source "$1" && printf '%s' "${!2-}"); }

# with_lock NAME TIMEOUT -- holds an exclusive lock on fd 9 for the shell.
lock() {
	local name=$1 t=${2:-280}
	exec 9>"$LOCKS/$name.lock"
	flock -w "$t" 9 || die "timed out waiting for lock $name"
}

# ---------------------------------------------------------------- layers

layer_path() { printf '%s/%s.qcow2' "$LAYERS" "$1"; }
layer_id() { local b; b=$(basename "$1"); printf '%s' "${b%.qcow2}"; }

# Files of the backing chain, top first (absolute paths).
chain() { "$QEMU_IMG" info -U --backing-chain --output=json "$1" | jq -r '.[].filename'; }
chain_depth() { chain "$1" | wc -l; }
backing_of() { "$QEMU_IMG" info -U --output=json "$1" | jq -r '."full-backing-filename" // empty'; }
vsize() { "$QEMU_IMG" info -U --output=json "$1" | jq -r '."virtual-size"'; }

# True when an overlay holds no data of its own (nothing written since created).
overlay_empty() {
	[[ -z $("$QEMU_IMG" map -U --output=json "$1" | jq -c '.[] | select(.depth == 0 and .data)' | head -1) ]]
}

layer_meta() { # layer_meta LID KIND ORIGIN
	local lid=$1 parent
	parent=$(backing_of "$(layer_path "$lid")")
	jq -n --arg id "$lid" --arg kind "$2" --arg origin "$3" \
		--arg parent "${parent:+$(layer_id "$parent")}" --arg created "$(date -u +%FT%TZ)" \
		'{id:$id, kind:$kind, origin:$origin, parent:($parent|select(.!="")), created:$created}' \
		>"$LAYERS/$lid.json"
	chmod 0444 "$(layer_path "$lid")"
}

# If the chain under LID is deeper than ORB_MAX_CHAIN, write a new layer that
# holds everything above the base image and print its ID; otherwise print LID.
maybe_flatten() {
	local lid=$1 file depth base flat
	file=$(layer_path "$lid")
	depth=$(chain_depth "$file")
	if ((depth <= ORB_MAX_CHAIN)); then
		printf '%s' "$lid"
		return
	fi
	base=$(chain "$file" | tail -1)
	flat=$(newid)
	log "flattening $depth-deep chain of layer $lid onto $(layer_id "$base")"
	"$QEMU_IMG" convert -U -f qcow2 -O qcow2 -B "$base" -F qcow2 "$file" "$(layer_path "$flat").tmp" >&2
	mv "$(layer_path "$flat").tmp" "$(layer_path "$flat")"
	layer_meta "$flat" flattened "$lid"
	printf '%s' "$flat"
}

new_overlay() { # new_overlay BACKING_FILE OUT [unsafe]
	if [[ ${3-} == unsafe ]]; then
		"$QEMU_IMG" create -q -u -f qcow2 -F qcow2 -b "$1" "$2" "$(vsize "$1")"
	else
		"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$1" "$2"
	fi
}

# ---------------------------------------------------------------- images

image_env() { printf '%s/%s/image.env' "$IMAGES" "$(key "$1")"; }

# Make sure a bootable base layer exists for an OCI image.
image_ensure() {
	local image=$1
	[[ -f $(image_env "$image") ]] && return 0
	log "no base disk for $image yet; building it (this can take several minutes)"
	"$ORBSYS_DIR/build-image.sh" "$image" >&2
}

# ---------------------------------------------------------------- orbs

# orb_paths ID: sets ODIR (persistent) and RDIR (runtime sockets).
orb_paths() {
	local id=$1 name
	if [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$ ]]; then name=$id; else name=$(key "$id"); fi
	OKEY=$name
	ODIR=$ORBS/$name
	RDIR=$ORBS_RUN/$(hash12 "$id")
	QMP_SOCK=$RDIR/qmp.sock
	QGA_SOCK=$RDIR/qga.sock
	SERIAL_SOCK=$RDIR/serial.sock
	PIDFILE=$RDIR/qemu.pid
}

orb_exists() { [[ -f $ODIR/vm.env ]]; }

orb_pid() {
	local pid
	[[ -f $PIDFILE ]] || return 1
	pid=$(<"$PIDFILE")
	[[ -n $pid ]] && kill -0 "$pid" 2>/dev/null &&
		tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q -- "guest=$OKEY" || return 1
	printf '%s' "$pid"
}

orb_running() { orb_pid >/dev/null; }

memstate() { # path of the saved RAM image, if any
	local f
	for f in "$ODIR/memory.state.zst" "$ODIR/memory.state"; do
		[[ -f $f ]] && { printf '%s' "$f"; return 0; }
	done
	return 1
}

load_vm_env() {
	CPUS='' MEM='' MACHINE='' MAC='' KERNEL='' VMHOST='' OUSER='' IMAGE='' SOURCE=''
	# shellcheck disable=SC1091
	source "$ODIR/vm.env"
}
save_vm_env() { kv_write "$ODIR/vm.env" CPUS MEM MACHINE MAC KERNEL VMHOST OUSER IMAGE SOURCE; }

default_machine() {
	"$QEMU" -machine help | sed -n 's/^q35 .*(alias of \([^)]*\)).*/\1/p' | head -1
}

orb_size() { # orb_size TYPE -> sets CPUS MEM
	local spec=''
	[[ -z ${1:-} ]] || spec=${ORB_TYPES[$1]-}
	if [[ -n $spec ]]; then
		read -r CPUS MEM <<<"$spec"
	else
		[[ -z ${1:-} ]] || log "unknown ORB_TYPE '$1', using defaults"
		CPUS=$ORB_DEFAULT_CPUS MEM=$ORB_DEFAULT_MEM
	fi
}

hostname_for() { printf %s "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-63 | sed 's/-*$//'; }

# Point the orb at a fresh, empty writable overlay on top of BACKING.
orb_new_top() {
	local backing=$1 top old
	old=$(readlink -e "$ODIR/disk.qcow2" 2>/dev/null || true)
	top=top-$(newid).qcow2
	new_overlay "$backing" "$ODIR/$top" "${2-}"
	ln -sfn "$top" "$ODIR/disk.qcow2"
	[[ -z $old || ! -e $old || $old == "$ODIR/$top" ]] || rm -f "$old"
}

# orb_create_from_image IMAGE TYPE
orb_create_from_image() {
	local image=$1 ienv
	image_ensure "$image"
	ienv=$(image_env "$image")
	mkdir -p "$ODIR"
	orb_size "${2-}"
	MACHINE=$(default_machine)
	MAC=$(printf '52:54:00:%s' "$(od -An -N3 -tx1 /dev/urandom | tr -d '\n' | sed 's/^ //; s/ /:/g')")
	KERNEL=$(kv_get "$ienv" KERNEL)
	OUSER=$(kv_get "$ienv" OUSER)
	VMHOST=$(hostname_for "$ORB_ID")
	IMAGE=$image
	SOURCE="image:$image"
	orb_new_top "$(layer_path "$(kv_get "$ienv" LAYER)")"
	save_vm_env
	log "created orb from image $image ($CPUS vCPU, $MEM)"
}

snap_dir() { printf '%s/%s' "$SNAPS" "$(key "$1")"; }
snap_exists() { [[ -f $(snap_dir "$1")/snap.env ]]; }

# orb_create_from_snapshot NAME TYPE USE_MEMORY(0|1)
orb_create_from_snapshot() {
	local name=$1 sd mem
	sd=$(snap_dir "$name")
	mkdir -p "$ODIR"
	mem=$(kv_get "$sd/snap.env" MEMORY)
	if [[ $3 == 1 && $mem == 1 ]]; then
		# Memory images only load into an identical VM.
		cp "$sd/vm.env" "$ODIR/vm.env"
		load_vm_env
		for f in "$sd"/memory.state*; do ln -f "$f" "$ODIR/$(basename "$f")"; done
	else
		orb_size "${2-}"
		MACHINE=$(default_machine)
		MAC=$(printf '52:54:00:%s' "$(od -An -N3 -tx1 /dev/urandom | tr -d '\n' | sed 's/^ //; s/ /:/g')")
		KERNEL=$(kv_get "$sd/snap.env" KERNEL)
		OUSER=$(kv_get "$sd/snap.env" OUSER)
		IMAGE=$(kv_get "$sd/snap.env" IMAGE)
	fi
	VMHOST=$(hostname_for "$ORB_ID")
	SOURCE="snapshot:$name"
	orb_new_top "$(layer_path "$(kv_get "$sd/snap.env" LAYER)")"
	save_vm_env
	log "created orb from snapshot $name${mem:+ (memory=$mem, used=$3)}"
}

# ---------------------------------------------------------------- QMP / QGA
#
# Both speak line-delimited JSON over a unix socket. A session is a socat
# coprocess; requests carry an "id" so replies can be matched while events
# and stale replies are skipped.

_S_IN='' _S_OUT='' _S_PID=''

_sess_open() {
	[[ -S $1 ]] || return 1
	coproc _SESS { exec socat - "UNIX-CONNECT:$1" 2>/dev/null; }
	_S_IN=${_SESS[1]} _S_OUT=${_SESS[0]} _S_PID=$_SESS_PID
}

_sess_close() {
	[[ -n $_S_PID ]] || return 0
	{ exec {_S_IN}>&-; } 2>/dev/null || true
	kill "$_S_PID" 2>/dev/null || true
	wait "$_S_PID" 2>/dev/null || true
	_S_PID=''
}

# _sess_req JSON TIMEOUT -> prints .return; non-zero on error/timeout.
_sess_req() {
	local req=$1 t=${2:-30} id line left end
	id=r$RANDOM$RANDOM
	printf '%s\n' "$(jq -c --arg id "$id" '. + {id:$id}' <<<"$req")" >&"$_S_IN" || return 1
	end=$((SECONDS + t))
	while :; do
		left=$((end - SECONDS))
		((left > 0)) || { log "timeout waiting for reply to $(jq -r .execute <<<"$req")"; return 124; }
		IFS= read -r -t "$left" -u "$_S_OUT" line || { ((left = end - SECONDS)); ((left > 0)) && return 1; continue; }
		line=${line//$'\xff'/}
		[[ $line == *"\"$id\""* ]] || continue
		if jq -e 'has("error")' <<<"$line" >/dev/null; then
			log "$(jq -r .execute <<<"$req"): $(jq -r '.error.desc' <<<"$line")"
			return 1
		fi
		jq -c '.return' <<<"$line"
		return 0
	done
}

# qmp JSON [TIMEOUT]
qmp() {
	local line rc=1
	_sess_open "$QMP_SOCK" || { log "QMP socket missing"; return 1; }
	if IFS= read -r -t 10 -u "$_S_OUT" line && [[ $line == *QMP* ]] &&
		_sess_req '{"execute":"qmp_capabilities"}' 10 >/dev/null; then
		_sess_req "$1" "${2:-30}" && rc=0
	fi
	_sess_close
	return $rc
}

qmp_status() { qmp '{"execute":"query-status"}' 10 | jq -r .status; }

# qga JSON [TIMEOUT] — flushes stale data with guest-sync first.
qga() {
	local rc=1 n=$RANDOM
	_sess_open "$QGA_SOCK" || return 1
	if [[ $(_sess_req "{\"execute\":\"guest-sync-delimited\",\"arguments\":{\"id\":$n}}" 3 2>/dev/null) == "$n" ]]; then
		_sess_req "$1" "${2:-30}" && rc=0
	fi
	_sess_close
	return $rc
}

guest_ready() { qga '{"execute":"guest-ping"}' 5 >/dev/null 2>&1; }

wait_guest() {
	local end=$((SECONDS + ${1:-$ORB_BOOT_TIMEOUT}))
	until guest_ready; do
		orb_running || { log "VM exited while booting; see $ODIR/console.log"; return 1; }
		((SECONDS < end)) || { log "guest agent did not come up; see $ODIR/console.log"; return 1; }
		sleep 1
	done
}

# guest_exec [-t TIMEOUT] [-e K=V]... -- PROG ARGS...  (runs as root in guest)
# Prints the guest's stdout/stderr and returns its exit code.
guest_exec() {
	local t=60 env=() r pid st end
	while [[ $# -gt 0 ]]; do
		case $1 in
		-t) t=$2; shift 2 ;;
		-e) env+=("$2"); shift 2 ;;
		--) shift; break ;;
		*) break ;;
		esac
	done
	env+=("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "LANG=C.UTF-8")
	local req
	req=$(jq -nc --arg path "$1" '{execute:"guest-exec", arguments:{path:$path, arg:$ARGS.positional[1:], env:$env, "capture-output":true}}' \
		--argjson env "$(printf '%s\n' "${env[@]}" | jq -R . | jq -sc .)" --args -- "$@")
	r=$(qga "$req" 10) || return 125
	pid=$(jq -r .pid <<<"$r")
	end=$((SECONDS + t))
	while :; do
		st=$(qga "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 10) || return 125
		if [[ $(jq -r .exited <<<"$st") == true ]]; then
			jq -r '."out-data" // empty' <<<"$st" | base64 -d
			jq -r '."err-data" // empty' <<<"$st" | base64 -d >&2
			return "$(jq -r '.exitcode // 128' <<<"$st")"
		fi
		((SECONDS < end)) || { log "guest command timed out: $*"; return 124; }
		sleep 0.3
	done
}

guest_set_time() {
	qga "{\"execute\":\"guest-set-time\",\"arguments\":{\"time\":$(date +%s%N)}}" 10 >/dev/null ||
		log "warning: could not set guest clock"
}

# ---------------------------------------------------------------- VM process

# qemu_start [INCOMING_URI]
qemu_start() {
	load_vm_env
	mkdir -p "$RDIR"
	rm -f "$QMP_SOCK" "$QGA_SOCK" "$SERIAL_SOCK" "$PIDFILE"
	local kdir=$KERNELS/$KERNEL cpu=host
	[[ -f $kdir/vmlinuz ]] || die "kernel $KERNEL missing"
	[[ $ORB_ACCEL == kvm ]] || cpu=max
	local blk
	blk=$(jq -nc --arg f "$ODIR/disk.qcow2" \
		'{driver:"qcow2", "node-name":"top0", discard:"unmap", "detect-zeroes":"unmap",
		  file:{driver:"file", filename:$f, "aio":"threads"}}')
	local args=(
		-name "guest=$OKEY"
		-machine "$MACHINE,accel=$ORB_ACCEL"
		-cpu "$cpu" -smp "$CPUS" -m "$MEM"
		-nodefaults -no-user-config -display none
		-rtc base=utc,clock=host
		-kernel "$kdir/vmlinuz" -initrd "$kdir/initrd.img"
		-append "root=/dev/vda rw console=ttyS0,115200 net.ifnames=0 systemd.hostname=$VMHOST panic=-1 quiet $ORB_KERNEL_CMDLINE"
		-blockdev "$blk"
		-device virtio-blk-pci,drive=top0,id=vda
		-netdev user,id=n0
		-device "virtio-net-pci,netdev=n0,mac=$MAC,id=net0"
		-device virtio-rng-pci,id=rng0
		-device virtio-serial-pci,id=vser0
		-chardev "socket,id=qga0,path=$QGA_SOCK,server=on,wait=off"
		-device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0,id=qgaport
		-chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off,logfile=$ODIR/console.log,logappend=on"
		-serial chardev:ser0
		-qmp "unix:$QMP_SOCK,server=on,wait=off"
		-pidfile "$PIDFILE"
		-daemonize
	)
	[[ -z ${1-} ]] || args+=(-incoming defer)
	# 9>&-: never let the long-lived VM inherit (and hold) the orb lock.
	"$QEMU" "${args[@]}" 9>&- || return 1
	[[ -z ${1-} ]] && return 0
	qmp '{"execute":"migrate-set-parameters","arguments":{"max-bandwidth":107374182400}}' >/dev/null || true
	qmp "$(jq -nc --arg u "$1" '{execute:"migrate-incoming", arguments:{uri:$u}}')" >/dev/null || return 1
	local end=$((SECONDS + 240)) st
	while :; do
		orb_running || return 1
		st=$(qmp_status 2>/dev/null || echo unknown)
		[[ $st == running ]] && return 0
		# The source was stopped before saving, so the loaded VM stays paused.
		if [[ $st == paused || $st == prelaunch ]] &&
			[[ $(qmp '{"execute":"query-migrate"}' 10 | jq -r '.status // "none"') == completed ]]; then
			qmp '{"execute":"cont"}' >/dev/null && continue
		fi
		[[ $st == inmigrate || $st == unknown ]] || { log "unexpected VM status after resume: $st"; return 1; }
		((SECONDS < end)) || return 1
		sleep 0.3
	done
}

qemu_kill() {
	local pid i
	pid=$(orb_pid) || return 0
	qmp '{"execute":"quit"}' 5 >/dev/null 2>&1 || true
	for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
	kill -9 "$pid" 2>/dev/null || true
	for ((i = 0; i < 25; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
	rm -f "$PIDFILE"
}

# Save RAM of a *stopped* VM to FILE (zstd-compressed if name ends in .zst).
qemu_save_memory() {
	local out=$1 uri st end
	# The writer renames the file only once it has flushed everything.
	if [[ $out == *.zst ]]; then
		uri="exec:zstd -q -T0 -3 -o '$out.tmp' && mv -f '$out.tmp' '$out'"
	else
		uri="exec:cat > '$out.tmp' && mv -f '$out.tmp' '$out'"
	fi
	rm -f "$out" "$out.tmp"
	qmp '{"execute":"migrate-set-parameters","arguments":{"max-bandwidth":107374182400}}' >/dev/null || true
	qmp "$(jq -nc --arg u "$uri" '{execute:"migrate", arguments:{uri:$u}}')" >/dev/null || return 1
	end=$((SECONDS + 240))
	while :; do
		st=$(qmp '{"execute":"query-migrate"}' 10 | jq -r '.status // "none"') || return 1
		case $st in
		completed) break ;;
		failed | cancelled) log "memory save $st"; rm -f "$out.tmp"; return 1 ;;
		esac
		((SECONDS < end)) || { log "memory save timed out"; return 1; }
		sleep 0.2
	done
	for ((end = 0; end < 300; end++)); do [[ -f $out ]] && return 0; sleep 0.1; done
	log "memory image was not written"
	return 1
}

memfile_name() { if [[ $ORB_COMPRESS_MEMORY == 1 ]] && command -v zstd >/dev/null; then echo memory.state.zst; else echo memory.state; fi; }

incoming_uri() { if [[ $1 == *.zst ]]; then echo "exec:zstd -dcq '$1'"; else echo "exec:cat '$1'"; fi; }

# ---------------------------------------------------------------- lifecycle

# Bring the VM up (resuming RAM if saved). Leaves it running.
orb_up() {
	local st m
	if orb_running; then
		st=$(qmp_status || echo unknown)
		case $st in
		running) ;;
		paused | postmigrate) log "continuing paused VM"; qmp '{"execute":"cont"}' >/dev/null ;;
		*) log "VM in state $st; restarting"; qemu_kill ;;
		esac
	fi
	if ! orb_running; then
		if m=$(memstate); then
			log "resuming from saved memory"
			if qemu_start "$(incoming_uri "$m")"; then
				rm -f "$ODIR"/memory.state "$ODIR"/memory.state.zst # disk diverges from here on
				wait_guest 30 || true
				guest_set_time
				return 0
			fi
			log "warning: memory resume failed; cold booting from disk instead"
			qemu_kill
			rm -f "$ODIR"/memory.state "$ODIR"/memory.state.zst
		fi
		log "booting VM"
		qemu_start || die "qemu failed to start"
	fi
	wait_guest
}

# Stop the VM, keeping its disk and (optionally) its RAM.
orb_down() {
	local save_mem=${1:-$ORB_SAVE_MEMORY} pid i
	orb_running || return 0
	if [[ $save_mem == 1 ]]; then
		guest_exec -t 30 -- /bin/sync >/dev/null 2>&1 || true
		qmp '{"execute":"stop"}' >/dev/null || true
		if qemu_save_memory "$ODIR/$(memfile_name)"; then
			log "saved memory ($(du -h "$(memstate)" | cut -f1))"
		else
			log "warning: memory save failed; disk is kept, processes will restart"
		fi
		qemu_kill
	else
		pid=$(orb_pid)
		qmp '{"execute":"system_powerdown"}' >/dev/null || true
		for ((i = 0; i < 300; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
		qemu_kill
	fi
}

# Freeze the stopped orb's disk (and RAM if MEMORY=1) under snapshot NAME.
snapshot_offline() {
	local name=$1 want_mem=$2 sd top lid parent tmp m
	sd=$(snap_dir "$name")
	top=$(readlink -f "$ODIR/disk.qcow2")
	parent=$(backing_of "$top")
	if snap_exists "$name" && [[ $(kv_get "$sd/snap.env" LAYER) == "$(layer_id "$parent")" ]] && overlay_empty "$top"; then
		log "snapshot $name already up to date"
		return 0
	fi
	lid=$(newid)
	mv "$top" "$(layer_path "$lid")"
	layer_meta "$lid" delta "orb:$ORB_ID"
	lid=$(maybe_flatten "$lid")
	orb_new_top "$(layer_path "$lid")"
	m=''
	if [[ $want_mem == 1 ]]; then m=$(memstate) || m=''; fi
	snap_write "$name" "$lid" "$m"
}

# Live snapshot of a running orb: brief pause, no disk copy.
snapshot_live() {
	local name=$1 want_mem=$2 top lid newtop node m='' tmpd=''
	top=$(readlink -f "$ODIR/disk.qcow2")
	guest_exec -t 30 -- /bin/sync >/dev/null 2>&1 || true
	qmp '{"execute":"stop"}' >/dev/null
	# 1) While stopped, freeze the current overlay as a layer and redirect
	#    writes to a new overlay (must happen before a memory save, which
	#    inactivates the block nodes).
	lid=$(newid)
	ln "$top" "$(layer_path "$lid")"
	newtop=$ODIR/top-$(newid).qcow2
	new_overlay "$(layer_path "$lid")" "$newtop" unsafe
	node=$(qmp '{"execute":"query-block"}' | jq -r '.[] | select(.qdev | test("vda")) | .inserted."node-name"')
	local nn=top$RANDOM
	if ! qmp "$(jq -nc --arg n "$nn" --arg f "$newtop" '{execute:"blockdev-add", arguments:{driver:"qcow2", "node-name":$n, discard:"unmap", "detect-zeroes":"unmap", backing:null, file:{driver:"file", filename:$f, aio:"threads"}}}')" >/dev/null ||
		! qmp "$(jq -nc --arg o "$nn" --arg n "$node" '{execute:"blockdev-snapshot", arguments:{node:$n, overlay:$o}}')" >/dev/null; then
		rm -f "$newtop" "$(layer_path "$lid")"
		qmp '{"execute":"cont"}' >/dev/null
		die "live snapshot failed"
	fi
	ln -sfn "$(basename "$newtop")" "$ODIR/disk.qcow2"
	rm -f "$top"
	# 2) Optionally dump RAM; it matches the frozen layer exactly.
	if [[ $want_mem == 1 ]]; then
		tmpd=$ODIR/.snapmem-$(newid)
		mkdir -p "$tmpd"
		if qemu_save_memory "$tmpd/$(memfile_name)"; then
			m=$tmpd/$(memfile_name)
		else
			log "warning: memory save failed; snapshot will be disk-only"
		fi
	fi
	qmp '{"execute":"cont"}' >/dev/null
	layer_meta "$lid" delta "orb:$ORB_ID"
	guest_set_time
	[[ -n $m ]] || lid=$(maybe_flatten "$lid") # memory images need the exact layer
	snap_write "$name" "$lid" "$m"
	[[ -z $tmpd ]] || rm -rf "$tmpd"
}

# snap_write NAME LAYER [MEMFILE] — atomically (re)place a snapshot record.
snap_write() {
	local name=$1 lid=$2 mem=${3-} sd tmp old
	sd=$(snap_dir "$name")
	tmp=$SNAPS/.tmp-$(newid)
	mkdir -p "$tmp"
	load_vm_env
	if [[ -n $mem ]]; then
		ln "$mem" "$tmp/$(basename "$mem")"
		cp "$ODIR/vm.env" "$tmp/vm.env"
		MEMORY=1
	else
		MEMORY=0
	fi
	NAME=$name LAYER=$lid CREATED=$(date -u +%FT%TZ) ORIGIN=$ORB_ID
	kv_write "$tmp/snap.env" NAME LAYER KERNEL OUSER IMAGE MEMORY CREATED ORIGIN
	if [[ -e $sd ]]; then
		old=$SNAPS/.old-$(newid)
		mv "$sd" "$old"
		mv "$tmp" "$sd"
		rm -rf "$old"
	else
		mv "$tmp" "$sd"
	fi
	log "saved snapshot $name -> layer $lid$([[ $MEMORY == 1 ]] && echo ' (+memory)')"
}

# Start `amp orb bootstrap` in the guest as the image's default user.
guest_bootstrap() {
	load_vm_env
	local envs=(-e "ORB_TOKEN=$ORB_TOKEN" -e "OUSER=${OUSER:-user}" -e "ORB_BOOTSTRAP_PAM=${ORB_BOOTSTRAP_PAM:-1}")
	[[ -z ${AMP_URL-} ]] || envs+=(-e "AMP_URL=$AMP_URL")
	# shellcheck disable=SC2016
	guest_exec -t 60 "${envs[@]}" -- /bin/bash -c '
		set -euo pipefail
		home=$(getent passwd "$OUSER" | cut -d: -f6)
		unit=amp-orb-bootstrap-$(date +%s)
		opts=(--quiet --collect --unit="$unit" --uid="$OUSER" --gid="$OUSER"
			--working-directory="$home" -p EnvironmentFile=-/etc/orb/image.env
			--setenv=HOME="$home" --setenv=USER="$OUSER" --setenv=LOGNAME="$OUSER"
			--setenv=SHELL=/bin/bash --setenv=ORB_TOKEN)
		[[ $ORB_BOOTSTRAP_PAM == 1 ]] && opts+=(-p PAMName=login)
		[[ -z ${AMP_URL-} ]] || opts+=(--setenv=AMP_URL)
		systemd-run "${opts[@]}" /bin/bash -lc "exec amp orb bootstrap"
		sleep 2
		if systemctl is-active -q "$unit"; then
			echo "amp orb bootstrap running in unit $unit"
		elif old=$(pgrep -u "$OUSER" -f "^amp orb bootstrap" | head -1) && [[ -n $old ]]; then
			# Resumed from RAM: the previous bootstrap survived and reconnects
			# by itself; the new one exits as a duplicate.
			echo "amp orb bootstrap already running (pid $old)"
		else
			journalctl -u "$unit" --no-pager -n 50 || true
			tail -n 20 "$home/.cache/amp/logs/cli.log" 2>/dev/null || true
			exit 1
		fi'
}
