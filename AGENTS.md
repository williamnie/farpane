# FarPane 代理工作规则

本仓库公开在 GitHub，并且已有 fork。提交、文档、日志、证据和提交信息一经推送即视为公开，事后删除也无法保证撤回。

## 隐私与本地环境信息

提交或推送前，以下内容不得出现在任何文件、压缩包内文件或提交信息中：

- 本机绝对路径和用户名：家目录、`/Users/<用户>`、`Documents/<用户>/...` 等。文档写仓库相对路径；日志和证据中的仓库根写 `/home/user/farpane`，家目录写 `/home/user`（macOS 写 `/Users/user`）。
- 主机名和机器昵称：真实主机统一写 `linux-host`，Mac 写 `Mac mini` 或 `mac-host`。
- 局域网地址、自建 ID/Relay 服务器地址、域名：IP 用文档保留段 `192.0.2.x`，域名用 `example.com`（如 `id.example.com`）。
- 真实设备 ID：写 `1000000000`。容器内临时生成的测试 ID 可以保留。
- 与本项目无关的本机服务：不要提交 `docker ps`/容器清单或进程列表的完整输出，只保留与 FarPane 测试相关的条目，并删去其他项目的容器名、端口和挂载。
- 密码、私钥、令牌、会话 Cookie、密码库内容：任何情况下都不写入仓库，包括测试中使用的真实固定密码。测试服务器的临时公钥可以保留。

证据要求：

- 先脱敏再生成哈希。修改证据文件或压缩包后，同步更新 `SHA256SUMS`、`archive-check.json` 等记录的哈希。
- 打包 `.tar.gz`/`.zip` 证据前，先对其中文本文件做同样的替换。文本扫描看不到压缩包里的内容。
- 截图不得显示终端提示符中的用户名/主机名、家目录路径、局域网地址或其他与测试无关的窗口。

## 提交前检查

每次 `git commit` 前，在仓库根目录运行以下命令，两段输出都必须为空：

```sh
pat="$(whoami)|$(hostname)|$( (hostname -I 2>/dev/null; ip -4 -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1) | tr ' ' '\n' | grep -E '^(10|192\.168)\.' | sort -u | sed 's/\./\\./g' | paste -sd'|')"
extra="$HOME/.config/farpane-private-patterns"   # 仓库外的私有规则：每行一个 PCRE（域名、设备 ID、昵称等）
[ -f "$extra" ] && pat="$pat|$(grep -v '^\s*$' "$extra" | paste -sd'|')"
git add -A
git diff --cached --name-only -z | xargs -0 -r grep -IlP "$pat"
git diff --cached --name-only | grep -E '\.(tar\.gz|tgz)$' | while read -r archive; do
  tar xzf "$archive" -O | grep -aqP "$pat" && echo "$archive"
done
```

- 只能用变量名 `archive` 或 `file`，不要用 `path`：zsh 中 `path` 与 `PATH` 绑定，会让后续命令全部找不到。
- `farpane-private-patterns` 只存在于本机，不得提交，也不要把其中的具体值写进本文件或其他文档。
- 提交信息同样适用：提交前确认标题和正文不含上述信息。

## 发现泄漏时

- 尚未推送：修改后重新提交（可修订尚未推送的提交）。
- 已经推送：立即停止并告知用户泄漏的内容和范围。未经用户明确同意，不得重写历史、强制推送、移动标签或删除远程分支。
