//! What an XPC message holds. JSON cannot say whether 1 is an int64, a uint64 or a double, nor carry data,
//! a date or a UUID as such, so dock2 reads `{"$int": 1}` and its kin; `XpcValue` writes and reads them.

use base64::Engine as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum XpcValue {
    Null,
    Bool(bool),
    Int(i64),
    Uint(u64),
    Double(f64),
    String(String),
    Data(Vec<u8>),
    /// Milliseconds since 1970.
    Date(f64),
    /// As text, `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`.
    Uuid(String),
    Array(Vec<XpcValue>),
    Dictionary(BTreeMap<String, XpcValue>),
}

impl XpcValue {
    /// A dictionary from its entries: what a message is.
    pub fn dictionary<K: Into<String>>(entries: impl IntoIterator<Item = (K, XpcValue)>) -> Self {
        XpcValue::Dictionary(entries.into_iter().map(|(k, v)| (k.into(), v)).collect())
    }

    pub fn get(&self, key: &str) -> Option<&XpcValue> {
        match self {
            XpcValue::Dictionary(entries) => entries.get(key),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            XpcValue::String(text) => Some(text),
            _ => None,
        }
    }

    /// Any of the three numbers, as an i64 when it fits.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            XpcValue::Int(n) => Some(*n),
            XpcValue::Uint(n) => i64::try_from(*n).ok(),
            XpcValue::Double(n) if n.fract() == 0.0 => Some(*n as i64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            XpcValue::Bool(b) => Some(*b),
            _ => None,
        }
    }

    fn to_json(&self) -> Value {
        match self {
            XpcValue::Null => Value::Null,
            XpcValue::Bool(b) => Value::Bool(*b),
            XpcValue::Int(n) => json!({ "$int": n }),
            XpcValue::Uint(n) if *n <= i64::MAX as u64 => json!({ "$uint": n }),
            XpcValue::Uint(n) => json!({ "$uint": n.to_string() }),
            XpcValue::Double(n) => json!({ "$double": n }),
            XpcValue::String(s) => Value::String(s.clone()),
            XpcValue::Data(bytes) => json!({ "$data": base64::engine::general_purpose::STANDARD.encode(bytes) }),
            XpcValue::Date(ms) => json!({ "$date": ms }),
            XpcValue::Uuid(text) => json!({ "$uuid": text }),
            XpcValue::Array(items) => Value::Array(items.iter().map(XpcValue::to_json).collect()),
            XpcValue::Dictionary(entries) => Value::Object(entries.iter().map(|(k, v)| (k.clone(), v.to_json())).collect::<Map<_, _>>()),
        }
    }

    fn from_json(value: Value) -> Result<Self, String> {
        Ok(match value {
            Value::Null => XpcValue::Null,
            Value::Bool(b) => XpcValue::Bool(b),
            Value::Number(n) => match n.as_i64() {
                Some(i) => XpcValue::Int(i),
                None => XpcValue::Double(n.as_f64().unwrap_or_default()),
            },
            Value::String(s) => XpcValue::String(s),
            Value::Array(items) => XpcValue::Array(items.into_iter().map(XpcValue::from_json).collect::<Result<_, _>>()?),
            Value::Object(map) => {
                if map.len() == 1 {
                    let (tag, inner) = map.iter().next().unwrap();
                    let number = |v: &Value| v.as_f64().ok_or_else(|| format!("{tag} holds no number"));
                    match tag.as_str() {
                        "$int" => return inner.as_i64().map(XpcValue::Int).ok_or_else(|| "$int holds no int".into()),
                        "$uint" => {
                            return inner
                                .as_u64()
                                .or_else(|| inner.as_str().and_then(|s| s.parse().ok()))
                                .map(XpcValue::Uint)
                                .ok_or_else(|| "$uint holds no uint".into());
                        }
                        "$double" => return number(inner).map(XpcValue::Double),
                        "$date" => return number(inner).map(XpcValue::Date),
                        "$data" => {
                            let text = inner.as_str().ok_or("$data holds no base64")?;
                            return base64::engine::general_purpose::STANDARD.decode(text).map(XpcValue::Data).map_err(|e| e.to_string());
                        }
                        "$uuid" => return inner.as_str().map(|s| XpcValue::Uuid(s.into())).ok_or_else(|| "$uuid holds no text".into()),
                        _ => {}
                    }
                }
                XpcValue::Dictionary(map.into_iter().map(|(k, v)| Ok((k, XpcValue::from_json(v)?))).collect::<Result<_, String>>()?)
            }
        })
    }
}

impl From<&str> for XpcValue {
    fn from(text: &str) -> Self {
        XpcValue::String(text.into())
    }
}

impl From<String> for XpcValue {
    fn from(text: String) -> Self {
        XpcValue::String(text)
    }
}

impl From<i64> for XpcValue {
    fn from(n: i64) -> Self {
        XpcValue::Int(n)
    }
}

impl From<bool> for XpcValue {
    fn from(b: bool) -> Self {
        XpcValue::Bool(b)
    }
}

impl Serialize for XpcValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.to_json().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for XpcValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        XpcValue::from_json(Value::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_number_says_which_it_is_and_reads_back() {
        let message = XpcValue::dictionary([
            ("count", XpcValue::Int(3)),
            ("size", XpcValue::Uint(u64::MAX)),
            ("ratio", XpcValue::Double(1.0)),
            ("blob", XpcValue::Data(vec![0, 1, 2])),
            ("name", "agent".into()),
        ]);
        let text = serde_json::to_string(&message).unwrap();
        assert!(text.contains(r#""ratio":{"$double":1.0}"#) && text.contains(r#""size":{"$uint":"18446744073709551615"}"#));
        assert_eq!(serde_json::from_str::<XpcValue>(&text).unwrap(), message);
        // Plain JSON, as a service's reply never is but a plugin may write: a whole number is an int.
        assert_eq!(serde_json::from_str::<XpcValue>("[1, 1.5]").unwrap(), XpcValue::Array(vec![XpcValue::Int(1), XpcValue::Double(1.5)]));
    }
}
