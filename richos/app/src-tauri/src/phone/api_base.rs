//! **THE REACHABILITY SEAM — the address is DATA, never the origin.** Plan §10.7 and §10.8
//! item 1, and the plan calls it *"the load-bearing recommendation"* and *"the thing to build
//! first"*.
//!
//! # The flaw this exists to avoid, in the plan's own words
//!
//! > *"A PWA's identity **is** its origin: scheme, host and port. The service worker, the push
//! > subscription, the cached shell and the Home Screen icon are all scoped to it … If the
//! > origin were the public address, every change would orphan the installed app, the
//! > subscription and the cache — and no push can fix that, because the push is *delivered to*
//! > the origin it is trying to replace."*
//!
//! So: the origin is fixed for the life of an installed phone app, and the **API base** is one
//! stored value the phone reads before every request. It arrives in the pair response, in every
//! snapshot, in an `api-base` event when it changes, and in every push payload.
//!
//! # One provider, and that is the point
//!
//! *"v1 should not ship without it **even if it only ever has one provider** — it is what keeps
//! the phone app from being rewritten twice."* The one provider here is [`Tailnet`], which
//! offers the origin the channel came up on. A router door (§10.2) or an IPv6 address (§10.3)
//! would each be a new entry in the ranked list and change nothing on the phone.
//!
//! **It was [`Tailnet`] until CEO §61, 2026-09-19**, and the rename is the seam doing exactly what
//! it was built for: the provider changed and neither the phone nor any caller of `current()`
//! noticed. What the phone is told is the origin; the name beside it is for a person reading a
//! log.
//!
//! # The degraded mode is honest for free
//!
//! When no provider can offer anything, [`ApiBaseDesk::current`] returns `None` and the phone
//! shows the queued-send state plan §2.4 already specifies, with a reason he can read. **It
//! never guesses an address and never promises a reach it has not tested** (§10.8).

use std::sync::Mutex;

/// One way the phone might currently reach this Mac.
///
/// **Several members of this module are built and not yet called**, and that is the seam doing its
/// job rather than dead code: plan §10.8 item 1 says to build it *"even if it only ever has one
/// provider — it is what keeps the phone app from being rewritten twice."* With one provider that
/// never stops answering, `take_change` never fires; slice D's router door is the first caller.
/// The alternative — leaving the interface out until something needs it — is the rewrite the plan
/// names.
#[allow(dead_code)]
pub trait AddressProvider: Send + Sync {
    /// A short, stable name. It travels to the phone on the `api-base` event as `reason`, so
    /// the phone can say *why* in plain words rather than showing a URL.
    fn name(&self) -> &'static str;

    /// The API base this provider can offer right now, or `None` when it cannot offer one.
    ///
    /// **`None` is a real answer and it is never a placeholder.** A provider that returns a
    /// best guess would be a provider that promises a reach nobody tested.
    fn offer(&self) -> Option<String>;
}

/// What the phone is told to use.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    pub api_base: String,
    /// The provider's name — `"tailnet"` today.
    pub reason: &'static str,
}

/// The home network: the origin itself. Always available while the listener is up, because it
/// **is** the listener.
pub struct Tailnet {
    origin: String,
}

impl Tailnet {
    pub fn new(origin: impl Into<String>) -> Self {
        Tailnet { origin: origin.into() }
    }
}

impl AddressProvider for Tailnet {
    fn name(&self) -> &'static str {
        "tailnet"
    }
    fn offer(&self) -> Option<String> {
        Some(self.origin.clone())
    }
}

#[allow(dead_code)]
/// A provider that never offers anything. Not dead code and not a mock: it is the honest
/// stand-in for a provider that is configured but cannot currently reach, and it is what the
/// "no usable address" path is tested with.
pub struct Unreachable {
    name: &'static str,
}

impl Unreachable {
    pub fn new(name: &'static str) -> Self {
        Unreachable { name }
    }
}

impl AddressProvider for Unreachable {
    fn name(&self) -> &'static str {
        self.name
    }
    fn offer(&self) -> Option<String> {
        None
    }
}

#[allow(dead_code)]
/// What [`ApiBaseDesk::take_change`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiBaseChange {
    /// The phone already has the right answer. Nothing is emitted — which is what keeps the
    /// `api-base` event off a timer, as plan §6 requires.
    Unchanged,
    /// A new API base. Emit it.
    Moved(Offer),
    /// There is no usable address any more. Emit that, so the phone can queue with a reason
    /// rather than post into nothing.
    Lost,
}

/// The ranked list, and the memory of what the phone was last told.
pub struct ApiBaseDesk {
    /// Best first. The order IS the ranking — there is no priority field to get out of step
    /// with the list.
    providers: Vec<Box<dyn AddressProvider>>,
    last_told: Mutex<Option<Offer>>,
}

impl ApiBaseDesk {
    /// The general constructor. This slice calls `only`; slice D's router door is the first
    /// caller with a list — see the note on [`AddressProvider`] for why it is built now.
    #[allow(dead_code)]
    pub fn new(providers: Vec<Box<dyn AddressProvider>>) -> Self {
        ApiBaseDesk { providers, last_told: Mutex::new(None) }
    }

    /// The one provider used in this slice.
    pub fn only(origin: impl Into<String>) -> Self {
        ApiBaseDesk::new(vec![Box::new(Tailnet::new(origin))])
    }

    /// The best address the Mac can currently offer, or `None`.
    pub fn current(&self) -> Option<Offer> {
        for provider in &self.providers {
            if let Some(api_base) = provider.offer() {
                return Some(Offer { api_base, reason: provider.name() });
            }
        }
        None
    }

    /// Has the answer moved since the phone was last told?
    ///
    /// **Three answers, not two, and the third is why this is not an `Option`.** An earlier
    /// draft returned `Option<Offer>` and could not tell *"nothing changed"* from *"the last
    /// address we had is gone"* — the second is the change the phone most needs to hear,
    /// because without it the phone keeps posting into nothing instead of showing its queued
    /// state with a reason.
    pub fn take_change(&self) -> ApiBaseChange {
        let current = self.current();
        let mut last = self.last_told.lock().unwrap();
        if *last == current {
            return ApiBaseChange::Unchanged;
        }
        *last = current.clone();
        match current {
            Some(offer) => ApiBaseChange::Moved(offer),
            None => ApiBaseChange::Lost,
        }
    }

    /// Record what the phone has been told, without treating it as a change. Used when the
    /// value rides along on a snapshot or a pair response.
    pub fn mark_told(&self, offer: Option<Offer>) {
        *self.last_told.lock().unwrap() = offer;
    }

    /// The names of every provider, best first. For the settings screen, which should be able
    /// to say what the Mac is willing to try rather than only what it managed.
    pub fn ranking(&self) -> Vec<&'static str> {
        self.providers.iter().map(|p| p.name()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_one_provider_in_this_slice_offers_the_origin_itself() {
        let desk = ApiBaseDesk::only("https://mm1.tail9a3b2.ts.net:8443");
        assert_eq!(
            desk.current(),
            Some(Offer { api_base: "https://mm1.tail9a3b2.ts.net:8443".into(), reason: "tailnet" })
        );
        assert_eq!(desk.ranking(), vec!["tailnet"]);
    }

    #[test]
    fn the_order_of_the_list_is_the_ranking_and_the_first_one_that_can_answer_wins() {
        // What every later provider is: a new entry in this list. If the ranking were a field
        // somewhere else, the two could disagree.
        let desk = ApiBaseDesk::new(vec![
            Box::new(Unreachable::new("ipv6")),
            Box::new(Tailnet::new("https://mm1.tail9a3b2.ts.net:8443")),
        ]);
        assert_eq!(desk.ranking(), vec!["ipv6", "tailnet"]);
        assert_eq!(desk.current().unwrap().reason, "tailnet");

        let better = ApiBaseDesk::new(vec![
            Box::new(Tailnet::new("https://first.example")),
            Box::new(Tailnet::new("https://second.example")),
        ]);
        assert_eq!(better.current().unwrap().api_base, "https://first.example");
    }

    #[test]
    fn no_usable_address_is_none_rather_than_a_guess() {
        // Plan §10.8: "The app never retries silently and never promises a reach it has not
        // tested." The phone's queued-send state depends on this being `None` rather than a
        // plausible-looking URL that does not answer.
        let desk = ApiBaseDesk::new(vec![
            Box::new(Unreachable::new("door")),
            Box::new(Unreachable::new("ipv6")),
        ]);
        assert_eq!(desk.current(), None);
        // POSITIVE CONTROL: the same desk with a reachable provider does answer, so the `None`
        // above is about the providers and not about the desk being inert.
        let with_home = ApiBaseDesk::new(vec![
            Box::new(Unreachable::new("door")),
            Box::new(Tailnet::new("https://mm1.tail9a3b2.ts.net:8443")),
        ]);
        assert!(with_home.current().is_some());
    }

    #[test]
    fn a_change_is_reported_once_and_an_unchanged_answer_is_reported_never() {
        // This is what keeps the `api-base` event off a timer, which plan §6 forbids: the
        // event fires on a change and on nothing else.
        let desk = ApiBaseDesk::only("https://mm1.tail9a3b2.ts.net:8443");
        assert_eq!(
            desk.take_change(),
            ApiBaseChange::Moved(Offer { api_base: "https://mm1.tail9a3b2.ts.net:8443".into(), reason: "tailnet" })
        );
        assert_eq!(desk.take_change(), ApiBaseChange::Unchanged, "an unchanged answer was reported");
        assert_eq!(desk.take_change(), ApiBaseChange::Unchanged);
    }

    #[test]
    fn losing_the_last_address_is_its_own_answer_and_not_silence() {
        // THE REASON `take_change` RETURNS THREE THINGS. Going from reachable to unreachable
        // has to reach the phone, or it keeps posting into nothing instead of showing its
        // queued state. An `Option` return could not say this at all.
        let gone = ApiBaseDesk::new(vec![Box::new(Unreachable::new("gone"))]);
        gone.mark_told(Some(Offer { api_base: "https://mm1.tail9a3b2.ts.net:8443".into(), reason: "tailnet" }));
        assert_eq!(gone.take_change(), ApiBaseChange::Lost);
        // And it is reported once, not on every poll.
        assert_eq!(gone.take_change(), ApiBaseChange::Unchanged);
    }

    #[test]
    fn what_the_phone_was_told_can_be_recorded_without_being_a_change() {
        // The value rides on the pair response and on every snapshot, so recording it there
        // must not make the next `take_change` fire for something the phone already has.
        let desk = ApiBaseDesk::only("https://mm1.tail9a3b2.ts.net:8443");
        desk.mark_told(desk.current());
        assert_eq!(desk.take_change(), ApiBaseChange::Unchanged);
    }

    #[test]
    fn the_offer_serializes_as_the_two_fields_the_contract_names() {
        let json = serde_json::to_value(Offer {
            api_base: "https://mm1.tail9a3b2.ts.net:8443".into(),
            reason: "tailnet",
        })
        .unwrap();
        assert_eq!(json["apiBase"], "https://mm1.tail9a3b2.ts.net:8443");
        assert_eq!(json["reason"], "tailnet");
        assert_eq!(json.as_object().unwrap().len(), 2);
    }
}
