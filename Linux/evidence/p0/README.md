# P0 原始验证输出

见 [`../../docs/p0-status.md`](../../docs/p0-status.md) 的结果、失败解释和未验收项。此目录不修改前两轮 `Evidence/LinuxHost/` 的资料。

`manifest.json` 保存证据哈希和最终 canonical 文件哈希。早期 GPU/CPU/clean-load 失败日志一并保留，不算通过项。历史日志不冒充全部由最终源码同一次运行产生。

实际结果：47项scrap和88项root测试通过（1项上游忽略），CPU H264/HEVC接口回归通过，GPU合成色卡/序号/租约和有界池检查通过；60秒720帧及资源计数已保存。`viewer-color-contract-01.json` 是源码系数推算，不是Mac实测。P0整体和P1均未宣称完成。
