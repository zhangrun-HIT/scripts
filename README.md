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
the same `PATH` entry.

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

Preview the generated Docker command without running it:

```bash
run_docker_image.sh yopo:latest yopo --dry-run
```

The runner detects WSL automatically. In WSL, it adds WSLg and `/dev/dxg`
bindings and rewrites container proxy values from `127.0.0.1` to
`host.docker.internal`. It uses proxy port `7897`, GPU support, host networking,
privileged mode, and `~:/root/host_home` by default.

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
