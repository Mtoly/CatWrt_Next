/* src/constants.rs */

// API URLs
#[allow(dead_code)]
pub const API_REPO_CONFIG_URL: &str = "https://api.miaoer.net/api/v2/snippets/catwrt/repo-config";
#[allow(dead_code)]
pub const BASE_REPO_URL: &str = "https://raw.miaoer.net/cattools/repo";

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
