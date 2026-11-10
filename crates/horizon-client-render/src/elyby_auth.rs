//! Ely.by Authlib-compatible session service for Horizon.
//!
//! This module deliberately does not call Minecraft Services. Microsoft
//! authentication remains in auth.rs; route Ely.by sessions to this module.
//!
//! Endpoints documented by Ely.by:
//!   POST https://authserver.ely.by/session/join
//!   GET  https://authserver.ely.by/session/hasJoined

use std::time::Duration;

const BASE: &str = "https://authserver.ely.by";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ElyByJoinError {
    Unavailable,
    InvalidSession,
    Other(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ElyByJoinedProfile {
    pub uuid: u128,
    pub properties: Vec<ElyByProperty>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ElyByProperty {
    pub name: String,
    pub value: String,
    pub signature: Option<String>,
}

/// The minimum account data required by Ely.by's session protocol.
/// Keep the token private and never include it in Debug output or logs.
pub struct ElyBySession {
    pub name: String,
    pub uuid: u128,
    access_token: String,
}

impl std::fmt::Debug for ElyBySession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ElyBySession")
            .field("name", &self.name)
            .field("uuid", &format!("{:032x}", self.uuid))
            .field("access_token", &"<hidden>")
            .finish()
    }
}

impl ElyBySession {
    pub fn new(name: impl Into<String>, uuid: u128, access_token: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            uuid,
            access_token: access_token.into(),
        }
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent("Horizon Ely.by session client")
        .build()
}

fn uuid_string(uuid: u128) -> String {
    format!("{uuid:032x}")
}

fn encode_query(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(char::from(byte));
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn map_error(status: u16, body: &str) -> ElyByJoinError {
    let value: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let error = value.get("error").and_then(|v| v.as_str()).unwrap_or("");
    let message = value
        .get("errorMessage")
        .and_then(|v| v.as_str())
        .unwrap_or("Ely.by rejected the session request");
    match (status, error) {
        (401, _) | (403, "ForbiddenOperationException") => ElyByJoinError::InvalidSession,
        (500..=599, _) => ElyByJoinError::Unavailable,
        _ => ElyByJoinError::Other(message.to_owned()),
    }
}

/// Tell Ely.by that this authenticated player is joining `server_hash`.
/// A successful HTTP 200/204 response is accepted.
pub fn join_server(session: &ElyBySession, server_hash: &str) -> Result<(), ElyByJoinError> {
    let payload = serde_json::json!({
        "accessToken": session.access_token,
        "selectedProfile": uuid_string(session.uuid),
        "serverId": server_hash,
    })
    .to_string();

    match agent()
        .post(&format!("{BASE}/session/join"))
        .set("Content-Type", "application/json; charset=utf-8")
        .send_string(&payload)
    {
        Ok(_) => Ok(()),
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            Err(map_error(status, &body))
        }
        Err(ureq::Error::Transport(_)) => Err(ElyByJoinError::Unavailable),
    }
}

/// Ask Ely.by whether `name` joined with `server_hash`.
/// `Ok(None)` means Ely.by did not find a matching authenticated join.
pub fn has_joined(
    name: &str,
    server_hash: &str,
    ip: Option<std::net::IpAddr>,
) -> Result<Option<ElyByJoinedProfile>, ElyByJoinError> {
    let mut url = format!(
        "{BASE}/session/hasJoined?username={}&serverId={}",
        encode_query(name),
        encode_query(server_hash),
    );
    if let Some(ip) = ip {
        url.push_str("&ip=");
        url.push_str(&encode_query(&ip.to_string()));
    }

    let body = match agent().get(&url).call() {
        Ok(response) => response.into_string().unwrap_or_default(),
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            return match map_error(status, &body) {
                ElyByJoinError::Unavailable => Err(ElyByJoinError::Unavailable),
                _ => Ok(None),
            };
        }
        Err(ureq::Error::Transport(_)) => return Err(ElyByJoinError::Unavailable),
    };

    Ok(parse_has_joined(&body))
}

pub fn parse_has_joined(body: &str) -> Option<ElyByJoinedProfile> {
    let value: serde_json::Value = serde_json::from_str(body).ok()?;
    let uuid_text = value.get("id")?.as_str()?;
    let compact: String = uuid_text.chars().filter(|c| *c != '-').collect();
    if compact.len() != 32 {
        return None;
    }
    let uuid = u128::from_str_radix(&compact, 16).ok()?;

    let properties = value
        .get("properties")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|p| {
            Some(ElyByProperty {
                name: p.get("name")?.as_str()?.to_owned(),
                value: p.get("value")?.as_str()?.to_owned(),
                signature: p
                    .get("signature")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned),
            })
        })
        .collect();

    Some(ElyByJoinedProfile { uuid, properties })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_elyby_has_joined_response() {
        let json = r#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"e30=","signature":"c2ln"}]}"#;
        let profile = parse_has_joined(json).unwrap();
        assert_eq!(profile.uuid, 0x069a79f444e94726a5befca90e38aaf5);
        assert_eq!(profile.properties.len(), 1);
        assert_eq!(profile.properties[0].signature.as_deref(), Some("c2ln"));
    }

    #[test]
    fn rejects_missing_or_invalid_profile() {
        assert!(parse_has_joined("").is_none());
        assert!(parse_has_joined(r#"{"name":"Notch"}"#).is_none());
        assert!(parse_has_joined(r#"{"id":"not-a-uuid"}"#).is_none());
    }

    #[test]
    fn hides_access_token_in_debug() {
        let session = ElyBySession::new("Player", 1, "secret-token");
        assert!(!format!("{session:?}").contains("secret-token"));
    }
}
