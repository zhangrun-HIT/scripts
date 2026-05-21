# 个人脚本工具箱

这个仓库放的是日常在 WSL、Ubuntu、Docker、代理和 mihomo 环境里反复会用到的小脚本。默认推荐先运行 `install_path.sh`，把仓库加入 `PATH`，之后就可以在任意目录直接调用这些命令。

## 安装到 PATH

在仓库目录下运行：

```bash
./install_path.sh
source ~/.bashrc
```

`install_path.sh` 会在 `~/.bashrc` 中写入一个受管理的配置块：

- 设置 `USER_SCRIPTS_DIR` 指向当前脚本仓库。
- 把脚本仓库加入 `PATH`。
- 在交互式 Bash 中自动加载 `completions/*.bash` 里的补全脚本。
- 重复运行时会更新旧配置块，不会重复追加多份 PATH。

## 启动前自动更新

每个可直接运行的脚本都会在真正执行前快速检查当前仓库是不是落后于远端分支：

- 仓库干净且本地落后远端时，脚本会执行 `git pull --ff-only`，然后用最新版本重新启动当前脚本。
- 如果仓库有本地未提交改动、分支发生分叉、没有 Git、没有网络、不是 Git 仓库，脚本会跳过自动更新并继续执行本地版本。
- 检查会尽量快速完成，避免因为网络问题长时间卡住。
- 临时跳过自更新可以设置：

```bash
SCRIPTS_SELF_UPDATE=0 configure_proxy.sh --dry-run
```

内部实现放在 `lib/self_update.sh`，这个文件是公共辅助库，不需要手动运行。

## 脚本清单

### `install_path.sh`

用途：把当前脚本仓库安装到当前用户的 Bash 环境中。

它适合在新机器、WSL、服务器或刚 clone 仓库后运行一次。运行后，新开的 shell 会自动找到本仓库里的脚本命令，也会自动加载 Docker 镜像名补全等补全脚本。

常用命令：

```bash
cd ~/tools/scripts
./install_path.sh
source ~/.bashrc
```

如果要把别的目录写入 PATH，也可以显式传入目录：

```bash
./install_path.sh /home/zhangrun/tools/scripts
```

### `run_docker_image.sh`

用途：用统一方式启动带 GPU、GUI、host 网络、代理和常用挂载的 Docker 容器。

它主要服务 ROS、无人机、YOPO、EGO-Planner、Fast-Drone 这类需要图形界面、GPU 或宿主机源码挂载的开发容器。脚本会根据当前环境自动处理 WSL 和普通 Ubuntu 的差异。

默认行为：

- 默认启用 GPU 参数、`--privileged`、`--network host`。
- 默认挂载 `~:/root/host_home`。
- 默认共享内存大小为 `16g`。
- 默认入口是 `bash`。
- 在 WSL 中自动添加 WSLg、`/dev/dxg`、图形和音频相关挂载。
- 在 WSL 中把容器里的 `127.0.0.1` 代理改写成 `host.docker.internal`。
- 在普通 Ubuntu 中保留 `127.0.0.1` 代理。
- 进入容器前会写入受管理的 shell、apt、git 代理配置和 GUI 环境变量，重复运行不会堆叠重复配置。

常用命令：

```bash
run_docker_image.sh yopo:latest yopo
run_docker_image.sh base_image:ubt20-ros1-cda ego-planner
run_docker_image.sh local/fastdronexi35:pc fast-drone --workspace ~/code/Fast-Drone-XI35:/root/Fast-Drone-XI35
```

挂载说明：

- `--workspace SRC[:DST]` 是主工作目录挂载，只能设置一个；不传时默认 `~:/root/host_home`。
- `--volume SRC:DST` 是额外挂载，可以重复传多个。

预览 Docker 命令但不启动：

```bash
run_docker_image.sh yopo:latest yopo --dry-run
```

常用选项：

- `--proxy none`：不向容器写入代理。
- `--proxy auto`：从当前 shell 的 proxy 环境变量推断代理。
- `--proxy 7897` 或 `--proxy 192.168.31.6:7897`：指定代理端口或地址。
- `--replace`：如果同名容器已经存在，先删除再创建。
- `--no-gpu`：不传 GPU 参数。
- `--no-privileged`：不使用 privileged 模式。
- `--entrypoint CMD`：覆盖默认入口。

补全：

```bash
run_docker_image.sh yo<Tab>
```

补全逻辑来自 `completions/run_docker_image.bash`，它只负责给 `run_docker_image.sh` 补全本地 Docker 镜像名，不需要单独运行。

### `configure_proxy.sh`

用途：给当前机器配置或移除通用代理环境。

它只负责系统代理设置，不安装 mihomo。适合在已经有可用代理端口时，把 shell、git、Docker、可选 apt 代理统一写好；也适合一键清理这些代理设置。

默认代理选择：

- 普通 Ubuntu 默认使用 `127.0.0.1:7897`。
- WSL Docker 容器中默认使用 `host.docker.internal:7897`。
- 显式传 `--proxy` 时，以用户传入值为准。

常用命令：

```bash
configure_proxy.sh
configure_proxy.sh --proxy 192.168.31.6:7897
configure_proxy.sh --proxy http://127.0.0.1:7897 --all-proxy socks5h://127.0.0.1:7897
configure_proxy.sh --unset
```

它会写入或清理：

- 当前用户 `~/.bashrc` 中受管理的代理块。
- `/etc/profile.d/proxy.sh`。
- `/etc/environment` 中的代理变量。
- git 的 system/global proxy。
- GitHub SSH 走 `ssh.github.com:443` 的配置块。
- Docker systemd proxy drop-in。
- 可选 apt proxy。

重要默认值：

- 默认不把 HTTP/HTTPS 代理写入系统环境文件，避免 apt 走 HTTP 代理后某些源失败。
- 默认不修改 apt，除非显式传 `--apt`。
- `--http-env` 会把 HTTP/HTTPS 代理也写到系统环境文件。
- `--skip-apt`、`--skip-git`、`--skip-docker` 可以跳过对应部分。

预览但不修改：

```bash
configure_proxy.sh --dry-run
configure_proxy.sh --unset --dry-run
```

### `select_clash_node.py`

用途：测试 Clash Verge/Mihomo 里所有真实节点对 GitHub、Google、YouTube 等常见站点的综合访问速度，并把 `Proxy` 组切换到综合最优节点。

它通过 Mihomo `external-controller` 接口工作。Clash Verge Rev 里需要开启外部控制器；常见地址是 `127.0.0.1:9097`，密钥通常跟配置里的 `secret` 一致。

默认测试目标：

- `https://www.google.com/generate_204`
- `https://www.gstatic.com/generate_204`
- `https://github.com/`
- `https://github.githubassets.com/favicons/favicon.svg`
- `https://avatars.githubusercontent.com/u/9919?v=4`
- `https://api.github.com/rate_limit`
- `https://raw.githubusercontent.com/github/gitignore/main/README.md`
- `https://api.openai.com/v1/models`
- `https://chatgpt.com/`
- `https://www.youtube.com/generate_204`
- `https://www.cloudflare.com/cdn-cgi/trace`

只看排名，不切换：

```bash
select_clash_node.py --dry-run
```

测试并切换 `Proxy` 到最佳节点：

```bash
select_clash_node.py
```

默认切换后会关闭 Clash 现有连接，让浏览器里的 GitHub、Google 等页面重新走新节点。若想保留当前连接，可以传：

```bash
select_clash_node.py --keep-connections
```

如果你的控制器不是默认端口，显式指定：

```bash
select_clash_node.py --api http://127.0.0.1:9097 --secret set-your-secret
```

每个节点每个目标测两轮，更稳但更慢：

```bash
select_clash_node.py --rounds 2
```

只测试名字匹配新加坡或日本的节点：

```bash
select_clash_node.py --include-regex '新加坡|日本|Singapore|Japan'
```

临时替换测试目标，格式是 `name,url[,weight]`：

```bash
select_clash_node.py \
  --target google,https://www.google.com/generate_204,1.2 \
  --target github,https://github.com/,1.2 \
  --target raw,https://raw.githubusercontent.com/github/gitignore/main/README.md,1.0
```

### `install_mihomo_proxy.sh`

用途：安装、更新或卸载 mihomo，并配置 MetaCubeXD UI、订阅、GEO 数据和系统代理。

安装模式会完成一整套 mihomo 环境：

- 自动安装基础依赖。
- 按当前架构下载并安装最新 MetaCubeX/mihomo `.deb`。
- 下载并安装最新 MetaCubeXD Web UI 到 `/etc/mihomo/ui`。
- 下载订阅并写入 `/etc/mihomo/config.yaml`。
- 保存订阅地址到 `/etc/mihomo/subscription.url`。
- 准备 `GeoSite.dat`、`Country.mmdb`、`geoip.metadb`，减少首次启动时 GEO 下载失败。
- 对订阅做基本可用性检查，拒绝空节点配置。
- 对 AnyTLS 节点自动补 `client-fingerprint: chrome`。
- 写入本机 shell、apt、git、Docker 代理配置。
- 启用并重启 `mihomo.service`。
- 启动前运行 `mihomo -t`，避免坏配置写入系统代理后才暴露问题。

安装命令：

```bash
install_mihomo_proxy.sh --sub-url 'https://example.com/subscribe?...'
```

更安全的方式是把订阅地址放到文件中：

```bash
mkdir -p ~/.config/mihomo
chmod 700 ~/.config/mihomo
printf '%s\n' 'https://example.com/subscribe?...' > ~/.config/mihomo/sub_url
chmod 600 ~/.config/mihomo/sub_url
install_mihomo_proxy.sh --sub-url-file ~/.config/mihomo/sub_url
```

首次安装时，如果服务器直连 GitHub、订阅或 GEO 数据源不稳定，可以借用局域网内已有代理：

```bash
install_mihomo_proxy.sh \
  --sub-url-file ~/.config/mihomo/sub_url \
  --download-proxy http://192.168.31.6:7897
```

默认端口：

- HTTP 代理：`127.0.0.1:7897`
- SOCKS 代理：`127.0.0.1:7891`
- 外部控制器：`0.0.0.0:9090`
- Web UI：`http://<server-ip>:9090/ui`

卸载并恢复代理环境：

```bash
install_mihomo_proxy.sh --uninstall
```

卸载模式会：

- 停止并禁用 `mihomo.service`。
- 通过 apt purge 卸载 mihomo 包。
- 默认删除 `/etc/mihomo` 和 `/var/log/mihomo`。
- 删除 `/etc/profile.d/proxy.sh`。
- 从 `/etc/environment` 清理代理变量。
- 删除 `/etc/apt/apt.conf.d/95proxies`。
- 清理 system git proxy。
- 删除 Docker systemd proxy drop-in 并重载/重启 Docker。

如果要保留配置和日志：

```bash
install_mihomo_proxy.sh --uninstall --keep-config
```

当前 shell 已经 source 过的变量不会被子进程反向清掉。卸载后建议打开新 shell，或手动清理：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
```

预览安装或卸载：

```bash
install_mihomo_proxy.sh --sub-url-file ~/.config/mihomo/sub_url --dry-run
install_mihomo_proxy.sh --uninstall --dry-run
```

常用选项：

- `--download-proxy URL`：下载 release、订阅和 GEO 数据时使用现有代理。
- `--user-agent VALUE`：覆盖订阅下载的 `User-Agent`。
- `--header 'K: V'`：给订阅请求追加请求头，可以重复传。
- `--skip-subscription`：保留当前 `/etc/mihomo/config.yaml`。
- `--skip-system-proxy`：不写 shell、apt、git、Docker 代理设置。
- `--skip-docker-proxy`：只跳过 Docker systemd proxy。
- `--keep-config`：卸载时保留配置和日志。

### `refresh_mihomo_config.sh`

用途：刷新已有 mihomo 的订阅配置，不重新安装 mihomo 和 MetaCubeXD。

它适合 mihomo 已经安装好，只想更新 `/etc/mihomo/config.yaml` 的场景。脚本会下载订阅，运行一个临时的 Clash Verge 兼容 JavaScript 自定义脚本，再把转换后的结果写回 mihomo 配置并重启服务。

默认自定义脚本：

```text
https://raw.githubusercontent.com/zhangrun-HIT/clash-subscription-customizer/main/clash-verge-script.js
```

首次刷新可以直接传订阅：

```bash
refresh_mihomo_config.sh --sub-url 'https://example.com/subscribe?...'
```

也可以使用文件：

```bash
refresh_mihomo_config.sh --sub-url-file ~/.config/mihomo/sub_url
```

脚本会把订阅保存到 `/etc/mihomo/subscription.url`。之后可以直接运行：

```bash
refresh_mihomo_config.sh
```

常用选项：

- `--download-proxy URL`：下载订阅和自定义脚本时使用现有代理。
- `--customizer-url URL`：换成自己的 GitHub raw JavaScript 自定义脚本。
- `--config-file FILE`：指定要写入的 mihomo 配置文件。
- `--no-restart`：写配置后不重启 `mihomo.service`。
- `--skip-prerequisites`：跳过依赖安装，只检查当前环境。
- `--dry-run`：只打印计划，不修改系统。

它同样会检查订阅响应是否像可用 mihomo 配置，拒绝空节点配置，并给缺少指纹的 AnyTLS 节点补 `client-fingerprint: chrome`。

## 常用排查

### 脚本没有自动更新

自动更新只在仓库干净、当前分支有可快进远端时执行。如果有未提交改动，先查看：

```bash
git status --short
```

确认不需要保留后再手动处理。不要在有本地实验改动时强行自动 pull。

### 代理配置后当前 shell 仍然没变化

系统文件已经写入后，当前 shell 不会自动继承新环境。打开新终端，或按脚本提示 source 对应文件。

### mihomo 安装后端口拒绝连接

先看服务状态和配置校验：

```bash
systemctl status mihomo --no-pager -l
mihomo -t -d /etc/mihomo
```

如果是首次 GEO 下载失败，重跑安装时加 `--download-proxy`。

### 卸载后当前 shell 还在走代理

打开新 shell，或手动执行：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
```
