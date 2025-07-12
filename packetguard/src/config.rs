use serde::Deserialize;
use std::{fs, path::Path};

#[derive(Debug, Deserialize)]
pub struct FilterConfig {
    pub drop_if_ip_matches: Vec<String>,
    pub drop_if_hostname_matches: Vec<String>,
    pub log_dangerous_http: bool,
    pub log_dns_queries: bool,
}

#[derive(Debug, Deserialize)]
pub struct NFQueueConfig {
    pub enabled: bool,
    pub queue_num: u16,
    pub fail_open: bool,
}

#[derive(Debug, Deserialize)]
pub struct PacketGuardConfig {
    pub mode: String,
    pub interfaces: Option<Vec<String>>,
    pub filter: FilterConfig,
    pub nfqueue: Option<NFQueueConfig>,
}

impl PacketGuardConfig {
    pub fn load<P: AsRef<Path>>(path: P) -> Result<Self, String> {
        let content = fs::read_to_string(path.as_ref())
            .map_err(|e| format!("Failed to read {}: {}", path.as_ref().display(), e))?;
        toml::from_str(&content).map_err(|e| format!("TOML parse error: {}", e))
    }

    pub fn is_sniff_mode(&self) -> bool {
        self.mode.eq_ignore_ascii_case("sniff")
    }

    pub fn is_guard_mode(&self) -> bool {
        self.mode.eq_ignore_ascii_case("guard")
    }

    pub fn nfqueue_enabled(&self) -> bool {
        self.nfqueue.as_ref().map(|q| q.enabled).unwrap_or(false)
    }
}