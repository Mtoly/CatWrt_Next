/* src/api/update.rs */

use crate::error::{CatoolsError, Result};
use crate::utils::system::run_command;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::process::Command;

const DEFAULT_META_URLS: [&str; 2] = [
    "https://mtoly.github.io/CatWrt_Next/meta.json",
    "https://cdn.jsdelivr.net/gh/Mtoly/CatWrt_Next@gh-pages/meta.json",
];

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateMeta {
    pub schema: u32,
    pub latest: String,
    pub base: String,
    pub released: String,
    pub notes_url: String,
    pub images: BTreeMap<String, BTreeMap<String, Image>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Image {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

impl UpdateMeta {
    pub fn image(&self, arch: &str, variant: &str) -> Result<&Image> {
        self.images
            .get(arch)
            .and_then(|images| images.get(variant))
            .ok_or_else(|| {
                CatoolsError::ValidationError(format!(
                    "更新信息没有所需镜像：架构 {}，变体 {}",
                    arch, variant
                ))
            })
    }
}

fn parse_meta(body: &str) -> Result<UpdateMeta> {
    let value: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| CatoolsError::ApiError(format!("解析 meta.json 失败：{}", e)))?;
    if value.get("schema").and_then(|schema| schema.as_u64()) != Some(1) {
        return Err(CatoolsError::ApiError(format!(
            "不支持的 meta.json schema：{}，仅支持 1",
            value.get("schema").unwrap_or(&serde_json::Value::Null)
        )));
    }
    serde_json::from_value(value)
        .map_err(|e| CatoolsError::ApiError(format!("meta.json 字段无效：{}", e)))
}

fn urls_from_uci(value: &str) -> Vec<String> {
    let urls: Vec<String> = value.split_whitespace().map(str::to_string).collect();
    if urls.is_empty() {
        DEFAULT_META_URLS
            .iter()
            .map(|url| url.to_string())
            .collect()
    } else {
        urls
    }
}

pub fn update_urls() -> Result<Vec<String>> {
    let command = "uci -q get catwrt.update.url";
    let output = Command::new("uci")
        .args(["-q", "get", "catwrt.update.url"])
        .output()
        .map_err(|error| {
            CatoolsError::CommandError(format!(
                "无法执行命令 {}：{}；stderr：无（未启动）",
                command, error
            ))
        })?;
    if !output.status.success() {
        let error = format!(
            "命令 {} 退出状态 {}；stderr：{}",
            command,
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        // A quiet UCI lookup returns 1 and no output when the option is absent.
        if output.status.code() == Some(1) && output.stdout.is_empty() && output.stderr.is_empty() {
            eprintln!("{}；未配置更新地址，使用默认地址", error);
            return Ok(urls_from_uci(""));
        }
        return Err(CatoolsError::CommandError(error));
    }
    Ok(urls_from_uci(&String::from_utf8_lossy(&output.stdout)))
}

pub fn fetch_meta(urls: &[String]) -> Result<UpdateMeta> {
    fetch_meta_with(urls, |url| {
        let mut failures = Vec::new();
        for (tool, args) in [
            ("uclient-fetch", vec!["-O", "-", url]),
            ("wget", vec!["-O", "-", url]),
            ("curl", vec!["-fL", url]),
        ] {
            match run_command(tool, &args) {
                Ok(body) => return Ok(body),
                Err(error) => {
                    eprintln!("下载更新信息失败：{}", error);
                    failures.push(error.to_string());
                }
            }
        }
        Err(CatoolsError::ApiError(failures.join("；")))
    })
}

fn fetch_meta_with<F>(urls: &[String], mut fetch: F) -> Result<UpdateMeta>
where
    F: FnMut(&str) -> Result<String>,
{
    let mut failures = Vec::new();
    for url in urls {
        match fetch(url).and_then(|body| parse_meta(&body)) {
            Ok(meta) => return Ok(meta),
            Err(error) => failures.push(format!("{}: {}", url, error)),
        }
    }
    Err(CatoolsError::ApiError(format!(
        "所有更新地址均失败：\n{}",
        failures.join("\n")
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_meta() -> String {
        serde_json::json!({
            "schema": 1,
            "latest": "v26.12",
            "base": "test-25.12.2",
            "released": "2026-12-01",
            "notes_url": "https://example.org/releases/v26.12",
            "images": {"x86_64": {"squashfs-efi": {
                "url": "https://example.org/firmware.img.gz",
                "sha256": "a".repeat(64),
                "size": 1024
            }}}
        })
        .to_string()
    }

    #[test]
    fn parse_schema_and_select_image() {
        let meta = parse_meta(&valid_meta()).unwrap();
        assert_eq!(meta.schema, 1);
        assert_eq!(meta.latest, "v26.12");
        assert_eq!(meta.image("x86_64", "squashfs-efi").unwrap().size, 1024);
        for (arch, variant) in [("missing", "squashfs-efi"), ("x86_64", "ext4-bios")] {
            let error = meta.image(arch, variant).unwrap_err().to_string();
            assert!(error.contains(arch));
            assert!(error.contains(variant));
        }
        let error = parse_meta(r#"{"schema":2}"#).unwrap_err().to_string();
        assert!(error.contains("schema：2"));
        assert!(parse_meta("{}").is_err());
        assert!(parse_meta(r#"{"schema":1}"#).is_err());
        assert!(parse_meta("<html>unavailable</html>").is_err());
    }

    #[test]
    fn urls_use_defaults_only_when_unconfigured() {
        assert_eq!(urls_from_uci(" \n"), DEFAULT_META_URLS);
        assert_eq!(
            urls_from_uci("https://example.org/meta.json"),
            ["https://example.org/meta.json"]
        );
        assert_eq!(
            urls_from_uci("first second\nthird"),
            ["first", "second", "third"]
        );
    }

    #[test]
    fn fallback_preserves_order_and_stops_at_success() {
        let urls = urls_from_uci("first second third fourth");
        let mut visited = Vec::new();
        let meta = fetch_meta_with(&urls, |url| {
            visited.push(url.to_string());
            match url {
                "first" => Err(CatoolsError::ApiError("HTTP 503".to_string())),
                "second" => Ok(r#"{"schema":7}"#.to_string()),
                _ => Ok(valid_meta()),
            }
        })
        .unwrap();
        assert_eq!(meta.latest, "v26.12");
        assert_eq!(visited, ["first", "second", "third"]);
    }

    #[test]
    fn all_failures_include_each_url_and_reason() {
        let urls = urls_from_uci("first second");
        let error = fetch_meta_with(&urls, |url| {
            Err(CatoolsError::ApiError(format!("{} HTTP 404", url)))
        })
        .unwrap_err()
        .to_string();
        for url in urls {
            assert!(error.contains(&format!("{}:", url)));
        }
        assert_eq!(error.matches("HTTP 404").count(), 2);
    }
}
