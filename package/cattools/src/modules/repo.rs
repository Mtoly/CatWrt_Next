use crate::error::{CatoolsError, Result};

#[derive(Debug, PartialEq, Eq)]
pub struct Mirror {
    pub key: &'static str,
    pub label: &'static str,
    pub base: &'static str,
}

pub const MIRRORS: [Mirror; 7] = [
    Mirror {
        key: "official",
        label: "官方源",
        base: "https://downloads.immortalwrt.org",
    },
    Mirror {
        key: "vsean",
        label: "vsean 镜像（默认）",
        base: "https://mirrors.vsean.net/openwrt",
    },
    Mirror {
        key: "ustc",
        label: "中国科学技术大学",
        base: "https://mirrors.ustc.edu.cn/immortalwrt",
    },
    Mirror {
        key: "nju",
        label: "南京大学",
        base: "https://mirror.nju.edu.cn/immortalwrt",
    },
    Mirror {
        key: "pku",
        label: "北京大学",
        base: "https://mirrors.pku.edu.cn/immortalwrt",
    },
    Mirror {
        key: "sjtu",
        label: "上海交通大学",
        base: "https://mirror.sjtu.edu.cn/immortalwrt",
    },
    Mirror {
        key: "cernet",
        label: "教育网联合镜像",
        base: "https://mirrors.cernet.edu.cn/immortalwrt",
    },
];

fn active_feeds(content: &str) -> impl Iterator<Item = &str> {
    content.lines().filter_map(|line| {
        let line = line.trim();
        if line.starts_with('#') {
            return None;
        }
        line.split_whitespace()
            .next()
            .filter(|url| url.ends_with("/packages.adb"))
    })
}

fn has_base(url: &str, base: &str) -> bool {
    url.strip_prefix(base)
        .is_some_and(|suffix| suffix.is_empty() || suffix.starts_with('/'))
}

pub fn detect_base(content: &str) -> Option<&'static Mirror> {
    let mut feeds = active_feeds(content);
    let first = feeds.next()?;
    let mirror = MIRRORS.iter().find(|mirror| has_base(first, mirror.base))?;
    feeds
        .all(|url| has_base(url, mirror.base))
        .then_some(mirror)
}

// A previously selected custom mirror must also be switchable back to a built-in one.
pub fn current_base(content: &str) -> Result<&str> {
    let mut feeds = active_feeds(content);
    let base = feeds
        .next()
        .and_then(|url| url.rsplit_once("/releases/").map(|(base, _)| base))
        .ok_or_else(|| CatoolsError::ConfigError("未找到可识别的发行版软件源地址".into()))?;
    if !feeds.all(|url| {
        url.rsplit_once("/releases/")
            .is_some_and(|(other, _)| other == base)
    }) {
        return Err(CatoolsError::ConfigError(
            "当前软件源混用了不同地址，请先统一 distfeeds.list 中的软件源地址".into(),
        ));
    }
    Ok(base)
}

pub fn rewrite_feeds(content: &str, from: &str, to: &str) -> Result<String> {
    let mut rewritten = String::with_capacity(content.len());
    let mut matched = false;
    for line in content.split_inclusive('\n') {
        let (comment, url) = line
            .strip_prefix("# ")
            .map_or(("", line), |url| ("# ", url));
        if !from.is_empty() && has_base(url.trim_end_matches(['\r', '\n']), from) {
            rewritten.push_str(comment);
            rewritten.push_str(to);
            rewritten.push_str(&url[from.len()..]);
            matched = true;
        } else {
            rewritten.push_str(line);
        }
    }
    if !matched {
        return Err(CatoolsError::ConfigError(
            "没有匹配的软件源地址，未修改配置".into(),
        ));
    }
    Ok(rewritten)
}

pub fn enable_own_repo(content: &str) -> Result<String> {
    let mut rewritten = String::with_capacity(content.len());
    let mut matched = false;
    for line in content.split_inclusive('\n') {
        let candidate = line.strip_prefix("# ").unwrap_or(line);
        let url = candidate.split_whitespace().next().unwrap_or("");
        let repository = url.starts_with("https://") || url.starts_with("http://");
        if repository && url.ends_with("/packages.adb") {
            rewritten.push_str(candidate);
            matched = true;
        } else {
            rewritten.push_str(line);
        }
    }
    if !matched {
        return Err(CatoolsError::ConfigError(
            "catwrt.list 中没有软件源仓库行".into(),
        ));
    }
    Ok(rewritten)
}

pub fn validate_custom_url(input: &str) -> Result<String> {
    let base = input.strip_suffix('/').unwrap_or(input);
    let valid = base.strip_prefix("https://").is_some_and(|rest| {
        let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
        !host.is_empty()
            && host
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-".contains(&c))
            && path
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._~/-".contains(&c))
    });
    if !valid || base.ends_with('/') {
        return Err(CatoolsError::ValidationError(
            "请输入 HTTPS 软件源基础地址；域名和路径仅允许英文字母、数字及 . _ ~ / -，不能包含空格、端口或查询参数".into(),
        ));
    }
    Ok(base.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TARGET: &str = concat!("/releases/25.12.2/targets/", "x86/64/packages/packages.adb");
    const BASE: &str = "/releases/25.12.2/packages/x86_64/base/packages.adb";
    const KMODS: &str = "/releases/25.12.2/targets/x86/64/kmods/kernel-test/packages.adb";

    #[test]
    fn detect_each_mirror_and_ignore_comments() {
        for mirror in &MIRRORS {
            let content = format!(
                "# Feeds\n{}{TARGET}\n{}{BASE}\n{}{KMODS}\n# https://example.org{BASE}\n",
                mirror.base, mirror.base, mirror.base
            );
            assert_eq!(detect_base(&content), Some(mirror));
        }
    }

    #[test]
    fn detect_rejects_mixed_unknown_and_empty() {
        let mixed = format!("{}{BASE}\n{}{BASE}", MIRRORS[0].base, MIRRORS[1].base);
        let unknown = format!("{}{BASE}\nhttps://example.org{BASE}", MIRRORS[0].base);
        let lookalike = format!("https://downloads.immortalwrt.org.example.org{BASE}");
        assert!(detect_base(&mixed).is_none());
        assert!(detect_base(&format!("https://example.org{BASE}\n")).is_none());
        assert!(detect_base(&unknown).is_none());
        assert!(detect_base(&lookalike).is_none());
        assert!(detect_base("# No active feeds\n").is_none());
    }

    #[test]
    fn rewrite_official_vsean_and_back_preserves_disabled_feeds_and_kmods() {
        let official = MIRRORS[0].base;
        let vsean = MIRRORS[1].base;
        let original = format!(
            "# Feeds\n{official}{TARGET}\n# {official}{BASE}\n{official}{KMODS}\n# Keep this comment\n"
        );
        let expected = format!(
            "# Feeds\n{vsean}{TARGET}\n# {vsean}{BASE}\n{vsean}{KMODS}\n# Keep this comment\n"
        );
        let rewritten = rewrite_feeds(&original, official, vsean).unwrap();
        assert_eq!(rewritten, expected);
        assert_eq!(
            rewrite_feeds(&rewritten, vsean, official).unwrap(),
            original
        );
    }

    #[test]
    fn rewrite_preserves_missing_final_newline_and_unrelated_lines() {
        let original = format!("https://example.org{BASE}\n{}{BASE}", MIRRORS[0].base);
        let expected = format!("https://example.org{BASE}\n{}{BASE}", MIRRORS[1].base);
        assert_eq!(
            rewrite_feeds(&original, MIRRORS[0].base, MIRRORS[1].base).unwrap(),
            expected
        );
        assert!(rewrite_feeds("# No feeds\n", MIRRORS[0].base, MIRRORS[1].base).is_err());
        assert!(
            rewrite_feeds(
                &format!("https://example.org.evil{BASE}"),
                "https://example.org",
                MIRRORS[0].base
            )
            .is_err()
        );
    }

    #[test]
    fn custom_base_can_be_switched_back_and_mixed_feeds_are_rejected() {
        assert_eq!(
            current_base(&format!("https://example.org/mirror{BASE}\n")).unwrap(),
            "https://example.org/mirror"
        );
        let mixed = format!("{}{BASE}\n{}{BASE}", MIRRORS[0].base, MIRRORS[1].base);
        assert!(current_base(&mixed).is_err());
        assert!(current_base("# Empty\n").is_err());
    }

    #[test]
    fn own_repo_enable_is_idempotent_and_preserves_other_comments() {
        let original = concat!(
            "# Repository\n# https://example.org/v26.11/x86_64/packages.adb\n",
            "# Keep\n# https://example.org/v26.12/x86_64/packages.adb"
        );
        let expected = concat!(
            "# Repository\nhttps://example.org/v26.11/x86_64/packages.adb\n",
            "# Keep\nhttps://example.org/v26.12/x86_64/packages.adb"
        );
        assert_eq!(enable_own_repo(original).unwrap(), expected);
        assert_eq!(enable_own_repo(expected).unwrap(), expected);
        assert!(enable_own_repo("").is_err());
        assert!(enable_own_repo("# No repository configured\n").is_err());
    }

    #[test]
    fn custom_url_validation() {
        assert_eq!(
            validate_custom_url("https://example.org/mirror/").unwrap(),
            "https://example.org/mirror"
        );
        assert_eq!(
            validate_custom_url("https://example.org/").unwrap(),
            "https://example.org"
        );
        assert_eq!(
            validate_custom_url("https://example.org/a_b/~mirror-1.0").unwrap(),
            "https://example.org/a_b/~mirror-1.0"
        );
        for invalid in [
            "http://example.org",
            "https://example.org/mir ror",
            " https://example.org",
            "https://example.org\n",
            "https://",
            "https://example.org//",
            "https://example.org:443",
            "https://example.org?q=1",
            concat!("https://user", "@", "example.org"),
        ] {
            assert!(validate_custom_url(invalid).is_err(), "{invalid}");
        }
    }
}
