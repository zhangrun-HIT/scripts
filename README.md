# Personal Scripts

Small helper scripts for Docker, ROS, WSL, and local development.

## Install

Run this from the repository directory:

```bash
./install_path.sh
source ~/.bashrc
```

The installer permanently adds the current directory to `PATH` in `~/.bashrc`.
It updates the existing managed block when run again, so it does not duplicate
the same `PATH` entry. It also loads Bash completions from `completions/*.bash`
for interactive shells.

## Docker Image Runner

```bash
run_docker_image.sh IMAGE CONTAINER_NAME [options]
```

Examples:

```bash
run_docker_image.sh yopo:latest yopo
run_docker_image.sh base_image:ubt20-ros1-cda ego-planner
run_docker_image.sh yopo:latest yopo --workspace ~/code:/root/code
run_docker_image.sh yopo:latest yopo --volume ~/datasets:/root/datasets
```

`--workspace` and `--volume` are both Docker bind mounts, but the script treats
them differently:

- `--workspace` sets the primary work directory mount. It can be used once and
  replaces the default `~:/root/host_home` mount. For example,
  `--workspace ~/code:/root/code` mounts only `~/code` as `/root/code`.
- `--volume` adds extra mounts. It can be used multiple times and does not
  replace the workspace mount. For example,
  `--volume ~/datasets:/root/datasets` keeps the default workspace mount and
  also mounts `~/datasets` as `/root/datasets`.

Preview the generated Docker command without running it:

```bash
run_docker_image.sh yopo:latest yopo --dry-run
```

Press Tab after the first argument position to complete local Docker image
names:

```bash
run_docker_image.sh yo<Tab>
```

The runner detects WSL automatically. In WSL, it adds WSLg and `/dev/dxg`
bindings and rewrites container proxy values from `127.0.0.1` to
`host.docker.internal`. It uses proxy port `7897`, GPU support, host networking,
privileged mode, and `~:/root/host_home` by default.

GUI environment defaults are selected by host type:

- WSL: `DISPLAY=:0`
- native Ubuntu: `DISPLAY=:1`

The selected GUI environment is written into managed shell/environment config
inside the container, so existing `DISPLAY` lines are updated instead of
duplicated.

When proxy is enabled, the container is configured before the interactive shell
opens:

- proxy environment variables are passed to Docker and written into managed
  shell config blocks
- apt proxy config is updated in `/etc/apt/apt.conf.d/95proxies`
- git global `http.proxy` and `https.proxy` are updated when git is installed

Existing proxy environment lines managed by the script are updated in place, and
direct proxy exports in the touched shell files are removed before the managed
block is written, so repeated runs do not create duplicate proxy exports. Use
`--proxy none` to remove the script-managed proxy config.

Bind mount sources and required WSL/GUI/GPU paths are checked before Docker
runs. If a required path does not exist, the script exits with an error instead
of starting a half-configured container.

## Mihomo Proxy Installer

```bash
install_mihomo_proxy.sh --sub-url 'https://example.com/subscribe?...'
```

`install_mihomo_proxy.sh` installs or updates the latest MetaCubeX mihomo
Linux `.deb` for the current system architecture, installs the latest
MetaCubeXD web UI, downloads a subscription config, enables `mihomo.service`,
and writes common system proxy settings for shells, apt, git, and Docker. At
startup it installs the basic packages it needs, including `curl`, `python3`,
`tar`, and CA certificates.

For safer command history, store the subscription URL in a file instead of
typing it directly:

```bash
mkdir -p ~/.config/mihomo
chmod 700 ~/.config/mihomo
printf '%s\n' 'https://example.com/subscribe?...' > ~/.config/mihomo/sub_url
chmod 600 ~/.config/mihomo/sub_url
install_mihomo_proxy.sh --sub-url-file ~/.config/mihomo/sub_url
```

Defaults:

- HTTP proxy: `127.0.0.1:7897`
- SOCKS proxy: `127.0.0.1:7891`
- external controller: `0.0.0.0:9090`
- external UI path: `/etc/mihomo/ui`
- remote UI URL: `http://<server-ip>:9090/ui`

The subscription downloader uses Clash Verge style headers by default and tries
several common client `User-Agent` values if the first request is rejected. If a
provider requires extra headers, pass them explicitly:

```bash
install_mihomo_proxy.sh \
  --sub-url-file ~/.config/mihomo/sub_url \
  --header 'Authorization: Bearer TOKEN'
```

Preview the installation without changing the system:

```bash
install_mihomo_proxy.sh --sub-url-file ~/.config/mihomo/sub_url --dry-run
```

Useful options:

- `--download-proxy URL` uses an existing proxy while downloading releases and
  the subscription.
- `--user-agent VALUE` overrides the subscription fetch `User-Agent`.
- `--skip-subscription` keeps the current `/etc/mihomo/config.yaml`.
- `--skip-system-proxy` skips shell, apt, git, and Docker proxy settings.
- `--skip-docker-proxy` skips only the Docker systemd proxy drop-in.

## Mihomo Config Refresher

```bash
refresh_mihomo_config.sh --sub-url 'https://example.com/subscribe?...'
```

`refresh_mihomo_config.sh` refreshes an existing mihomo installation without
reinstalling mihomo or MetaCubeXD. It downloads the subscription config, runs a
temporary Clash Verge compatible JavaScript customizer from GitHub, writes the
transformed result to `/etc/mihomo/config.yaml`, stores the subscription URL in
`/etc/mihomo/subscription.url`, and restarts `mihomo.service`. The downloaded
customizer lives only in the script's temporary directory and is removed when
the run finishes.

The first run can provide the subscription URL directly:

```bash
refresh_mihomo_config.sh --sub-url 'https://example.com/subscribe?...'
```

After that, the stored URL is used automatically:

```bash
refresh_mihomo_config.sh
```

Defaults match the installer where they overlap:

- HTTP proxy: `127.0.0.1:7897`
- SOCKS proxy: `127.0.0.1:7891`
- external controller: `0.0.0.0:9090`
- external UI path: `/etc/mihomo/ui`
- stored subscription URL: `/etc/mihomo/subscription.url`
- customizer URL:
  `https://raw.githubusercontent.com/zhangrun-HIT/clash-subscription-customizer/main/clash-verge-script.js`

Use another GitHub raw URL if needed:

```bash
refresh_mihomo_config.sh --customizer-url https://raw.githubusercontent.com/OWNER/REPO/BRANCH/file.js
```

Preview the refresh without changing the system:

```bash
refresh_mihomo_config.sh --dry-run
```

## Local Proxy Config

```bash
configure_proxy.sh
configure_proxy.sh --proxy 192.168.31.10:7897
```

`configure_proxy.sh` only configures this machine's proxy settings. It does not
install or manage mihomo. By default it writes `127.0.0.1:7897` into shell,
`/etc/environment`, system/global git, and Docker systemd proxy settings. Apt is
left unchanged by default; pass `--apt` only when apt should also use the proxy. When it
runs inside a Docker container on WSL, the default proxy becomes
`host.docker.internal:7897` so the container can reach the WSL/Docker host
proxy.

For a preview:

```bash
configure_proxy.sh --dry-run
```

To remove the settings managed by the script:

```bash
configure_proxy.sh --unset
```
