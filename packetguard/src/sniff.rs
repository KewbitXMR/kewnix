// Lightweight DPI sniffer for Kewnix Tor Orchestrator
// Rust binary to watch container bridges and extract potential leak attempts

use pnet::datalink::{self, Channel::Ethernet};
use pnet::packet::ethernet::EthernetPacket;
use pnet::packet::ip::IpNextHeaderProtocols;
use pnet::packet::tcp::TcpPacket;
use pnet::packet::udp::UdpPacket;
use pnet::packet::ipv4::Ipv4Packet;
use std::collections::HashMap;
use std::env;
use std::net::Ipv4Addr;
use std::str;

fn list_kewnix_interfaces() -> Vec<String> {
    datalink::interfaces()
        .into_iter()
        .filter(|iface| iface.name.starts_with("kewnet-"))
        .map(|iface| iface.name)
        .collect()
}

fn decode_dns(payload: &[u8]) {
    if payload.len() > 12 {
        let qname = &payload[12..];
        let mut name = String::new();
        let mut i = 0;
        while i < qname.len() {
            let len = qname[i] as usize;
            if len == 0 || i + len >= qname.len() { break; }
            if !name.is_empty() { name.push('.'); }
            name.push_str(&String::from_utf8_lossy(&qname[i+1..i+1+len]));
            i += len + 1;
        }
        if !name.is_empty() {
            println!("[DNS] Query: {}", name);
        }
    }
}

fn decode_http(payload: &[u8]) {
    if let Ok(data) = str::from_utf8(payload) {
        for line in data.lines().take(10) {
            if line.to_lowercase().starts_with("host") || line.to_lowercase().starts_with("user-agent") {
                println!("[HTTP] {}", line);
            }
        }
    }
}

fn sniff_interface(name: &str) {
    let interfaces = datalink::interfaces();
    let iface = interfaces.into_iter().find(|iface| iface.name == name).expect("Interface not found");

    let (_, mut rx) = match datalink::channel(&iface, Default::default()) {
        Ok(Ethernet(tx, rx)) => (tx, rx),
        Ok(_) => panic!("Unhandled channel type"),
        Err(e) => panic!("Error creating channel: {}", e),
    };

    println!("[+] Sniffing on interface: {}", name);

    loop {
        match rx.next() {
            Ok(packet) => {
                if let Some(eth) = EthernetPacket::new(packet) {
                    if let Some(ip) = Ipv4Packet::new(eth.payload()) {
                        match ip.get_next_level_protocol() {
                            IpNextHeaderProtocols::Tcp => {
                                if let Some(tcp) = TcpPacket::new(ip.payload()) {
                                    let sport = tcp.get_source();
                                    let dport = tcp.get_destination();
                                    let data = tcp.payload();
                                    if dport == 80 || sport == 80 {
                                        decode_http(data);
                                    } else if dport == 443 || sport == 443 {
                                        println!("[TLS] TCP:{} -> {} ({} bytes)", sport, dport, data.len());
                                    }
                                }
                            }
                            IpNextHeaderProtocols::Udp => {
                                if let Some(udp) = UdpPacket::new(ip.payload()) {
                                    let dport = udp.get_destination();
                                    if dport == 53 {
                                        decode_dns(udp.payload());
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Err(e) => eprintln!("[-] Error receiving packet: {}", e),
        }
    }
}

fn main() {
    let interfaces = list_kewnix_interfaces();
    if interfaces.is_empty() {
        eprintln!("[-] No kewnet-* Docker bridges found");
        return;
    }

    for iface in interfaces {
        std::thread::spawn(move || {
            sniff_interface(&iface);
        });
    }

    loop { std::thread::sleep(std::time::Duration::from_secs(999)); }
}