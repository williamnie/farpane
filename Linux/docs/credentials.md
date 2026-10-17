# FarPane Linux GUI：远端密码与设备名称

原生 GUI 通过登录用户会话中的 Secret Service 保存**远端连接密码**。这与本机 Host 的固定密码、网络身份和服务配置是不同的存储路径；本机固定密码仍不可读回。原生版尚未完成完整打包和真实桌面验收。

## 用户操作与存储边界

视频和文件连接共用认证控件。默认不保存密码；用户勾选“验证成功后保存到系统密码库”，且核心确认认证成功后，才提交保存。错误密码、一次性验证码不写入；二次验证期间仅保留当前待保存密码。通常点击“使用已保存密码”读取密码库，填入遮蔽的输入框后仍需验证连接。启动首页、打开认证页都不会自动读取钥匙环。

Viewer 的“断线后使用系统密码库自动重连（最多 4 次）”是另一项明确授权，默认关闭，只绑定当前设备、服务器与本次会话。已呈现的连接在核心允许的网络错误后重建时，可读取并提交一次该范围的保存密码；取消、服务器变化、密码错误、二次验证或不安全连接确认立即停止。不会将保存密码默认启用为自动重连，也不会在文件连接中自动读取。详细边界见[自动重连合同](viewer-recovery.md)。

认证页和设备编辑页均提供明确确认后的“忘记已保存密码”。忘记设备可选择只删除记录，或同时删除密码。后一项先确认密码库删除成功，再提交带 revision 的记录删除；若配置发生并发变化，记录删除可被拒绝，此时已成功的密码删除不会被冒充为回滚。取消正在进行的操作只表示客户端取消等待，不能保证已经提交给服务端的保存/删除被撤回。

密码库不可用、仍锁定、用户取消或返回冲突记录时显示具体类别，用户可手动输入继续连接。没有明文文件、TOML、portal 文件后端或核心 PeerConfig 保存密码的回退路径。GUI 在 root、真实/有效 UID 不一致、明确的非用户会话类或缺少用户会话总线时拒绝访问；普通用户 UID 不要求大于等于 1000。登录前/greeter 和其他用户钥匙环不属于当前支持范围。

锁定时不主动调用 Secret Service `Unlock`：提示先在系统密码管理器中解锁，再重试读取/保存/删除。保存要求已有未锁定的默认 collection；没有默认存储时提示在系统密码管理器中创建，不替用户初始化钥匙环。这一选择来自隔离测试：GNOME Keyring 50 在连续取消 `Unlock` 后触发 `gkd-secret-unlock.c:243` 的 `!self->current` 断言并退出。失败日志会与最终检查点一同保留，不能把该次解锁测试称为通过。其他提供者仍可能为自身的创建/删除策略提示用户，所有实际调用仍携带取消对象。

`org.farpane.RemotePassword.v1` schema 仅有 `peer` 与 `scope` 两项属性。`scope` 是设备目录使用的服务器范围 JSON（小写 ID 服务器地址、公钥）的 SHA-256；relay 地址不参与身份。不能把不同服务器、公钥或设备的密码混用。属性不是保密字段，只有 SecretValue 存储密码；记录标签只包含 FarPane 和设备标识。

## 实现与资源

- `gui/src/credentials.rs` 管理按需工作线程和取消；整个 GUI 最多同时两个操作，60 秒后请求取消，主线程不 join 未完成线程。待保存的有界副本在丢弃时覆盖；这不代表 GTK、IPC 序列化或整个进程内存都经过清零。
- `gui/src/secret_service.c` 通过公开 libsecret 头文件核对 ABI，首次显式操作才动态加载 `libsecret-1.so.0`。GUI 不硬链接 libsecret；核心和 Viewer 不加载它。每次操作建立指向 `org.freedesktop.secrets` 的独立 service proxy，使用可取消的同步调用，仅在工作线程运行。
- 查找包含锁定记录，但不请求解锁；不能把锁定当作没有保存密码。读取要求唯一记录、UTF-8、1–4096 字节且无内嵌 NUL。保存通过现有 collection 的 `Item.create_sync(REPLACE)`，避免 `Service.store_sync` 的自动解锁/创建 collection 流程。删除后再搜索包含锁定项的整个匹配范围，确认无匹配项才报告成功。原始 GError 和密码不进入状态文案或日志。
- 设置中的操作使用可取消的临时对话框；认证页同时提供取消按钮及提示。密码读取结果绑定认证代，提交手动密码、切换认证挑战或结束会话后，旧结果不能回填新认证。
- Secret Service 提供者的增量内存需单独计入验收；测试专用 GNOME Keyring 的 PSS 会随 GUI/Host/Viewer 一同记录。不能仅报告 GUI 内存就称密码保存没有成本。

## 设备名称

核心从认证后的 PeerInfo 取得主机名，去除控制字符并按 UTF-8 边界限制为 128 字节。会话标题显示名称和 ID；首次实际呈现后，名称与最近连接记录经唯一配置 owner/revision 持久化。列表显示优先级为用户别名、远端名称、ID，三者均可搜索。旧设备记录缺少 `remote_name` 时按空字符串读取。

## 验证范围与待验收项

隔离容器使用私有 Xvfb、D-Bus、GNOME Keyring、临时配置和合成密码，不挂载宿主会话总线、显示、密码库或服务配置。已验证错误密码不保存、认证后保存、第二个 GUI 读取后真实连接、服务暂停时取消并手动连接、确认删除、设备页取消/删除、服务器公钥和设备范围隔离，以及主机名称持久化与搜索。测试运行日志在 `Build/Linux/native-viewer-smoke/`；完成检查点后归档 Evidence。

KWallet 等其他提供者、真实桌面的手动解锁/默认 collection 初始化、2FA 服务器、异常退出与长稳资源仍需独立验收。容器里的 GNOME Keyring 结果不代表所有 Linux 桌面均已验证。完整原生安装包与跨发行版 ABI 验证仍未完成。

## 公开 API 依据

[SecretSchema](https://gnome.pages.gitlab.gnome.org/libsecret/struct.Schema.html) 定义匹配属性；[open_sync](https://gnome.pages.gitlab.gnome.org/libsecret/type_func.Service.open_sync.html) 允许选择明确服务；[search_sync](https://gnome.pages.gitlab.gnome.org/libsecret/method.Service.search_sync.html) 的解锁标志不保证所有项目成功解锁。[Collection.for_alias_sync](https://gnome.pages.gitlab.gnome.org/libsecret/type_func.Collection.for_alias_sync.html) 查找已有存储；[Item.create_sync](https://gnome.pages.gitlab.gnome.org/libsecret/type_func.Item.create_sync.html) 可替换匹配属性的记录；[Item.delete_sync](https://gnome.pages.gitlab.gnome.org/libsecret/method.Item.delete_sync.html) 删除项目。同步调用可能等待系统提示，因此放在工作线程。简单的 [password_clearv_sync](https://gnome.pages.gitlab.gnome.org/libsecret/func.password_clearv_sync.html) 不适合作为删除锁定记录后确认全部清除的替代。
