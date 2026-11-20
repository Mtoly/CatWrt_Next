/* src/uci/network.rs */

#![allow(dead_code)]

use crate::error::{CatoolsError, Result};
use crate::uci::Uci;
use crate::utils::system::run_command;
use std::net::Ipv4Addr;

pub fn first_lan_address(ipaddr: &str) -> &str {
    ipaddr
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .split('/')
        .next()
        .unwrap_or_default()
}

pub fn select_lan_prefix(ipaddr: &str, netmask: Option<&str>) -> Result<u8> {
    let first = ipaddr.split_whitespace().next().unwrap_or_default();
    if let Some((_, prefix)) = first.split_once('/') {
        return prefix
            .parse::<u8>()
            .ok()
            .filter(|prefix| (1..=32).contains(prefix))
            .ok_or_else(|| CatoolsError::ValidationError("LAN 地址前缀必须为 1–32".to_string()));
    }

    let Some(netmask) = netmask else {
        return Ok(24);
    };
    let invalid = || {
        CatoolsError::ValidationError("LAN 子网掩码必须是连续的 IPv4 掩码（1–32 位）".to_string())
    };
    let mask = u32::from(netmask.parse::<Ipv4Addr>().map_err(|_| invalid())?);
    let prefix = mask.leading_ones();
    if prefix == 0 || prefix + mask.trailing_zeros() != 32 {
        return Err(invalid());
    }
    Ok(prefix as u8)
}

pub fn lan_prefix(uci: &Uci) -> Result<u8> {
    let ipaddr = uci.get_optional("network.lan.ipaddr")?.unwrap_or_default();
    if ipaddr
        .split_whitespace()
        .next()
        .is_some_and(|ip| ip.contains('/'))
    {
        return select_lan_prefix(&ipaddr, None);
    }
    let netmask = uci.get_optional("network.lan.netmask")?;
    select_lan_prefix(&ipaddr, netmask.as_deref())
}

fn format_lan_address(ip: &str, prefix: u8) -> String {
    format!("{}/{}", ip, prefix)
}

pub fn set_lan_address(uci: &Uci, ip: &str, prefix: u8) -> Result<()> {
    let has_ipaddr = uci.get_optional("network.lan.ipaddr")?.is_some();
    let has_netmask = uci.get_optional("network.lan.netmask")?.is_some();
    if has_ipaddr {
        uci.delete("network.lan.ipaddr")?;
    }
    uci.add_list("network.lan.ipaddr", &format_lan_address(ip, prefix))?;
    if has_netmask {
        uci.delete("network.lan.netmask")?;
    }
    Ok(())
}

pub fn set_ip_address(uci: &Uci, ip: &str) -> Result<()> {
    set_lan_address(uci, ip, lan_prefix(uci)?)?;
    uci.commit("network")?;
    Ok(())
}

pub fn set_gateway(uci: &Uci, gateway: &str) -> Result<()> {
    uci.set("network.lan.gateway", gateway)?;
    Ok(())
}

pub fn enable_ipv6(_uci: &Uci, _enable: bool) -> Result<()> {
    // TODO: implement IPv6 configuration
    Ok(())
}

pub fn configure_pppoe(uci: &Uci, username: &str, password: &str) -> Result<()> {
    uci.set("network.wan.proto", "pppoe")?;
    uci.set("network.wan.username", username)?;
    uci.set("network.wan.password", password)?;
    Ok(())
}

pub fn set_wan_interface(uci: &Uci, iface: &str) -> Result<()> {
    for section in ["wan", "wan6"] {
        uci.set(&format!("network.{}.device", section), iface)?;
        for option in ["ifname", "_orig_ifname", "_orig_bridge"] {
            let _ = uci.delete(&format!("network.{}.{}", section, option));
        }
    }
    Ok(())
}

fn bridge_section(config: &str) -> Option<&str> {
    config.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        let section = key.strip_suffix(".name")?;
        if value.trim_matches('\'') != "br-lan" {
            return None;
        }
        let is_device = config.lines().any(|entry| {
            entry
                .split_once('=')
                .is_some_and(|(key, value)| key == section && value.trim_matches('\'') == "device")
        });
        is_device.then_some(section)
    })
}

pub fn bridge_interfaces(uci: &Uci, interfaces: &[&str]) -> Result<()> {
    let config = run_command("uci", &["show", "network"])?;
    let section = match bridge_section(&config) {
        Some(section) => section.to_string(),
        None => {
            let section = run_command("uci", &["add", "network", "device"])?;
            format!("network.{}", section.trim())
        }
    };
    uci.set(&format!("{}.name", section), "br-lan")?;
    uci.set(&format!("{}.type", section), "bridge")?;
    let ports = format!("{}.ports", section);
    let _ = uci.delete(&ports);
    for iface in interfaces {
        uci.add_list(&ports, iface)?;
    }
    uci.set("network.lan.device", "br-lan")?;
    for option in ["type", "ifname", "_orig_ifname", "_orig_bridge"] {
        let _ = uci.delete(&format!("network.lan.{}", option));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{bridge_section, first_lan_address, format_lan_address, select_lan_prefix};

    #[test]
    fn preserve_first_cidr_prefix() {
        assert_eq!(
            select_lan_prefix(" 192.0.2.4/25 198.51.100.4/24\n", Some("invalid")).unwrap(),
            25
        );
        for prefix in [1, 32] {
            assert_eq!(
                select_lan_prefix(&format!("192.0.2.4/{prefix}"), None).unwrap(),
                prefix
            );
        }
        for value in ["192.0.2.4/0", "192.0.2.4/33", "192.0.2.4/", "192.0.2.4/bad"] {
            assert!(select_lan_prefix(value, Some("255.255.255.0")).is_err());
        }
    }

    #[test]
    fn derive_prefix_from_legacy_netmask() {
        for (netmask, prefix) in [
            ("255.0.0.0", 8),
            ("255.255.255.0", 24),
            ("255.255.255.128", 25),
            ("255.255.255.254", 31),
            ("255.255.255.255", 32),
        ] {
            assert_eq!(
                select_lan_prefix("192.0.2.4", Some(netmask)).unwrap(),
                prefix
            );
        }
        assert_eq!(
            select_lan_prefix("192.0.2.4 198.51.100.4/28", Some("255.255.255.0")).unwrap(),
            24
        );
    }

    #[test]
    fn default_prefix_without_cidr_or_netmask() {
        assert_eq!(select_lan_prefix("192.0.2.4", None).unwrap(), 24);
        assert_eq!(select_lan_prefix("", None).unwrap(), 24);
    }

    #[test]
    fn reject_invalid_netmask() {
        for netmask in ["invalid", "", "255.255.255", "255.0.255.0", "0.0.0.0"] {
            assert!(select_lan_prefix("192.0.2.4", Some(netmask)).is_err());
        }
    }

    #[test]
    fn format_address_with_selected_prefix() {
        for (ipaddr, netmask, expected) in [
            ("192.0.2.4/25 198.51.100.4/24", None, "203.0.113.4/25"),
            ("192.0.2.4", Some("255.255.255.128"), "203.0.113.4/25"),
            ("192.0.2.4", None, "203.0.113.4/24"),
        ] {
            let prefix = select_lan_prefix(ipaddr, netmask).unwrap();
            assert_eq!(format_lan_address("203.0.113.4", prefix), expected);
        }
    }

    #[test]
    fn display_only_first_address_without_prefix() {
        for (ipaddr, expected) in [
            ("192.0.2.4/25", "192.0.2.4"),
            (" 192.0.2.4/25 198.51.100.4/24\n", "192.0.2.4"),
            ("192.0.2.4", "192.0.2.4"),
            (" \n", ""),
        ] {
            assert_eq!(first_lan_address(ipaddr), expected);
        }
    }

    #[test]
    fn find_anonymous_bridge_without_assuming_device_index() {
        let config = "network.@device[0]=device\nnetwork.@device[0].name='eth0'\n\
                      network.@device[1]=device\nnetwork.@device[1].name='br-lan'\n";
        assert_eq!(bridge_section(config), Some("network.@device[1]"));
    }

    #[test]
    fn find_named_bridge_and_ignore_interface_sections() {
        let config = "network.lan=interface\nnetwork.lan.name='br-lan'\n\
                      network.lan_bridge=device\nnetwork.lan_bridge.name='br-lan'\n";
        assert_eq!(bridge_section(config), Some("network.lan_bridge"));
        assert_eq!(bridge_section("network.lan=interface\n"), None);
        assert_eq!(
            bridge_section("network.lan=interface\nnetwork.lan.name='br-lan'"),
            None
        );
    }
}
