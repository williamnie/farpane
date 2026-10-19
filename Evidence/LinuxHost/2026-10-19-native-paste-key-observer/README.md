# FarPane Linux GPU 媒体重构（linux-host）：按键观察工具准备证据

工具准备后，用户明确批准的 30 秒实机观察已完成；正常到时退出，用户仍报告无文字。范围、命令、实测结果和权限边界见 [native-paste-key-observer.md](../../../Linux/docs/native-paste-key-observer.md)。

- `first-failure/`：首轮私有 VM 发现枚举临时 FD 消失误报，保留原始失败。
- `passed/`：修复后私有 VM 的磁盘来源、运行命令、内核结果与串口记录。观察者收到完整 Shift/Insert 四事件，普通键由内核过滤；另一个 reader 收到全部事件，说明无独占或消费干扰。
- `checks.json`：本轮单元测试和边界检查结果。
- `source-sha256.json`：canonical 观察器、VM 夹具及测试的源码哈希。
- `real-capture/`：本次授权的宿主 event7 过滤记录，22 个白名单事件，五组完整 Shift/Insert，无 Ctrl/Alt/Meta，无丢帧；以及只包含元数据的现有日志阶段。CLI exit 0，没有遗留采集任务。

仅在私有 guest 中创建虚拟键盘及注入人工夹具；宿主窗口只打开已绑定 FarPane 的 event7 观察，不注入/独占。实机验证了内核事件流，未验证桌面/应用消费，不能据此关闭中文输入缺陷。没有产品新版本。
