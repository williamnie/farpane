# FarPane Linux GPU 媒体重构（linux-host）：中文输入设计讨论

2026-10-19（用户时区）。用户明确要求使用 ocs 与新 Claude 线程讨论。实际收件人为 `claude-08da8438` / `farpane-96`，没有唤醒旧线程，没有委派实现。

- `request.txt`：发给新线程的现象、版本、证据、问题和只读边界。
- `delivery.txt`：第一次带空闲通知的调用在存储前失败；当前 ocs 0.8.3 的该功能要求 Claude 来源。
- `delivery-without-idle-subscription.txt`：移除通知选项后，seq 6 成功存储并获 inbox 接收，接收不等于已读。
- `followup.txt` / `followup-delivery.txt`：Codex 的三个额外核查点，seq 7 仅存储，未声称该次唤醒成功，也未重发。
- `thread-read-3.json` / `claude-initial-review.txt`：Claude seq 8 的完整初稿。包含尚未验证的建议和后来被修正的表述，不可直接当成最终实施方案。
- `challenge.txt` / `challenge-delivery.txt`：Codex seq 9 对四项关键边界的反证与收敛要求，inbox 接收。
- `thread-read-4.json` / `claude-final-response.txt`：Claude seq 10 同意修正，并收回未知状态下无条件释放修饰键的建议。
- `codex-review-notes.txt` / `reviewed-source-hashes.json`：Codex 独立核查记录和当时源码身份；包含一个经继续读代码排除的 Shift 怀疑，没有将其计为缺陷。

最终采用的表述见 [讨论结论](../../../Linux/docs/chinese-input.md)。尤其不能把剪贴板读取等同于焦点应用消费，也不能把 IBus 研究候选称为已实现的通用输入后端。纯 ASCII 修饰键和剪贴板竞争在本轮只做源码评审，没有新动态复现。

产品、Mac 文件、依赖 pin、暂停的输入草稿和当前安装均未修改；没有构建、测试、部署、桌面操作、读取真实剪贴板正文或新的提交/推送。本轮仅新增本证据和更新讨论文档。
