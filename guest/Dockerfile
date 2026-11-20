# Turns an orb container image into something that boots as a KVM guest:
# adds a kernel + initramfs, the QEMU guest agent, udev and networkd config.
ARG BASE
FROM ${BASE}
USER root
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "linux-image-cloud-$(dpkg --print-architecture)" initramfs-tools \
        systemd systemd-sysv udev dbus kmod iproute2 iputils-ping procps \
        qemu-guest-agent e2fsprogs libpam-systemd; \
    apt-get clean; rm -rf /var/lib/apt/lists/*
COPY rootfs/ /
RUN set -eux; \
    systemctl enable systemd-networkd.service orb-hosts.service; \
    mkdir -p /etc/systemd/system/multi-user.target.wants; \
    ln -sf /lib/systemd/system/qemu-guest-agent.service \
        /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service; \
    systemctl mask systemd-networkd-wait-online.service \
        apt-daily.timer apt-daily-upgrade.timer man-db.timer e2scrub_all.timer \
        e2scrub_reap.service getty@tty1.service; \
    systemctl set-default multi-user.target
