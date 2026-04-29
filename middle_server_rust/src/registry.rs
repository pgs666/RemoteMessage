use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

const MAX_CACHED_GATEWAYS: usize = 4096;

#[derive(Clone, Default)]
pub struct GatewayRegistry {
    inner: Arc<Mutex<HashMap<String, String>>>,
}

impl GatewayRegistry {
    pub fn upsert(&self, device_id: String, public_key_pem: String) {
        let Ok(mut map) = self.inner.lock() else {
            return;
        };
        if map.len() >= MAX_CACHED_GATEWAYS
            && !map.contains_key(&device_id)
            && let Some(first_key) = map.keys().next().cloned()
        {
            map.remove(&first_key);
        }
        map.insert(device_id, public_key_pem);
    }

    pub fn get(&self, device_id: &str) -> Option<String> {
        self.inner.lock().ok()?.get(device_id).cloned()
    }
}
