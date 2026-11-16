/* src/uci/network.rs */

#![allow(dead_code)]

use crate::error::Result;
use crate::uci::Uci;
use crate::utils::system::run_command;

pub fn set_ip_address(uci: &Uci, ip: &str) -> Result<()> {
    uci.set("network.lan.ipaddr", ip)?;
    uci.commit("network")?;
    Ok(())
}

pub fn set_gateway(uci: &Uci, gateway: &str) -> Result<()> {
    uci.set("network.lan.gateway", gateway)?;
    Ok(())
}

pub fn set_netmask(uci: &Uci, mask: &str) -> Result<()> {
    uci.set("network.lan.netmask", mask)?;
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
    use super::bridge_section;

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
