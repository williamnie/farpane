# FarPane Linux GPU 媒体重构（linux-host）：.8 安装与实机失败

2026-10-19，北京时间。用户明确要求安装，已完成 stage → plan → activate → 用户 bind。没有宿主 dpkg、/usr 写入、产品重编译、Mac 或 RustDesk 操作。新核心 79e6fd6f2505d006beeb4e71 / c403acbf… 确实运行，原 root 64215、Host 1362864 与旧 GUI 已退出。新 root 1474136；Host 初始 1474420，随后自身 supervisor 记录 RestartIdle，换为 1476403，后者已再次核对核心哈希、注册状态与实机一条入站。root 未重启。ID、固定密码/密钥及全部 options 前后一致，旧版保留；私有备份仅在忽略的 Build 维护目录。

用户实机反馈“仍然没有中文”。日志 inode/offset 连续，检测到 3 条非 ASCII 提交（chars 2、3、6）、释放掩码均 0，每条之后有 clipboard written / ready / paste queued。另有一组 ready/queued 没有对应 INFO 行，可能受限流影响，不从缺行推断没收到。没有输出正文/正文哈希。写入成功是 API 返回，入队不是内核或应用消费确认；真实根因仍未确认。

用户随后质疑界面一直连接、未观察到断开，要求 GUI 显示版本。本次已证明进程代际替换，但尚未解释用户未见断开的现象。Codex 接手 GUI 版本显示，中文输入继续交 Claude。notice 来源映射与完整归档仍待交付收尾，本次不是正式发布。
