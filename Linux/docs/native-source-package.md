# FarPane Linux GPU 媒体重构（linux-host）：从源码构建结果打包

完整源码构建的输出可直接打包，不需要覆盖当前产品的 `native-build.json`、FFmpeg 前缀或 Cargo target。入口只生成开发候选，不执行安装或服务/桌面切换。

## 二进制包

在仓库或新源码包根目录执行（系统需要 Python 3.11+、binutils、patchelf；Debian 打包还需要 dpkg）：

```sh
python3 -B Scripts/linux/package-native.py \
  --source-build /path/to/completed/application.BUILD
python3 -B Scripts/linux/package-native-deb.py \
  Build/Linux/artifacts/farpane-native-dev-ARTIFACT \
  --version 0.1.0~dev.YYYYMMDD.N
```

将路径和版本换为实际值。源码构建目录可以只读挂载，输出留在执行入口所在源码根的 `Build/Linux/artifacts` 和 `Build/Linux/debian`。不要求该目录存在 `.git`。标准默认产品打包入口仍读取当前产品 receipt；`--source-build` 显式选择独立构建。

`native_package_source.py` 核对原编译快照、其中的 canonical 源码记录、四阶段日志、实际核心/GUI/媒体库哈希以及当前应用源码。应用源码不一致会拒绝打包。包内新 receipt 使用实际编译产生的二进制哈希，原编译目录和产品 receipt 均不改写。

`build.json` 分别记录编译来源与打包来源：

- `source_build` 绑定实际构建结果、编译输入快照、依赖前缀清单和 builder image。
- `source_origin` 记录打包所在的 Git 根或源码快照原 manifest 哈希。只有源码根自身有 `.git` 才查询 Git；解压目录不会借用外层仓库的 HEAD。
- 源码快照下 `source_head` 与 `source_dirty` 为 null；这不是伪造提交或宣称目录无变更。最终包的全部文件仍由内容清单覆盖，应用源码另由 receipt 核对。

同一应用源码可以配合更新的打包工具/文档交付；编译时的快照哈希和本次交付快照哈希分别保存，不假称重新编译或按位复现。

## 对应源码交付

`package-native-source.py --source-build` 将源码清单和 `binary-build-receipt.json` 绑定到上述独立构建；重建后的 prepared trees 与实际编译目录逐文件比较，生成日期文件从该编译目录单独捕获。Cargo vendor、非 FFmpeg 配方、源归档和许可补充仍按既有固定输入核验。

```sh
python3 -B Scripts/linux/package-native-source.py \
  --reference /path/to/read-only/source-reference \
  --vendor Build/Linux/source-bundles/work/vendor \
  --vendor-config Build/Linux/source-bundles/work/vendor-config.toml \
  --source-build Build/Linux/native-bootstrap/application.BUILD
```

新源码包包含根目录 `THIRD_PARTY_NOTICES.md`，供独立二进制打包使用。旧冻结归档不重写。源码包的 `compiled_source_build` 指向实际编译证据；`fresh_full_build_verified=false` 仍表示没有声称从新归档的每一字节重新做一次空缓存编译，不能据此省略已记录的编译来源。

源码归集本身仍使用只读 reference 的固定 Git 对象和现有 vendor 输入；这不是已经完成公共网络 bootstrap/CI 的声明。运行与发布验收、完整许可审计、真实桌面/GPU/性能以及维护窗口要求保持不变。

## 实际交付检查（2026-10-17）

交付归档 `514e82df…` 包含 88,621 个条目，绑定完整源码构建 `application.fQLWLQG3` 的结果 SHA-256 `c6dbcbaa7ff0866088465a1f178c58760affc85019ea5966cbdaf6476014561b`。`package.voOsdKkO` 在只读输入、全新输出、普通 UID、4 CPU/12 GiB、断网且没有 Git 工作区的 Ubuntu 24.04 容器中，核对整个归档，并用其自身入口生成 bundle 和 Debian `.5`。没有重新编译程序或媒体库，没有覆盖原产品构建记录。`test-native-source-package.sh` 是外部测试驱动，生成于该归档冻结之后；不声称它在归档内。

| 输出 | SHA-256 |
| --- | --- |
| `farpane-native-source-514e82dfb17b17ebe6892725.tar.gz` | `a4ac71805d46eb123313859ab5081fbde547814fac8780ca40f4e06786589af6` |
| `farpane-native-dev-5ad72a016972fad57d895c5e.tar.gz` | `f5ca75d7ff6200f9b350d0e2bae842ef8477a1f1dfa7e0362ef285780b8782ec` |
| `farpane-native-candidate_0.1.0~dev.20261017.5_amd64.deb` | `0880de6640ee0718762639c84ac97ac86e0cd853c9f3952dc1633047ed684060` |

同一包完成以下独立检查：

- Ubuntu 24.04/26.04 各八类包/私有库检查及两次实际软件视频连接，覆盖 GTK 呈现、错误密码重试、Viewer 回收和 Host/设置保留。
- 限定 renderD128、256×128/12 fps 静态夹具的两次私有 Wayland GPU 连接；VAAPI、DMA-BUF 和 after-paint 完成，无软件帧回退。86 次现有 FarPane 空闲查询全为零，约 17.25 秒。
- 两个 Ubuntu 环境各六类实际 `.4 → .5` dpkg 检查，覆盖两个不同 artifact 的暂存、未完成维护事务拒绝配置、恢复配置、升级后 `.5` GUI 两次连接及 purge 保留旧版本。现有测试原本只覆盖同 artifact 的版本号升级，现已明确验证不同 artifact 并运行升级后的二进制。
- 15 项既有 bundle 完整性测试；真实编译结果加载、应用源码不一致拒绝，以及嵌套解压目录不误用外层 Git HEAD。

所有连接都是短时功能夹具；软件会话各呈现 1–2 帧，GPU 会话各完成 1 帧。不是帧率、长稳、真实桌面、Ubuntu 24.04 GPU 或低内存验收。dpkg 中保留的是私有哨兵进程/服务文件，不代表真实 systemd 激活。源码归档本身的 `fresh_full_build_verified=false` 与完整许可审计 false 保持原值；实际编译证明另行绑定旧输入快照。

完整输入、日志、包内/实际测试二进制哈希和边界核对见[本轮证据](../../Evidence/LinuxHost/2026-10-17-native-source-package/README.md)。当前产品 receipt、既有 FFmpeg 库和两个服务的 PID/状态未变；`.4` 原候选仍保留，`.5` 未安装到 linux-host。
