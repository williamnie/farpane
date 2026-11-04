//! 更新选择只使用公开 Release 元数据，不下载或执行安装包。
use serde::Deserialize;
use std::{cmp::Ordering, time::Duration};

pub const RELEASES_URL: &str = "https://github.com/williamnie/farpane/releases";
pub const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
pub const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 60);
pub const RESPONSE_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Version {
    numbers: [u64; 3],
    prerelease: Vec<String>,
}

impl Version {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.strip_prefix('v').unwrap_or(text);
        if text.is_empty() || text.len() > 128 {
            return None;
        }
        let mut build_parts = text.split('+');
        let version = build_parts.next()?;
        if let Some(build) = build_parts.next() {
            if !identifiers_valid(build, false) || build_parts.next().is_some() {
                return None;
            }
        }
        let (numbers, prerelease) = match version.split_once('-') {
            Some((numbers, pre)) if identifiers_valid(pre, true) => {
                (numbers, pre.split('.').map(str::to_owned).collect())
            }
            Some(_) => return None,
            None => (version, Vec::new()),
        };
        let numbers: Option<Vec<_>> = numbers
            .split('.')
            .map(|part| {
                if part.is_empty()
                    || !part.bytes().all(|b| b.is_ascii_digit())
                    || (part.len() > 1 && part.starts_with('0'))
                {
                    return None;
                }
                part.parse().ok()
            })
            .collect();
        Some(Self {
            numbers: numbers?.try_into().ok()?,
            prerelease,
        })
    }
}

fn identifiers_valid(text: &str, reject_numeric_leading_zero: bool) -> bool {
    text.split('.').all(|part| {
        !part.is_empty()
            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !(reject_numeric_leading_zero
                && part.len() > 1
                && part.starts_with('0')
                && part.bytes().all(|b| b.is_ascii_digit()))
    })
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        let numeric = self.numbers.cmp(&other.numbers);
        if numeric != Ordering::Equal {
            return numeric;
        }
        match (self.prerelease.is_empty(), other.prerelease.is_empty()) {
            (true, false) => return Ordering::Greater,
            (false, true) => return Ordering::Less,
            _ => {}
        }
        for (left, right) in self.prerelease.iter().zip(&other.prerelease) {
            let ordering = match (
                left.bytes().all(|b| b.is_ascii_digit()),
                right.bytes().all(|b| b.is_ascii_digit()),
            ) {
                (true, true) => left.len().cmp(&right.len()).then_with(|| left.cmp(right)),
                (true, false) => Ordering::Less,
                (false, true) => Ordering::Greater,
                (false, false) => left.cmp(right),
            };
            if ordering != Ordering::Equal {
                return ordering;
            }
        }
        self.prerelease.len().cmp(&other.prerelease.len())
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Release {
    pub tag: String,
    pub preview: bool,
}

impl Release {
    pub fn url(&self) -> String {
        // tag 先通过严格版本解析；不打开服务端传入的任意 URL。
        format!("{RELEASES_URL}/tag/{}", self.tag)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CheckResult {
    Available(Release),
    Current,
}

#[derive(Deserialize)]
struct ReleaseMetadata {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    state: String,
    size: u64,
}

pub fn select_release(
    bytes: &[u8],
    current: &str,
    architecture: &str,
) -> Result<CheckResult, String> {
    let current =
        Version::parse(current).ok_or("当前构建没有可比较的版本号，请前往发布页检查更新。")?;
    if bytes.len() > RESPONSE_LIMIT {
        return Err("更新服务返回的数据过大，请稍后重试。".into());
    }
    let releases: Vec<ReleaseMetadata> =
        serde_json::from_slice(bytes).map_err(|_| "更新服务返回的数据无效，请稍后重试。")?;
    let latest = releases
        .into_iter()
        .filter_map(|release| {
            if release.draft {
                return None;
            }
            let version = Version::parse(&release.tag_name)?;
            if !release.assets.iter().any(|asset| {
                asset.state == "uploaded"
                    && asset.size > 0
                    && matching_asset(&asset.name, &release.tag_name, architecture)
            }) {
                return None;
            }
            Some((version, release))
        })
        .max_by(|(left, _), (right, _)| left.cmp(right))
        .ok_or("尚未找到适用于本机的 Linux 安装包，请前往发布页查看。")?;
    Ok(if latest.0 > current {
        CheckResult::Available(Release {
            tag: latest.1.tag_name,
            preview: latest.1.prerelease,
        })
    } else {
        CheckResult::Current
    })
}

fn matching_asset(name: &str, tag: &str, architecture: &str) -> bool {
    let version = tag.strip_prefix('v').unwrap_or(tag);
    let deb_arch = match architecture {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        _ => return false,
    };
    name == format!("FarPane-{version}-linux-{architecture}.tar.gz")
        || name == format!("farpane-native-candidate_{version}_{deb_arch}.deb")
        || name
            .strip_prefix(&format!("farpane-native-candidate-{version}-"))
            .and_then(|release| release.strip_suffix(&format!(".{architecture}.rpm")))
            .is_some_and(|release| {
                release.starts_with(|c: char| c.is_ascii_digit())
                    && release
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._+".contains(&b))
            })
}

/// 只接受完整、未压缩的成功响应；兼容代理转回 HTTP/1.1 的分块传输。
pub fn http_body(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let boundary = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .filter(|position| *position <= 32 * 1024)
        .ok_or("更新服务返回的响应无效，请稍后重试。")?;
    let header = std::str::from_utf8(&bytes[..boundary])
        .map_err(|_| "更新服务返回的响应无效，请稍后重试。")?;
    let mut lines = header.split("\r\n");
    let mut status = lines.next().unwrap_or_default().split_whitespace();
    if !matches!(status.next(), Some("HTTP/1.0" | "HTTP/1.1")) {
        return Err("更新服务返回的响应无效，请稍后重试。".into());
    }
    match status.next() {
        Some("200") => {}
        Some("403" | "429") => return Err("更新检查暂时受到限流，请稍后重试。".into()),
        _ => return Err("暂时无法访问更新服务，请稍后重试。".into()),
    }
    let body = &bytes[boundary + 4..];
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let (key, value) = line
            .split_once(':')
            .ok_or("更新服务返回的响应无效，请稍后重试。")?;
        match key.to_ascii_lowercase().as_str() {
            "content-length" => {
                let parsed = value
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| "更新服务返回的数据不完整，请稍后重试。")?;
                if length.replace(parsed).is_some() {
                    return Err("更新服务返回的响应无效，请稍后重试。".into());
                }
            }
            "content-encoding" if value.trim() != "identity" => {
                return Err("更新服务返回了不支持的数据编码，请稍后重试。".into());
            }
            "transfer-encoding" => {
                if chunked || !value.trim().eq_ignore_ascii_case("chunked") {
                    return Err("更新服务返回了不支持的数据编码，请稍后重试。".into());
                }
                chunked = true;
            }
            _ => {}
        }
    }
    if chunked {
        if length.is_some() {
            return Err("更新服务返回的响应无效，请稍后重试。".into());
        }
        return decode_chunks(body).ok_or_else(|| "更新服务返回的数据不完整，请稍后重试。".into());
    }
    if length.is_some_and(|length| length != body.len()) || body.len() > RESPONSE_LIMIT {
        return Err("更新服务返回的数据不完整，请稍后重试。".into());
    }
    Ok(body.to_vec())
}

fn decode_chunks(mut bytes: &[u8]) -> Option<Vec<u8>> {
    let mut decoded = Vec::new();
    loop {
        let boundary = bytes.windows(2).position(|window| window == b"\r\n")?;
        let line = std::str::from_utf8(&bytes[..boundary]).ok()?;
        let number = line.split(';').next()?;
        if number.is_empty() || !number.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let length = usize::from_str_radix(number, 16).ok()?;
        bytes = &bytes[boundary + 2..];
        if length == 0 {
            // 尾部只允许空行或合法 trailer；不接受未结束或额外的响应正文。
            while bytes != b"\r\n" {
                let end = bytes.windows(2).position(|window| window == b"\r\n")?;
                if !bytes[..end].contains(&b':') {
                    return None;
                }
                bytes = &bytes[end + 2..];
            }
            return Some(decoded);
        }
        if length > RESPONSE_LIMIT - decoded.len()
            || bytes.get(length..length.checked_add(2)?)? != b"\r\n"
        {
            return None;
        }
        decoded.extend_from_slice(&bytes[..length]);
        bytes = &bytes[length + 2..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn release(tag: &str, asset: &str) -> serde_json::Value {
        json!({"tag_name":tag,"draft":false,"prerelease":true,
            "assets":[{"name":asset,"state":"uploaded","size":100}]})
    }

    #[test]
    fn compares_versions_numerically_and_handles_semver_precedence() {
        let versions = [
            "0.2.9",
            "v0.2.10-alpha",
            "0.2.10-alpha.2",
            "0.2.10-alpha.10",
            "0.2.10-beta",
            "0.2.10",
            "1.0.0",
        ];
        for pair in versions.windows(2) {
            assert!(Version::parse(pair[0]).unwrap() < Version::parse(pair[1]).unwrap());
        }
        assert_eq!(
            Version::parse("1.2.3+first"),
            Version::parse("v1.2.3+second")
        );
        for invalid in [
            "",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.2.3-01",
            "1.2.3+",
            "1.2.3-",
            "1.2.3-rc..1",
            "1.2.3/evil",
            "1.2.3+z+z",
            "-1.2.3",
        ] {
            assert!(Version::parse(invalid).is_none(), "{invalid}");
        }
    }

    #[test]
    fn selects_latest_downloadable_linux_release_including_preview() {
        let mut draft = release("v9.0.0", "FarPane-9.0.0-linux-x86_64.tar.gz");
        draft["draft"] = true.into();
        let data = serde_json::to_vec(&vec![
            release("v0.2.13", "FarPane-v0.2.13-macos-arm64.dmg"),
            release("v0.2.11", "FarPane-0.2.11-linux-x86_64.tar.gz"),
            release("v0.2.12", "FarPane-0.2.11-linux-x86_64.tar.gz"),
            release("v0.2.14", "FarPane-0.2.14-linux-aarch64.tar.gz"),
            release("v0.2.15", "FarPane-0.2.15-linux-source.tar.gz"),
            draft,
            release("v0.2.9", "FarPane-0.2.9-linux-x86_64.tar.gz"),
        ])
        .unwrap();
        assert_eq!(
            select_release(&data, "0.2.9", "x86_64"),
            Ok(CheckResult::Available(Release {
                tag: "v0.2.11".into(),
                preview: true
            }))
        );
        assert_eq!(
            select_release(&data, "0.2.11", "x86_64"),
            Ok(CheckResult::Current)
        );
        assert_eq!(
            select_release(&data, "0.3.0", "x86_64"),
            Ok(CheckResult::Current)
        );
    }

    #[test]
    fn accepts_architecture_specific_packages_but_not_partial_uploads() {
        assert!(matching_asset(
            "farpane-native-candidate_0.2.11_amd64.deb",
            "v0.2.11",
            "x86_64"
        ));
        assert!(matching_asset(
            "farpane-native-candidate-0.2.11-1.fc44.x86_64.rpm",
            "v0.2.11",
            "x86_64"
        ));
        let mut data = release("v0.2.11", "FarPane-0.2.11-linux-x86_64.tar.gz");
        data["assets"][0]["state"] = "starter".into();
        assert!(
            select_release(&serde_json::to_vec(&vec![data]).unwrap(), "0.2.9", "x86_64").is_err()
        );
    }

    #[test]
    fn malformed_or_empty_results_never_report_up_to_date() {
        for data in [
            b"[]".as_slice(),
            b"{}",
            b"{bad",
            b"[{\"tag_name\":\"v1.0.0\"}]",
        ] {
            assert!(select_release(data, "0.2.9", "x86_64").is_err());
        }
        assert!(select_release(b"[]", "0.1.0 · 构建未标识", "x86_64").is_err());
        assert!(select_release(&vec![b' '; RESPONSE_LIMIT + 1], "0.2.9", "x86_64").is_err());
    }

    #[test]
    fn validates_http_status_length_and_encoding() {
        assert_eq!(
            http_body(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n[]").unwrap(),
            b"[]"
        );
        assert_eq!(
            http_body(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n[]").unwrap(),
            b"[]"
        );
        assert_eq!(http_body(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n[\r\n1;ext=ok\r\n]\r\n0\r\n\r\n").unwrap(), b"[]");
        for response in [
            "HTTP/1.1 403 Forbidden\r\n\r\n[]",
            "HTTP/1.1 429 Too Many Requests\r\n\r\n[]",
            "HTTP/1.1 302 Found\r\n\r\n[]",
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n[]",
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n[]",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n[]",
            "not HTTP",
        ] {
            assert!(http_body(response.as_bytes()).is_err(), "{response}");
        }
    }
}
