#!/bin/sh
# corelab — start Postfix in the foreground (the container's main process).
set -eu

# chroot is off, but Debian's postfix scripts still expect these copies.
mkdir -p /var/spool/postfix/etc
for f in /etc/resolv.conf /etc/hosts /etc/services; do
	if [ -r "$f" ]; then
		cp "$f" /var/spool/postfix/etc/
	fi
done

mkdir -p /var/log/postfix
postfix check
exec postfix start-fg
