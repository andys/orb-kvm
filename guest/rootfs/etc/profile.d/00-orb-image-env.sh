# Environment from the orb image's OCI config (PATH, LD_LIBRARY_PATH, ...),
# which a container would have set and a VM login would otherwise lose.
if [ -r /etc/orb/image.env ]; then
	set -a
	. /etc/orb/image.env
	set +a
fi
