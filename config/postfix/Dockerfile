# corelab — Postfix image: the Debian package, on a pinned (digest) base image.
FROM debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      postfix libsasl2-modules ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY main.cf /etc/postfix/main.cf
RUN chmod 0644 /etc/postfix/main.cf

# chroot off (so the relay name from /etc/hosts resolves), postlog service for the log file
RUN postconf -F '*/*/chroot = n' \
 && (postconf -M postlog/unix-dgram 2>/dev/null | grep -q . \
     || postconf -M 'postlog/unix-dgram=postlog unix-dgram n - n - 1 postlogd') \
 && mkdir -p /var/log/postfix

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

EXPOSE 25
ENTRYPOINT ["/entrypoint.sh"]
