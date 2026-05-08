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
run_docker_image.sh IMAGE [CONTAINER_NAME] [options]
```

Examples:

```bash
run_docker_image.sh yopo:latest yopo --proxy 7897
run_docker_image.sh base_image:ubt20-ros1-cda ego-planner --proxy 7897
run_docker_image.sh yopo:latest yopo --workspace ~/code:/root/code
run_docker_image.sh yopo:latest yopo --volume ~/datasets:/root/datasets
```

Preview the generated Docker command without running it:

```bash
run_docker_image.sh yopo:latest yopo --proxy 7897 --dry-run
```

The runner detects WSL automatically. In WSL, it adds WSLg and `/dev/dxg`
bindings and rewrites container proxy values from `127.0.0.1` to
`host.docker.internal`.
