/*
 * Phone Farm addition to gnirehtet (Apache License 2.0).
 *
 * Sends every TCP connection of the phone through one HTTP proxy with CONNECT, so the
 * phone reaches the internet only through the proxy saved for it. The relay is started
 * with GNIREHTET_PROXY=host:port and, for a proxy with a login, GNIREHTET_PROXY_AUTH set
 * to base64("user:pass").
 */

use log::*;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, SocketAddrV4, ToSocketAddrs};
use std::sync::OnceLock;

const TAG: &str = "UpstreamProxy";
const MAX_RESPONSE_HEADER: usize = 16 * 1024;

pub struct ProxyConfig {
    pub address: SocketAddr,
    authorization: Option<String>,
}

static CONFIG: OnceLock<Option<ProxyConfig>> = OnceLock::new();

/// The proxy every TCP connection goes through, or None to connect directly.
pub fn get() -> Option<&'static ProxyConfig> {
    CONFIG.get_or_init(load).as_ref()
}

fn load() -> Option<ProxyConfig> {
    let value = std::env::var("GNIREHTET_PROXY").ok()?;
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let address = match value.to_socket_addrs().ok().and_then(|mut list| list.find(SocketAddr::is_ipv4)) {
        Some(address) => address,
        None => {
            // Never fall back to a direct connection when a proxy was requested.
            error!(target: TAG, "Cannot resolve proxy {}", value);
            std::process::exit(3);
        }
    };
    let authorization = std::env::var("GNIREHTET_PROXY_AUTH")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    info!(target: TAG, "TCP goes through proxy {}", address);
    Some(ProxyConfig { address, authorization })
}

/// UDP is allowed only for DNS and NTP while a proxy is set: an HTTP proxy cannot carry
/// UDP, and anything else (QUIC) would leave from the Mac's own address. Apps fall back to TCP.
pub fn allows_udp(port: u16) -> bool {
    get().is_none() || port == 53 || port == 123
}

/// HTTP CONNECT handshake run on a fresh connection to the proxy before the relay answers
/// the phone's SYN.
pub struct Handshake {
    request: Vec<u8>,
    written: usize,
    response: Vec<u8>,
}

impl Handshake {
    pub fn new(config: &ProxyConfig, destination: SocketAddrV4) -> Self {
        let mut request = format!(
            "CONNECT {0} HTTP/1.1\r\nHost: {0}\r\nProxy-Connection: Keep-Alive\r\n",
            destination
        );
        if let Some(authorization) = &config.authorization {
            request.push_str("Proxy-Authorization: Basic ");
            request.push_str(authorization);
            request.push_str("\r\n");
        }
        request.push_str("\r\n");
        Self {
            request: request.into_bytes(),
            written: 0,
            response: Vec::new(),
        }
    }

    pub fn wants_write(&self) -> bool {
        self.written < self.request.len()
    }

    /// Ok(true) once the proxy accepted the tunnel; Err(WouldBlock) while waiting for it.
    pub fn advance<S: Read + Write>(&mut self, stream: &mut S, writable: bool) -> io::Result<bool> {
        if self.wants_write() {
            if !writable {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            while self.wants_write() {
                match stream.write(&self.request[self.written..])? {
                    0 => return Err(io::ErrorKind::WriteZero.into()),
                    count => self.written += count,
                }
            }
        }
        // Read one byte at a time so no data after the response header is consumed.
        let mut byte = [0u8; 1];
        loop {
            if stream.read(&mut byte)? == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "proxy closed the connection"));
            }
            self.response.push(byte[0]);
            if self.response.ends_with(b"\r\n\r\n") {
                return self.accepted();
            }
            if self.response.len() > MAX_RESPONSE_HEADER {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "proxy response too long"));
            }
        }
    }

    fn accepted(&self) -> io::Result<bool> {
        let text = String::from_utf8_lossy(&self.response);
        let status_line = text.lines().next().unwrap_or("");
        let status = status_line.split_whitespace().nth(1).unwrap_or("");
        if status_line.starts_with("HTTP/") && status.starts_with('2') {
            Ok(true)
        } else {
            Err(io::Error::new(io::ErrorKind::ConnectionRefused, format!("proxy answered {}", status_line)))
        }
    }
}
