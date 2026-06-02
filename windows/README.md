# Windows / WSL Scripts

这个目录放的是面向 Windows 上 Clash Verge Rev 的辅助脚本，但默认在 WSL 里的 Bash/Python 环境运行。

## `update_clash_verge_profile_wsl.sh`

用途：在 WSL 中模拟官方 `Clash Verge v2.4.2` 的订阅更新请求，把拉到的 YAML 写回 Windows 的 profile 文件。

关键点：

- 默认 `User-Agent` 是 `clash-verge/v2.4.2`
- 会优先直连拉取订阅，不继承当前 shell 的代理环境
- 拉取失败时会回退到同目录下的 `*.last-known-good.yaml` 缓存
- 只做校验和覆盖，不会改写 YAML 内容，尽量贴近官方客户端行为

示例：

```bash
windows/update_clash_verge_profile_wsl.sh \
  --sub-url 'http://43.135.28.238/link/Ch1L3KTh50xosaKt?clash=2' \
  --profile-id RmkFk6tnuFxa
```

如果已经知道完整 profile 路径，也可以直接指定：

```bash
windows/update_clash_verge_profile_wsl.sh \
  --sub-url 'http://43.135.28.238/link/Ch1L3KTh50xosaKt?clash=2' \
  --profile-file '/mnt/c/Users/zhangrun/AppData/Roaming/io.github.clash-verge-rev.clash-verge-rev/profiles/RmkFk6tnuFxa.yaml'
```

## `select_clash_node.py`

这是顶层 [select_clash_node.py](../select_clash_node.py) 的同目录入口，方便从 `windows/` 目录直接运行，不会和 Ubuntu 侧脚本混在一起。
