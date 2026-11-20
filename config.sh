# config.sh — settings for the KVM orb dispatcher. Sourced by lib.sh.
# Anything here can be overridden from the provider's environment.

# Where all state lives (layers, snapshots, orbs). Must be on a disk with room
# for qcow2 layers and memory dumps. Must be stable across reboots.
: "${ORBS_HOME:=$HOME/.local/share/kvm-orbs}"

# Defaults for orbs whose ORB_TYPE is unset or unknown.
: "${ORB_DEFAULT_CPUS:=4}"
: "${ORB_DEFAULT_MEM:=8G}"

# Size of the guest root filesystem. Sparse: costs only what is written.
: "${ORB_DISK_SIZE:=64G}"

# Orb types (names configured in Amp's provider "Orb types"). "cpus mem".
declare -gA ORB_TYPES=(
	[small]="2 4G"
	[medium]="4 8G"
	[large]="8 16G"
)

# Save guest RAM on pause so processes survive (like E2B / exe.dev).
# 0 = cold-boot on every spawn (disk only, like Docker).
: "${ORB_SAVE_MEMORY:=1}"

# Compress memory dumps with zstd when available (smaller, a bit slower).
: "${ORB_COMPRESS_MEMORY:=1}"

# When Amp saves a project snapshot, also keep the RAM image with it. Forks of
# such a snapshot would then resume the old thread's processes (including its
# `amp orb bootstrap`), so this is off for Amp-driven snapshots. `orbctl save
# --memory` stores memory explicitly regardless of this setting.
: "${ORB_SNAPSHOT_MEMORY:=0}"

# Flatten a disk chain into one layer (on top of the base image) once it gets
# deeper than this many layers, to keep IO fast.
: "${ORB_MAX_CHAIN:=8}"

# Extra kernel command line for the guest.
: "${ORB_KERNEL_CMDLINE:=}"

# Seconds to wait for the guest agent after boot / resume.
: "${ORB_BOOT_TIMEOUT:=150}"
