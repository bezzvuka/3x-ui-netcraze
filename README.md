# 3x-ui Netcraze / Entware patch

This repository contains a small compatibility patch and a tested `arm64`
binary for running 3x-ui v3.6.0 on a Netcraze Ultra router with Entware.

On Netcraze, `/` is the read-only firmware SquashFS and is expected to appear
100% full. Entware and 3x-ui data live on the external drive mounted at `/opt`.
Upstream 3x-ui v3.6.0 always measures `/`, so its dashboard reports a false
critical disk warning.

The patch adds the optional `XUI_DISK_PATH` environment variable. The default
remains `/`, preserving upstream behavior. On Netcraze, set it to `/opt`.

## One-line installation

After Entware/OPKG has been initialized on an external EXT4 drive:

```sh
curl -Ls https://raw.githubusercontent.com/bezzvuka/3x-ui-netcraze/main/install.sh | bash
```

Netcraze/NDMS does not expose `/dev/fd`, so Bash process substitution in the
upstream form `bash <(curl ...)` is unavailable even after Entware Bash is
installed. The pipe form above is its direct one-line equivalent.

If Entware does not yet have `curl`, use its `wget` and `bash` directly:

```sh
/opt/bin/wget -qO- https://raw.githubusercontent.com/bezzvuka/3x-ui-netcraze/main/install.sh | /opt/bin/bash
```

The installer validates the architecture, external `/opt` mount, free space,
and bundle SHA-256. Existing databases and credentials are preserved, and the
previous program directory is retained as a timestamped rollback copy.

## Entware environment

```sh
export XUI_DB_FOLDER=/opt/etc/x-ui
export XUI_BIN_FOLDER=/opt/3x-ui/bin
export XUI_LOG_FOLDER=/opt/var/log/x-ui
export XUI_DISK_PATH=/opt
export XUI_ENABLE_FAIL2BAN=false
```

## Apply and build

```sh
git clone --branch v3.6.0 --depth 1 https://github.com/MHSanaei/3x-ui.git
cd 3x-ui
git apply ../xui-disk-path.patch
cd frontend
npm ci
npm run build
cd ..
```

Run `build_netcraze.py` from the repository root in an amd64 Debian/Python
container. It downloads Go 1.26.5 and Bootlin's stable aarch64-musl toolchain,
then produces a statically linked `x-ui-netcraze` binary.

## Tested configuration

- Netcraze Ultra NC-1812
- aarch64, NDMS kernel 4.9
- Entware external drive mounted at `/opt`
- 3x-ui 3.6.0
- Xray 26.7.28

The release binary was tested on the router before publication. Keep the
original `x-ui` binary as a rollback copy before replacing it.
