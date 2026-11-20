/* src/utils/validation.rs */

use crate::error::{CatoolsError, Result};

pub fn validate_ip(ip: &str) -> Result<()> {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 {
        return Err(CatoolsError::ValidationError(format!(
            "Invalid IP format: {}",
            ip
        )));
    }

    for octet in &parts {
        if octet.is_empty() || octet.len() > 3 {
            return Err(CatoolsError::ValidationError(
                "Invalid IP octet".to_string(),
            ));
        }
    }

    for octet in parts.iter().take(3) {
        octet
            .parse::<u8>()
            .map_err(|_| CatoolsError::ValidationError("Invalid IP octet".to_string()))?;
    }

    let pd = parts[3]
        .parse::<u8>()
        .map_err(|_| CatoolsError::ValidationError("Invalid IP octet".to_string()))?;

    if !(1..=254).contains(&pd) {
        return Err(CatoolsError::ValidationError(
            "Last octet must be 1-254".to_string(),
        ));
    }

    Ok(())
}

#[derive(Eq, Ord, PartialEq, PartialOrd)]
enum VersionStage {
    Dev,
    Rc(u32),
    Release,
}

fn parse_update_version(ver: &str) -> Result<(u32, u32, u32, VersionStage)> {
    let invalid = || CatoolsError::ValidationError(format!("无效的版本号：{}", ver));
    let rest = ver.strip_prefix('v').ok_or_else(invalid)?;
    let (numbers, stage) = match rest.split_once('-') {
        None => (rest, VersionStage::Release),
        Some((numbers, "dev")) => (numbers, VersionStage::Dev),
        Some((numbers, suffix)) => {
            let rc = suffix.strip_prefix("rc").ok_or_else(invalid)?;
            if rc.is_empty() || !rc.bytes().all(|c| c.is_ascii_digit()) {
                return Err(invalid());
            }
            let rc = rc.parse().map_err(|_| invalid())?;
            (numbers, VersionStage::Rc(rc))
        }
    };
    let parts: Vec<&str> = numbers.split('.').collect();
    if !(2..=3).contains(&parts.len())
        || parts[0].len() != 2
        || parts[1].len() > 2
        || parts
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|c| c.is_ascii_digit()))
    {
        return Err(invalid());
    }
    let year = parts[0].parse().map_err(|_| invalid())?;
    let month = parts[1].parse().map_err(|_| invalid())?;
    if !(1..=12).contains(&month) {
        return Err(invalid());
    }
    let patch = parts
        .get(2)
        .unwrap_or(&"0")
        .parse()
        .map_err(|_| invalid())?;
    Ok((year, month, patch, stage))
}

pub fn compare_versions(v1: &str, v2: &str) -> Result<std::cmp::Ordering> {
    Ok(parse_update_version(v1)?.cmp(&parse_update_version(v2)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_ip() {
        assert!(validate_ip("192.168.1.1").is_ok());
        assert!(validate_ip("192.0.2.254").is_ok());
        assert!(validate_ip("256.1.1.1").is_err());
        assert!(validate_ip("192.168.1").is_err());
    }

    #[test]
    fn version_ordering() {
        use std::cmp::Ordering::{Equal, Less};

        for (left, right, expected) in [
            ("v26.12", "v26.12.0", Equal),
            ("v26.01", "v26.1", Equal),
            ("v26.12-dev", "v26.12-rc1", Less),
            ("v26.12-rc2", "v26.12-rc10", Less),
            ("v26.12-rc10", "v26.12", Less),
            ("v26.12", "v26.12.1-dev", Less),
            ("v26.12.1-dev", "v26.12.1-rc1", Less),
            ("v26.12.1-rc1", "v26.12.1", Less),
            ("v26.12.1", "v26.12.2-dev", Less),
            ("v26.12.9", "v26.12.10", Less),
            ("v26.11.99", "v26.12-dev", Less),
            ("v26.12", "v27.1-dev", Less),
            ("v26.12.0-rc1", "v26.12-rc1", Equal),
            ("v26.12-dev", "v26.12.0-dev", Equal),
        ] {
            assert_eq!(
                compare_versions(left, right).unwrap(),
                expected,
                "{left} / {right}"
            );
            assert_eq!(compare_versions(right, left).unwrap(), expected.reverse());
        }
    }

    #[test]
    fn invalid_versions_are_rejected() {
        for version in [
            "",
            "26.12",
            "v2026.12",
            "v26",
            "v26.0",
            "v26.13",
            "v26.001",
            "v26.12.",
            "v26.12.1.2",
            "v26.12-rc",
            "v26.12-rcx",
            "v26.12-beta1",
            "v26.12-dev1",
            "v26.12-rc1-dev",
            "v26.12.+1",
            "v26.12-rc+1",
            "v26.12.999999999999999999999",
            " v26.12",
            "v26.12\n",
        ] {
            assert!(compare_versions(version, "v26.12").is_err(), "{version}");
            assert!(compare_versions("v26.12", version).is_err(), "{version}");
        }
    }
}
