//! Managed access control. The service sees public identities and allocation state only.
//! Conversation requests still terminate at the existing authenticated phone channel.
pub mod client;
pub mod state;
pub mod supervisor;
pub const ORIGIN: &str = "https://connect.richos.ceo";
pub const PORT: u16 = 18443;
pub const METRICS_PORT: u16 = 18444;
