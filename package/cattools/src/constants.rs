/* src/constants.rs */

// API URLs
pub const API_UPDATE_URL: &str = "https://api.miaoer.net/api/v2/snippets/catwrt/update";
#[allow(dead_code)]
pub const API_REPO_CONFIG_URL: &str = "https://api.miaoer.net/api/v2/snippets/catwrt/repo-config";
#[allow(dead_code)]
pub const BASE_REPO_URL: &str = "https://raw.miaoer.net/cattools/repo";

// Sysupgrade URLs
pub const SYSUP_AMD64_URL: &str =
    "https://raw.githubusercontent.com/miaoermua/cattools/main/sysupgrade/amd64/sysup_efi";
pub const SYSUP_MT7621_URL: &str =
    "https://raw.githubusercontent.com/miaoermua/cattools/main/sysupgrade/mt7621/sysup";
pub const SYSUP_MT798X_URL: &str =
    "https://raw.githubusercontent.com/miaoermua/cattools/main/sysupgrade/mt798x/sysup";

// Default values
pub const DEFAULT_IP: &str = "192.168.1.4";
#[allow(dead_code)]
pub const RELEASE_FILE: &str = "/etc/catwrt_release";
pub const BACKUP_FILE: &str = "/etc/catwrt_apk_world.bak";

// Mirror options
pub const MIRROR_OPTIONS: &[&str] = &[
    "miaoer.net (主站)",
    "Github-Pages",
    "Cloudflare-Netlify",
    "Netlify (默认)",
    "Cloudflare-Vercel",
    "Vercel",
];

pub const BETA_MIRROR_OPTIONS: &[&str] = &["netlify", "vercel (默认)"];
