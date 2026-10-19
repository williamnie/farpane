# FarPane Linux GPU 媒体重构（linux-host）：Fedora 44/RPM 证据

2026-10-18。冻结 `.20261018.3` 应用完成 Fedora 用户态 bundle 检查与独立 RPM 包装。产品未重编，当前 linux-host 安装未变；暂停的 Warp 应用特判没有参与。完整 GUI 任务继续进行，以下只证明列出的包装与软件连接范围。

## 原始输入与结果

| 检查 | 实际输出 | 结果 |
| --- | --- | --- |
| Fedora bundle 运行 | `Build/Linux/native-package-smoke/20261018T102001Z` | 8 项包/库检查及两次实际软件视频连接通过 |
| Fedora RPM 安装、`.1 → .3` 升级、显式 stage、erase | `Build/Linux/native-rpm-smoke/run-t0ayg7m9` | 7 组事务检查及安装后两次实际软件视频连接通过，退出 0 |
| RPM 包装与重复包装 | `build/package-rpm-tmp.log`、`build/package-rpm-repeat.log` | 同哈希，包内所有 payload 和 7 份工具源码一致 |

四次连接各经过真实 TCP 登录与密码挑战、解码、GTK 呈现与退出回收；没有用静态截图替代连接。截图来自私有 Xvfb 合成桌面。视频检查的九类断言见 console；没有打开音频、文件共享或用户剪贴板。

候选 RPM：`farpane-native-candidate-0.1.0~dev.20261018.3-1.fc44.x86_64.rpm`，19,770,160 字节，SHA-256 `0c0e45b9a67f2e5502d732ccdc1321f7a48106727583056394531fd0b7c05fc7`。旧包由冻结 `.1` 另行包装，仅供升级夹具使用；两个 RPM 的 receipt/checksum 见 `packages/`。应用二进制、manifest 与既有完整应用源码归档哈希见 `artifact.json`。

## 保存内容

- `bundle-raw.tar.gz`：55 份 bundle 运行原始文件，包含图像、事件、映射和库检查。
- `rpm-raw.tar.gz`：58 份 RPM 运行原始文件，包含完整 rpm 命令/返回码、退出状态、事务结果、实际 GUI 事件与图像。
- `archive-check.json`：两份归档逐个条目与原始 Build 文件比较，共 113 份文件字节一致。原始文件没有 symlink，不归档用户配置或宿主桌面。
- `bundle/`、`rpm/`：便于直接查看的报告、截图和运行清单副本；完整事件与进程映射在原始归档。
- `build/`：隔离镜像构建日志、镜像/配方 pin、原始运行输出和包装失败/成功日志。
- `source/`、`source-manifest.json`：本轮实际使用的 24 份包装、安装、测试、镜像与文档源码快照。新增 RPM 配方没有冒充既有应用源码归档的一部分。
- `host-preservation.json`：只读核对当前 release 与原两个核心 PID；没有服务控制、宿主安装或 GPU/输入设备挂载。
- `SHA256SUMS`：本目录文件的最终校验清单。

## 失败与修正

首次包装返回 125 且日志为空。缩小到相同镜像中的 `timeout --kill-after=10 240 python3 -c 'print(123)'`，无 init 返回 125，Docker `--init` 后返回 0 并输出 123；入口据此加入 init。随后 rpmbuild 报只读 `/var/tmp`，保留在 `package-rpm-init.log`。将 RPM `_tmppath` 指定为已有私有可写 `/tmp` 后成功，没有解除只读根或增加宿主写权限。

RPM 安装/升级没有 scriptlets，也没有自动 stage/activate。保留行为检查使用容器内真实文件、常驻私有 shell 与服务单元哨兵，并非真实 systemd 服务切换。未完成事务时，新 RPM 可安装，但显式 stage 拒绝；恢复夹具后 stage 成功，最终 erase 保留两份已暂存包和旧的活动哨兵。

## 验证边界

固定镜像是 Fedora 44 x86_64 用户态，dnf 软件仓库未采用时间快照。运行与包装镜像 ID、Dockerfile 哈希及实际版本清单保留，不声称任意时间重建镜像完全一致。RPM 重复包装一致只绑定这一固定镜像与相同输入。

测试容器无外网、宿主显示/总线/socket、GPU 或输入设备；包事务只修改容器文件系统。运行测试不安装原 RustDesk、宿主 FFmpeg 或应用编译依赖。UID 1000 没有 passwd 记录引发 D-Bus 警告，数字 UID 会话仍通过；不算完整登录/密码库验收。

没有验证 Fedora 自己的内核、SELinux enforcing、真实 systemd/logind、GNOME/KDE/Wayland、GPU、硬件音频、真实 Mac 输入或完整跨平台功能。首页内存目标、24 小时长稳、完整许可来源审计及正式发布仍未通过。中文方案按用户要求暂停讨论。

入口与维护合同见 [RPM 开发候选说明](../../../Linux/docs/native-rpm.md)。没有 commit、push、publish 或宿主安装。
