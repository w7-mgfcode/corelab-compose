# shellcheck shell=bash
# The variables are used by the scripts that source this file:
# shellcheck disable=SC2034
# corelab — pinned image references (tag + digest), resolved 2026-11-16.
# The scripts (validate.sh, render-ignition.sh, smoke-test.sh, backup.sh)
# source this file. compose.yaml and external/compose.yaml repeat the same
# references verbatim (Compose cannot source a shell file); validate.sh checks
# that every image used there also appears here.
#
# Update: docker buildx imagetools inspect <name>:<tag>  ->  the "Digest:" line.

# --- Stack (app-01) ---
CADDY_IMAGE=caddy:2.11.9@sha256:4e2425f6009577e7c651010f16679c28f7d12df3e7b1914f941a7a3370746b3c
WORDPRESS_IMAGE=wordpress:7.1.4-php8.4-apache@sha256:4bf2c44f19a5eba28de4e5cbe50e1c5dc55ae3f8b894f681f4d7676a7e2512e5
WORDPRESS_CLI_IMAGE=wordpress:cli-2.12.0-php8.4@sha256:858dc76209146b8b5544fbdfde6fbb364fd7545c0114aebbccb52144adb50b5c
MARIADB_IMAGE=mariadb:11.8.9@sha256:d36f18d65a0459510b8b0f643b226a6d299e3206486e2b64ff20754a6d291707
DEBIAN_IMAGE=debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
LOKI_IMAGE=grafana/loki:3.7.10@sha256:b43c257ccfc925d4a50b8717cac61a3b51df8c48d01847936057e5c4075a24a7
ALLOY_IMAGE=grafana/alloy:v1.22.0@sha256:9acc2529bc1edb7f5b2bd801dd8334ebc80c158e3a9e5526ecd7c9a273d43189
GRAFANA_IMAGE=grafana/grafana:13.3.1@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf

# --- External VM (ext-01) ---
MAILPIT_IMAGE=axllent/mailpit:v1.33.1@sha256:aef2aacc11f075ec0fb6874275ee4a421e688e11a96ebb296134d1735c7761ce
CHECKMK_IMAGE=checkmk/check-mk-community:2.5.0p20@sha256:4677d9f8b11598252bf15cea61769e3dc20402908071e79448d3537acd8112f7

# --- Tools (validation, test) ---
BUTANE_IMAGE=quay.io/coreos/butane:v0.29.0@sha256:13fec166cb47a8e053dcc23256c0ca41aaa1c61cab39793832aaf8894ca78c8f
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
PHP_CLI_IMAGE=php:8.4.27-cli@sha256:d63e8b80cd4c6cfd01cfa7c910522e299cdc7ca1a2b6d6563db48df3c17e6c55
CURL_IMAGE=curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
HTTPD_IMAGE=httpd:2.4.71-alpine@sha256:32bd0639bcc4917ef1fd9363a1d9dd2dd9c498565118b062a10d51e43a5c3a24
LYCHEE_IMAGE=lycheeverse/lychee:0.24.2@sha256:e2d19e57cf6ab037026f20b8e449a1f30d9d7f81eef4194763aab2eab20bd28d
