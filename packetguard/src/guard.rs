use crate::config::{PacketGuardConfig};
use netfilter_queue::{Queue, Message};
use std::net::Ipv4Addr;
use std::thread;
use std::time::Duration;
use log::{info, warn};

pub fn start_guard(config: PacketGuardConfig) {
    if !config.nfqueue_enabled() {
        warn!("NFQUEUE is disabled in config. Nothing to guard.");
        return;
    }

    let queue_num = config.nfqueue.as_ref().unwrap().queue_num;
    let fail_open = config.nfqueue.as_ref().unwrap().fail_open;

    let filter_cfg = config.filter.clone();
    thread::spawn(move || {
        let mut q = Queue::new().expect("Failed to open NFQUEUE");

        info!("[*] PacketGuard active on NFQUEUE queue {}", queue_num);

        q.bind(queue_num, move |msg: Message| {
            if let Some(ip) = msg.get_payload_ipv4() {
                if let Some(tcp) = ip.get_transport_tcp() {
                    let payload = tcp.payload();
                    let payload_str = String::from_utf8_lossy(payload);

                    // Scan for dangerous headers
                    if filter_cfg.log_dangerous_http && (payload_str.contains("Host:") || payload_str.contains("X-Real-IP")) {
                        warn!("[HTTP] Dangerous header detected: {:?}", payload_str.lines().take(3).collect::<Vec<_>>());
                    }

                    // Drop packet if destination IP matches config
                    if filter_cfg.drop_if_ip_matches.iter().any(|blocked_ip| {
                        ip.get_destination() == parse_ip(blocked_ip)
                    }) {
                        warn!("[DROP] Packet matched blocked IP: {}", ip.get_destination());
                        return msg.drop();
                    }
                }

                if let Some(udp) = ip.get_transport_udp() {
                    // Optional: handle DNS leaks
                    if udp.get_destination() == 53 && filter_cfg.log_dns_queries {
                        warn!("[DNS] UDP port 53 request to: {}", ip.get_destination());
                    }
                }
            }

            // Default accept
            msg.accept()
        }).unwrap();

        q.run().unwrap_or_else(|e| {
            if fail_open {
                warn!("NFQUEUE failed but fail_open=true, packets will pass. Error: {}", e);
            } else {
                panic!("NFQUEUE error: {}", e);
            }
        });
    });

    // Keep main thread alive
    loop { thread::sleep(Duration::from_secs(3600)); }
}

fn parse_ip(s: &str) -> Ipv4Addr {
    s.parse().expect("Invalid IP in config")
}