# KVM orbs — self-hosted Amp orbs on this host

A dispatch program for [Amp self-hosted orbs](https://ampcode.com/docs/orbs/self-hosted)
that runs each orb as a KVM/QEMU virtual machine on qcow2 copy-on-write disks.

Here is how it compares with the examples in Amp's docs:

| | Memory | Disk | Project snapshots |
|---|---|---|---|
| this | Yes (RAM saved on pause) | Yes | Yes, as COW layers on one host |

Measured on this host: cold boot to guest agent takes about 4 s, pause with RAM
saved takes about 2 s, and resume takes about 4 s. A live snapshot with RAM
takes under 1 s.

## Requirements

```sh
sudo apt install qemu-system-x86 qemu-utils socat jq zstd
sudo usermod -aG kvm $USER      # /dev/kvm access for services
```

You also need Docker. It's used only to convert the orb OCI image into a
bootable disk. No root access is needed on the host.

## Quick start

```sh
./build-image.sh                 # once: OCI image -> qcow2 base (~2 min)
export AMP_ORB_PROVIDER_TOKEN=aop_live_...
amp orb provider "$PWD/dispatch.sh"
```

To run the provider permanently, see `systemd/kvm-orb-provider.service`.

Spawn builds a missing base image on demand. The first build can exceed the
5-minute job limit, so run `build-image.sh` ahead of time. Run it again with
`--pull` to pick up a newer `amp-orb:latest`. New orbs then use the new image.
Existing orbs and snapshots keep their layers.

## Files

| File | Purpose |
|---|---|
| `dispatch.sh` | The dispatch contract: `spawn`, `pause`, `delete` |
| `orbctl` | Manual control: save, fork, restore, exec, console, gc |
| `build-image.sh` | Converts the OCI image into a base qcow2 layer, kernel and initrd |
| `lib.sh` | Shared code: layers, QMP and guest-agent clients, VM lifecycle |
| `config.sh` | CPU/RAM per `ORB_TYPE`, memory saving, paths |
| `guest/` | Dockerfile and files added to the image so it boots as a VM |

## How it works

**Image to VM.** `build-image.sh` builds `guest/Dockerfile` on top of
`ORB_IMAGE`. That adds a Debian cloud kernel, udev, qemu-guest-agent and a
static systemd-networkd config. The script then exports the container's
filesystem and packs it into a sparse ext4 filesystem (`ORB_DISK_SIZE`,
default 64G) with `mke2fs -d` inside a container, so ownership and xattrs
are kept. Finally it converts that to qcow2. The VM boots that kernel
directly (`-kernel`/`-initrd`), so no bootloader is needed. The image's
`Config.Env` (PATH, LD_LIBRARY_PATH, …) goes into `/etc/orb/image.env`.

**Disks are chains of qcow2 layers.** They live under `~/.local/share/kvm-orbs`:

```
layers/<id>.qcow2        read-only: base images and frozen deltas
orbs/<orb>/disk.qcow2 -> top-*.qcow2   the orb's only writable overlay
snapshots/<key>/snap.env name -> layer (+ memory.state.zst, vm.env)
```

Saving a state never copies a disk. The orb's top overlay is renamed into
`layers/` (or hard-linked while the VM keeps running, using QMP
`blockdev-snapshot`). The orb then continues on a new, empty overlay on top
of it. A fork is another empty overlay on the same layer. Deleting an orb
removes only its own overlay. Chains deeper than `ORB_MAX_CHAIN` are
flattened onto the base image when a snapshot is taken.

**Memory.** On `pause`, the dispatcher flushes guest file systems, stops the
VM, saves RAM through QEMU migration to `memory.state.zst` (only touched
pages, zstd-compressed), and exits QEMU. The next `spawn` starts QEMU with
`-incoming`, so processes, tmux, portals and the desktop keep running. It
then deletes the RAM file (the disk diverges from it from then on) and
corrects the guest clock. If the restore fails, for example after a QEMU
upgrade that broke compatibility, it cold-boots from the same disk. Set
`ORB_SAVE_MEMORY=0` to always shut down cleanly instead.

**Dispatch contract.**

- `spawn` resumes or boots the orb. If the orb doesn't exist, it's created
  from `ORB_SNAPSHOT_ID` if that snapshot exists, otherwise from
  `ORB_IMAGE`. The dispatcher then runs
  `systemd-run --uid=user … amp orb bootstrap` through the guest agent,
  passing `ORB_TOKEN`/`AMP_URL` as environment variables rather than
  arguments. The bootstrap runs in its own transient unit with a PAM
  session. Failures print the unit journal and Amp's CLI log into the
  setup log. After a resume from RAM, the previous bootstrap is still
  alive and reconnects to the thread by itself. The new one exits as a
  duplicate, and the dispatcher reports this as success.
- `pause` saves RAM (above). With `ORB_SNAPSHOT_ID` set, it also freezes
  the disk into a snapshot layer. Repeating it is a no-op.
- `delete` kills QEMU and removes the orb's overlay.

All three are safe to repeat and are serialized per orb with `flock`.

`ORB_TYPE` maps to `ORB_TYPES` in `config.sh` (`small` 2/4G, `medium`
4/8G, `large` 8/16G; the default is 4/8G).

Project snapshots are disk-only by default (`ORB_SNAPSHOT_MEMORY=0`). A RAM
fork of a prepared orb would also revive the old thread's `amp orb
bootstrap`.

**Networking.** Networking uses QEMU user-mode NAT (slirp): outbound only
and isolated per VM, with no bridges, root access or inbound ports. That's
all orbs need, since everything else goes through Amp's tunnel.

## orbctl

```sh
./orbctl ls
./orbctl start dev --type large            # a VM not tied to Amp
./orbctl exec dev -- git --version         # as the image user (-r for root)
./orbctl console dev                       # serial console, Ctrl-] to quit
./orbctl save dev before-upgrade --memory  # live, no disk copy
./orbctl fork before-upgrade dev2 --memory # new VM resumes from the same state
./orbctl fork amp-T-1234 experiment        # fork an orb's current disk
./orbctl restore dev before-upgrade        # roll back (add --memory for RAM)
./orbctl layers dev                        # show the backing chain
./orbctl rmsnap before-upgrade && ./orbctl gc
```

`gc` deletes layers and kernels that no orb, snapshot or image refers to.
Amp's `amp projects snapshots delete` does not reach the dispatcher, so run
`orbctl rmsnap` and `orbctl gc` from time to time.

## Caveats

- Project snapshots, like the Docker example's, exist only on this host.
- Layers refer to their backing files by absolute path, so don't move
  `ORBS_HOME` after creating orbs.
- Guest kernel updates are ignored. The kernel used is the one extracted
  at image build time.
- On host reboot, running orbs lose their RAM but keep their disks. The
  next spawn cold-boots them and Amp runs `.agents/resume`.
- Each orb reserves its RAM size while running. Saved RAM files take only
  the touched pages (typically 100 MB–2 GB compressed).
- x86_64 only as written: the Dockerfile picks the kernel by architecture,
  but `QEMU` and `--platform` are amd64.
