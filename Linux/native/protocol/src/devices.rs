//! Public device metadata, persisted only by the configuration owner.
//! No password, token, network identity or implicit peer configuration lives here.
use crate::ServerSettings;
use serde::{Deserialize, Serialize};

pub const MAX_DEVICES: usize = 128;
pub const MAX_BYTES: usize = 24 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Device {
    pub peer: String,
    pub alias: String,
    #[serde(default)]
    pub remote_name: String,
    pub favorite: bool,
    pub last_connected: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    scope: String,
    device: Device,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    version: u32,
    entries: Vec<Entry>,
}
impl Default for Catalog {
    fn default() -> Self {
        Self {
            version: 1,
            entries: Vec::new(),
        }
    }
}
pub fn validate_server(server: &ServerSettings) -> Result<(), &'static str> {
    for value in [&server.rendezvous, &server.relay] {
        if value.len() > 253
            || value
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '/' | '\\'))
        {
            return Err("Server must be a hostname or IP address with an optional port");
        }
    }
    if server.public_key.len() > 256 || server.public_key.chars().any(char::is_control) {
        return Err("Invalid server public key");
    }
    Ok(())
}
pub fn scope(server: &ServerSettings) -> Result<String, &'static str> {
    validate_server(server)?;
    // Relay routing can change without changing a device's identity. ID server
    // and its public key cannot: equal numeric IDs across servers are distinct.
    serde_json::to_string(&(server.rendezvous.to_lowercase(), &server.public_key))
        .map_err(|_| "Cannot encode device server")
}
pub fn validate_peer(peer: &str) -> Result<(), &'static str> {
    if peer.is_empty()
        || peer.len() > 256
        || peer.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err("Invalid device ID or address");
    }
    Ok(())
}
fn validate_alias(alias: &str) -> Result<(), &'static str> {
    if alias.len() > 128 || alias.chars().any(char::is_control) {
        return Err("Device alias must be at most 128 UTF-8 bytes without control characters");
    }
    Ok(())
}
impl Catalog {
    pub fn load(data: &str) -> Result<Self, &'static str> {
        if data.is_empty() {
            return Ok(Self::default());
        }
        if data.len() > MAX_BYTES {
            return Err("Device catalog exceeds its size limit");
        }
        let catalog: Self = serde_json::from_str(data)
            .map_err(|_| "Device catalog is invalid; existing data is preserved")?;
        if catalog.version != 1 || catalog.entries.len() > MAX_DEVICES {
            return Err("Unsupported device catalog");
        }
        let mut keys = std::collections::HashSet::new();
        for entry in &catalog.entries {
            validate_peer(&entry.device.peer)?;
            validate_alias(&entry.device.alias)?;
            validate_alias(&entry.device.remote_name)?;
            if entry.scope.len() > 1024 || !keys.insert((&entry.scope, &entry.device.peer)) {
                return Err("Invalid device catalog keys");
            }
        }
        Ok(catalog)
    }
    pub fn visible(&self, server: &ServerSettings) -> Result<Vec<Device>, &'static str> {
        let key = scope(server)?;
        let mut values: Vec<_> = self
            .entries
            .iter()
            .filter(|e| e.scope == key)
            .map(|e| e.device.clone())
            .collect();
        values.sort_by(|a, b| {
            b.favorite
                .cmp(&a.favorite)
                .then(b.last_connected.cmp(&a.last_connected))
                .then(a.peer.cmp(&b.peer))
        });
        Ok(values)
    }
    pub fn remember(
        &mut self,
        server: &ServerSettings,
        peer: &str,
        now: u64,
    ) -> Result<(), &'static str> {
        self.remember_named(server, peer, "", now)
    }
    pub fn remember_named(
        &mut self,
        server: &ServerSettings,
        peer: &str,
        name: &str,
        now: u64,
    ) -> Result<(), &'static str> {
        validate_peer(peer)?;
        validate_alias(name)?;
        let key = scope(server)?;
        if let Some(entry) = self
            .entries
            .iter_mut()
            .find(|e| e.scope == key && e.device.peer == peer)
        {
            entry.device.last_connected = entry.device.last_connected.max(now);
            if !name.is_empty() {
                entry.device.remote_name = name.into();
            }
        } else {
            self.entries.push(Entry {
                scope: key.clone(),
                device: Device {
                    peer: peer.into(),
                    alias: String::new(),
                    remote_name: name.into(),
                    favorite: false,
                    last_connected: now,
                },
            });
        }
        // Only old, unstarred history may be evicted. Favorites are never
        // silently lost, even when the total serialized-byte budget is reached.
        while self.entries.len() > MAX_DEVICES || self.encoded()?.len() > MAX_BYTES {
            let index = self
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| !e.device.favorite && (e.scope != key || e.device.peer != peer))
                .min_by_key(|(_, e)| e.device.last_connected)
                .map(|(i, _)| i)
                .ok_or(
                    "Device history is full; forget an unused favorite before saving more devices",
                )?;
            self.entries.remove(index);
        }
        Ok(())
    }
    pub fn edit(
        &mut self,
        server: &ServerSettings,
        peer: &str,
        alias: &str,
        favorite: bool,
    ) -> Result<(), &'static str> {
        validate_peer(peer)?;
        validate_alias(alias)?;
        let key = scope(server)?;
        let entry = self
            .entries
            .iter_mut()
            .find(|e| e.scope == key && e.device.peer == peer)
            .ok_or("Device no longer exists; refresh before editing")?;
        entry.device.alias = alias.trim().into();
        entry.device.favorite = favorite;
        Ok(())
    }
    pub fn forget(&mut self, server: &ServerSettings, peer: &str) -> Result<(), &'static str> {
        validate_peer(peer)?;
        let key = scope(server)?;
        self.entries
            .retain(|e| e.scope != key || e.device.peer != peer);
        Ok(())
    }
    fn encoded(&self) -> Result<String, &'static str> {
        serde_json::to_string(self).map_err(|_| "Cannot encode device catalog")
    }
    pub fn store(&self) -> Result<String, &'static str> {
        let data = self.encoded()?;
        if data.len() > MAX_BYTES || self.entries.len() > MAX_DEVICES {
            return Err("Device history is full; forget an unused device before saving");
        }
        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_name_migrates_old_records_and_never_replaces_user_alias() {
        let server = ServerSettings::default();
        let mut c = Catalog::default();
        c.remember(&server, "peer", 1).unwrap();
        c.edit(&server, "peer", "书房", true).unwrap();
        let old = c.store().unwrap().replace(",\"remote_name\":\"\"", "");
        let mut c = Catalog::load(&old).unwrap();
        c.remember_named(&server, "peer", "hermes", 2).unwrap();
        let d = &c.visible(&server).unwrap()[0];
        assert_eq!(d.alias, "书房");
        assert_eq!(d.remote_name, "hermes");
        assert!(d.favorite);
        c.remember_named(&server, "peer", "", 3).unwrap();
        assert_eq!(c.visible(&server).unwrap()[0].remote_name, "hermes");
        assert!(c.remember_named(&server, "peer", "bad\nname", 4).is_err());
        assert!(c
            .remember_named(&server, "peer", &"名".repeat(43), 4)
            .is_err());
    }
    #[test]
    fn same_id_is_isolated_by_server_and_public_key_but_not_relay() {
        let server = ServerSettings::default();
        let mut other = server.clone();
        other.rendezvous = "hermes:21116".into();
        let mut c = Catalog::default();
        c.remember(&server, "123", 4).unwrap();
        c.edit(&server, "123", "书房", true).unwrap();
        c.remember(&other, "123", 5).unwrap();
        assert!(c.visible(&server).unwrap()[0].favorite);
        assert_eq!(c.visible(&other).unwrap()[0].alias, "");
        other.relay = "relay:21117".into();
        assert_eq!(c.visible(&other).unwrap().len(), 1);
        other.public_key = "changed".into();
        assert!(c.visible(&other).unwrap().is_empty());
        let c = Catalog::load(&c.store().unwrap()).unwrap();
        assert_eq!(c.visible(&server).unwrap()[0].alias, "书房");
    }
    #[test]
    fn evicts_only_unstarred_history_and_bounds_encoded_bytes() {
        let server = ServerSettings::default();
        let mut c = Catalog::default();
        c.remember(&server, "kept", 1).unwrap();
        c.edit(&server, "kept", "永久收藏", true).unwrap();
        for i in 2..200 {
            c.remember(&server, &format!("{i}{}", "x".repeat(250)), i)
                .unwrap();
        }
        assert!(c.store().unwrap().len() <= MAX_BYTES);
        let values = c.visible(&server).unwrap();
        assert_eq!(values[0].peer, "kept");
        assert!(values.len() < MAX_DEVICES);
        assert!(values.iter().any(|d| d.peer.starts_with("199")));
        for d in values {
            c.edit(&server, &d.peer, &d.alias, true).unwrap();
        }
        assert!(c.remember(&server, &"y".repeat(256), 999).is_err());
    }
    #[test]
    fn corrupt_future_duplicate_and_oversized_data_are_not_silently_reset() {
        assert!(Catalog::load("{invalid").is_err());
        assert!(Catalog::load(r#"{"version":2,"entries":[]}"#).is_err());
        let server = ServerSettings::default();
        let mut c = Catalog::default();
        c.remember(&server, "123", 7).unwrap();
        c.entries.push(c.entries[0].clone());
        assert!(Catalog::load(&c.encoded().unwrap()).is_err());
        assert!(Catalog::load(&" ".repeat(MAX_BYTES + 1)).is_err());
        assert!(c.edit(&server, "123", "line\nbreak", false).is_err());
        assert!(c.remember(&server, "bad id", 8).is_err());
    }
}
