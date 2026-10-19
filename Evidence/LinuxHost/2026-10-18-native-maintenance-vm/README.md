# FarPane Linux GPU 媒体重构（linux-host）：真实维护 VM 证据

2026-10-18。本轮用冻结 `.20261018.1` / `.20261018.3` Debian 包验证真实 systemd、logind、GNOME 会话和用户 D-Bus 下的安装、升级、回退与移除。产品未重编、候选未改写、linux-host 未切换；中文输入方案仍暂停。

## 实际结果

最终固定磁盘 `Build/Linux/native-input-vm/disk.2xse7dgi`：

| 运行 | 结果 | 范围 |
| --- | --- | --- |
| `run.k60ifgcg` | 退出 0 | 六组维护检查通过，guest 正常关机 |
| `run.7qibqyoe` | 退出 0 | 同一磁盘、新 overlay/boot ID，六组检查再次通过 |

六组分别为真实登录会话、初次安装/激活/用户入口、仅安装新候选时保留旧进程、显式升级协调 root/Host/GUI、系统与用户入口回退、purge 保留运行应用/凭据/无关服务。

第一轮的 root/Host/GUI PID 从 `.1` 的 `739/770/823`，切为 `.3` 的 `1098/1136/1219`，回退到 `.1` 的 `1301/1340/1396`。只安装候选时旧三个 PID/start ticks 完全不变；明确 activate 后旧代不再有可执行进程。每次 GUI 总线 owner 都对应同 release 的真实进程。第二轮独立结果见 `summary.json`，没有用一轮的观察替代另一轮。

私有配置的 `enc_id/key_pair/password/salt` 字段、身份快照、认证/服务器/GPU/设备设置在升级、回退、purge 后保持一致；结果不保存字段正文。一个真实、独立的 systemd 哨兵服务和用户未知 autostart 文件原样保留。包移除后 `/opt` 应用继续运行；系统服务的 disabled 策略未改变。

## 原始失败

`failed-1`（`run.5cri3xre`）停在 GUI 就绪超时；`failed-2`（`run.xa37m6js`）观察到包安装后进程集合不等；`failed-3`（`run.u_xut06n`）在进程已出现时查询 GUI 总线 owner，收到 NameHasNoOwner。它们使用短命 `gio launch` 后的即时进程采样，均失败并正常收尾，不能计入通过。

最终入口等待 `org.freedesktop.Application.Activate` 的真实回执，再核对 PID 和代际；不在应用里加入测试 hook，不修改安装器或让失败自动放行。早期日志不足以把差异归因于产品重启；也没有宣称 `gio launch` 的全部行为已解释或修复。实际 GNOME 菜单点击仍未验收。

## 保存与对应关系

- `passed-1/`、`passed-2/`：原始 serial/journal/核心日志、QEMU 日志、精确命令与结果。所有配置和会话只属于无外网的合成 guest。
- `failed-1/` 至 `failed-3/`：原始失败及各自冻结的测试源码、磁盘记录。没有覆盖旧结果。
- `disk.json`：实际应用/包哈希、guest 单元原模板与生成版本哈希、核心测试源码、固定镜像/公开内核来源。
- `source/`、`source-manifest.json`：最终真实执行的测试和准备器快照，以及其单元、保护测试和说明。历史应用源码归档未被重写。
- `guard-tests.log`：两项维护入口保护与八项原有 guest 入口保护通过。宿主 boot 或非 maintenance 场景在写入/服务控制前拒绝。
- `prepare*.log`、`run-*.log`：外层准备/运行的完整退出结果；没有归档 8 GiB 基础磁盘或可写 overlay。
- `summary.json`：两轮检查、准确 PID/UID/start ticks/boot ID，以及未验收范围。
- `SHA256SUMS`：本目录文件最终哈希清单。

旧包 SHA-256 `9960dfb15c170d66c23677c006f9c37633f4c9ccf47cd72ab0e1809e8fc353e9`；新包 SHA-256 `476f189cac60495be8b54fad2e0c8070bf904cdfa3420af7af1baa72f68bea64`。只读源磁盘与包均保持原始字节。

## 范围与限制

VM 运行器只开放 `/dev/kvm`，无网卡/宿主共享目录/输入/GPU/用户显示/总线或服务 socket；实际 root/user 服务控制都发生在独立 guest 内核。4 vCPU、6 GiB guest 内存、10 GiB 容器上限，维护流程有 300 秒总时限。虚拟 VKMS 和软件 GNOME 不代表硬件 GPU；此场景不调用中文测试，也没有远程 Viewer/真实连接。

通过的是包事务、真实系统服务代际协调和 D-Bus/文件入口绑定。没有证明线上 ID 注册、固定密码真实远端登录、逐像素首页显示、真实连接中的升级、旧 Flutter P1 回退、断电/重启恢复、多用户/greeter、KDE 或 Fedora SELinux。内存目标、中文缺陷、24 小时长稳、完整许可/发布检查仍未完成。

复现和完整边界见[维护 VM 说明](../../../Linux/docs/native-maintenance-vm.md)。所有测试已终态，宿主 `.1` 的服务、ID、配置和连接保持原状；未提交、推送、发布或部署。
