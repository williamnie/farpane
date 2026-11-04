use crate::updates::{http_body, select_release, CheckResult, RESPONSE_LIMIT};
use gtk::gio::{self, prelude::*};

pub fn check(current: &str, cancel: &gio::Cancellable) -> Result<CheckResult, String> {
    // GIO 默认校验证书及主机名；使用桌面的代理和 TLS 后端，不携带认证或设备信息。
    let client = gio::SocketClient::new();
    client.set_tls(true);
    client.set_timeout(15);
    let connection = client
        .connect_to_uri("https://api.github.com", 443, Some(cancel))
        .map_err(|_| "无法连接更新服务，请检查网络及系统 TLS 支持后重试。")?;
    let request = concat!(
        "GET /repos/williamnie/farpane/releases?per_page=100 HTTP/1.0\r\n",
        "Host: api.github.com\r\n",
        "User-Agent: FarPane-Update-Checker\r\n",
        "Accept: application/vnd.github+json\r\n",
        "Accept-Encoding: identity\r\n",
        "X-GitHub-Api-Version: 2022-11-28\r\n",
        "Connection: close\r\n\r\n"
    );
    let (written, error) = connection
        .output_stream()
        .write_all(request.as_bytes(), Some(cancel))
        .map_err(|_| "更新检查请求未完成，请稍后重试。")?;
    if error.is_some() || written != request.len() {
        return Err("更新检查请求未完成，请稍后重试。".into());
    }
    let input = connection.input_stream();
    let mut response = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        let count = input
            .read(&mut buffer, Some(cancel))
            .map_err(|_| "更新检查超时或连接中断，请稍后重试。")?;
        if count == 0 {
            break;
        }
        if response.len() + count > RESPONSE_LIMIT + 32 * 1024 {
            return Err("更新服务返回的数据过大，请稍后重试。".into());
        }
        response.extend_from_slice(&buffer[..count]);
    }
    select_release(&http_body(&response)?, current, std::env::consts::ARCH)
}
