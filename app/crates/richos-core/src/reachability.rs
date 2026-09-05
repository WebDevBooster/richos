//! **REACHABILITY, PROBED AT REALISTIC SIZE** — `open-items.md` row 3.30's fourth answer.
//!
//! > *"A cheap health check is worse than none, because it manufactures confidence. If the
//! > app reports a status, that status has to have been earned by a request of the same
//! > order as the work."*
//!
//! ## THE MEASUREMENT THIS EXISTS FOR
//!
//! On 2026-09-03, in the same minutes that four large briefs died on their initial context
//! load with `529 Overloaded`, a one-command probe — `pwd`, three characters — completed
//! normally in 51 seconds. **A degraded API does not fail uniformly. It fails the expensive
//! requests first.** So the arithmetic that matters is not "did a request succeed" but "how
//! big was the request that succeeded, compared to the work":
//!
//! ```text
//!   the probe that PASSED on 2026-09-03            3 chars
//!   the briefs that FAILED in the same minutes     tens of thousands of chars
//!   what a health check built on that probe        would have reported HEALTHY
//! ```
//!
//! ## THE ONE RULE, AND IT IS STRUCTURAL RATHER THAN ADVISORY
//!
//! [`ReachabilityVerdict::Reachable`] cannot be constructed by a probe smaller than the
//! floor. A cheap probe that succeeds returns [`ReachabilityVerdict::Unproven`], which is a
//! statement about the PROBE and not about the API, and which carries both numbers so the
//! gap is a fact rather than a footnote. There is no flag that relaxes it: a caller who
//! wants a stronger answer sends a bigger request, which is the honest price.
//!
//! ## THE FLOOR IS THE LARGEST RECENT REQUEST, NOT THE TYPICAL ONE
//!
//! A median would be the wrong statistic here and the reason is the finding itself. Under a
//! size-dependent failure the median request can be sailing through while the large one —
//! the actual brief, the re-primed session — dies every time. So the floor is derived from
//! the BIGGEST thing the app has actually sent recently ([`WorkSize::from_recent`]), because
//! that is the request that has to work for RichOS to be usable, and a status that vouches
//! for less than that is vouching for a workload nobody has.
//!
//! ## A PROBE COSTS MONEY, AND THIS MODULE NEVER SPENDS IT ON ITS OWN
//!
//! Under BYO-Anthropic the customer is billed for every token, so a realistic-size probe is
//! not free and a periodic one would be a standing charge for a number nobody asked for.
//! Nothing here has a timer, a scheduler or a background task; a probe happens when a caller
//! calls one, and [`ReachabilityProbe::estimated_cost_chars`] states what it will send
//! before it sends it.
//!
//! ## WHAT EXISTS IN THIS TREE TODAY, CHECKED RATHER THAN ASSUMED
//!
//! **There is no cheap ping to remove.** Nothing in `app/` reports upstream reachability at
//! all: `work_gate.rs` answers "is RichOS doing anything" from local worker rows and makes
//! no network claim, `setup.rs` checks that a `claude` binary exists and is Anthropic's, and
//! `native.rs`'s `initialize` handshake (measured at 697.9 ms) is a conversation with a
//! LOCAL CHILD PROCESS that never touches the API. So this module removes nothing; it exists
//! so that the first surface to report a status cannot earn it cheaply. That is stated here
//! because "we looked and found none" and "we did not look" are different claims.

use crate::upstream::UpstreamFailure;

/// **How big the app's real requests actually are, measured.**
///
/// Never a constant. A RichOS install that sends short questions has a small floor and one
/// that sends re-primed sessions has a large one, and a probe is honest against ITS OWN
/// install rather than against a number somebody picked in this file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkSize {
    /// The largest single request measured in the sample, in characters.
    pub largest_chars: usize,
    /// How many requests the figure was derived from. `0` means nothing was measured, and
    /// [`WorkSize::from_recent`] returns `None` in that case rather than a zero floor —
    /// a floor of zero would let any probe at all claim [`ReachabilityVerdict::Reachable`],
    /// which is the defect this module exists to prevent, wearing a struct.
    pub sample: usize,
}

impl WorkSize {
    /// Derive the floor from measured request sizes, largest wins.
    ///
    /// `sizes` is what the app SENT — prompt plus whatever priming went with it — not what
    /// came back. Returns `None` for an empty sample, because "we have never sent anything"
    /// and "we send tiny things" are different facts and only one of them supports a floor.
    pub fn from_recent(sizes: &[usize]) -> Option<WorkSize> {
        let largest = sizes.iter().copied().max()?;
        if largest == 0 {
            return None;
        }
        Some(WorkSize { largest_chars: largest, sample: sizes.len() })
    }
}

/// What a probe is allowed to conclude.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReachabilityVerdict {
    /// A request of at least [`WorkSize::largest_chars`] went through. `probe_chars` is
    /// what was actually sent, and it is carried because a verdict only ever vouches for
    /// its own size — see [`ReachabilityVerdict::vouches_for`].
    Reachable { probe_chars: usize },
    /// A request of realistic size came back with a classified upstream failure.
    Failed { failure: UpstreamFailure, probe_chars: usize },
    /// **The probe was too cheap to prove anything, and this is the whole point of the
    /// module.** It says nothing about the API and everything about the question that was
    /// asked of it. Both numbers are carried so the shortfall is a measurement.
    Unproven { probe_chars: usize, floor_chars: usize },
    /// No floor could be derived, because nothing has been sent yet. A probe of ANY size
    /// against an unmeasured install would be a number with no scale on it.
    Unmeasured,
}

impl ReachabilityVerdict {
    /// **Would this verdict vouch for a request of `chars`?**
    ///
    /// Only [`ReachabilityVerdict::Reachable`] ever answers `true`, and only up to its own
    /// probe size. This is the method a future caller uses instead of `matches!(v,
    /// Reachable { .. })`, because "it is up" is not a fact — "it is up for a request this
    /// big" is.
    pub fn vouches_for(&self, chars: usize) -> bool {
        matches!(self, ReachabilityVerdict::Reachable { probe_chars } if *probe_chars >= chars)
    }

    /// The CEO-facing line.
    ///
    /// **`Unproven` does NOT say "healthy" and does not say "down".** It says the check did
    /// not run at the size that matters, which is the true answer and the one a cheap ping
    /// would have replaced with a green tick.
    pub fn ceo_message(&self) -> String {
        match self {
            ReachabilityVerdict::Reachable { probe_chars } => format!(
                "Claude answered a request of {probe_chars} characters just now, which is the \
                 size RichOS actually sends. It is working."
            ),
            ReachabilityVerdict::Failed { failure, .. } => failure.fault.ceo_message().to_string(),
            ReachabilityVerdict::Unproven { probe_chars, floor_chars } => format!(
                "That check sent {probe_chars} characters where RichOS's own work runs to \
                 {floor_chars}, so it proves nothing about whether real work would get \
                 through. A small request can succeed while every large one fails."
            ),
            ReachabilityVerdict::Unmeasured => {
                "RichOS has not sent Claude enough work yet to know what size to test at, so \
                 there is nothing honest to report about whether it is reachable."
                    .to_string()
            }
        }
    }

    /// One line for the operator.
    pub fn summary(&self) -> String {
        match self {
            ReachabilityVerdict::Reachable { probe_chars } => {
                format!("reachable probe_chars={probe_chars}")
            }
            ReachabilityVerdict::Failed { failure, probe_chars } => {
                format!("failed probe_chars={probe_chars} {}", failure.summary())
            }
            ReachabilityVerdict::Unproven { probe_chars, floor_chars } => {
                format!("unproven probe_chars={probe_chars} floor_chars={floor_chars}")
            }
            ReachabilityVerdict::Unmeasured => "unmeasured".to_string(),
        }
    }
}

/// **A reachability check that cannot be answered cheaply.**
///
/// Holds the measured floor and nothing else. It has no clock, no scheduler and no
/// connection: the caller supplies the send, which is what makes the whole thing testable
/// against [`crate::upstream::FakeUpstream`] rather than against a network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReachabilityProbe {
    floor: Option<WorkSize>,
}

impl ReachabilityProbe {
    /// Build a probe against a measured floor.
    pub fn new(floor: Option<WorkSize>) -> ReachabilityProbe {
        ReachabilityProbe { floor }
    }

    /// Derive the floor from what this install has actually been sending.
    pub fn from_recent(sizes: &[usize]) -> ReachabilityProbe {
        ReachabilityProbe { floor: WorkSize::from_recent(sizes) }
    }

    /// What a probe would send, in characters. `None` when there is no floor, in which case
    /// nothing is sent at all — a probe with no scale would spend the customer's money to
    /// learn nothing.
    pub fn estimated_cost_chars(&self) -> Option<usize> {
        self.floor.map(|f| f.largest_chars)
    }

    /// **Run one probe.**
    ///
    /// `send` receives a payload of exactly [`ReachabilityProbe::estimated_cost_chars`]
    /// characters and returns the vendor's own text on failure — the same string
    /// [`UpstreamFailure::classify_lines`] reads everywhere else, so one classifier decides
    /// and this does not get a second opinion.
    ///
    /// **`send` is never called when there is no floor.** That is not an optimization; it
    /// is the refusal. An unmeasured install gets [`ReachabilityVerdict::Unmeasured`] and
    /// is billed for nothing.
    pub fn run<S>(&self, send: S) -> ReachabilityVerdict
    where
        S: FnOnce(&str) -> Result<(), String>,
    {
        let Some(floor) = self.floor else {
            return ReachabilityVerdict::Unmeasured;
        };
        let payload = Self::payload(floor.largest_chars);
        self.judge(payload.chars().count(), send(&payload))
    }

    /// **Judge a request somebody else sent** — the arm that makes the guard structural.
    ///
    /// A caller with its own transport (the Tauri shell, a probe example, a future health
    /// surface) reports what it sent and what came back, and gets the SAME verdict rules. A
    /// caller that sent three characters gets [`ReachabilityVerdict::Unproven`] even though
    /// its request succeeded, because the rule lives here and not in the caller's honesty.
    pub fn judge(&self, probe_chars: usize, outcome: Result<(), String>) -> ReachabilityVerdict {
        let Some(floor) = self.floor else {
            return ReachabilityVerdict::Unmeasured;
        };
        match outcome {
            // A FAILURE IS REPORTED WHATEVER THE SIZE, and the asymmetry is deliberate. A
            // small request that failed is real evidence that something is wrong; a small
            // request that succeeded is not evidence that anything is right. Treating the
            // two symmetrically would either hide a real outage or manufacture a green tick,
            // and only one of those errors is safe.
            Err(text) => match UpstreamFailure::classify_lines(&text) {
                Some(failure) => ReachabilityVerdict::Failed { failure, probe_chars },
                // Not an upstream fault at all — a local failure. It says nothing about
                // reachability, so it does not get to answer the question.
                None => ReachabilityVerdict::Unproven { probe_chars, floor_chars: floor.largest_chars },
            },
            Ok(()) if probe_chars >= floor.largest_chars => {
                ReachabilityVerdict::Reachable { probe_chars }
            }
            Ok(()) => ReachabilityVerdict::Unproven { probe_chars, floor_chars: floor.largest_chars },
        }
    }

    /// The probe payload: a real question at the measured size.
    ///
    /// **Padded with prose rather than with one repeated character**, because the cost being
    /// modeled is the model's — a long run of the same byte is not the same work as a long
    /// document, and a probe whose payload is cheaper to process than the work it stands for
    /// is the same manufactured confidence at a different layer.
    ///
    /// It is truncated on a CHAR boundary (`chars().take`), never a byte one: the padding is
    /// ASCII today and slicing by byte would be a panic waiting for the first time somebody
    /// changes it.
    pub fn payload(chars: usize) -> String {
        const LEAD: &str = "Reply with the single word OK. The rest of this message is \
                            padding so that this request is the same size as the work \
                            RichOS actually sends, and it can be ignored. ";
        const PAD: &str = "The quick brown fox jumps over the lazy dog while the release \
                           notes are still being written and nobody has read them yet. ";
        let mut out = String::with_capacity(chars + PAD.len());
        out.push_str(LEAD);
        while out.chars().count() < chars {
            out.push_str(PAD);
        }
        out.chars().take(chars.max(LEAD.chars().count())).collect()
    }

    /// The floor this probe holds, for reporting.
    pub fn floor(&self) -> Option<WorkSize> {
        self.floor
    }
}

/// A convenience for the one thing a caller most often wants to say: is the fault, if any,
/// one that clears on a schedule?
pub fn schedule_of(verdict: &ReachabilityVerdict) -> Option<bool> {
    match verdict {
        ReachabilityVerdict::Failed { failure, .. } => {
            Some(failure.fault.clears_on_a_known_schedule())
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the payload is EXACTLY the requested size, so "a request of the same
    /// order as the work" is a measurement and not an intention.
    #[test]
    fn the_payload_is_exactly_the_requested_size() {
        for n in [200usize, 1_000, 12_345, 120_000] {
            assert_eq!(ReachabilityProbe::payload(n).chars().count(), n, "size {n}");
        }
    }

    /// INVARIANT: an empty sample yields no floor. A zero floor would let a three-character
    /// probe report `Reachable`, which is the defect this module exists to prevent.
    #[test]
    fn an_unmeasured_install_has_no_floor_and_therefore_no_verdict() {
        assert_eq!(WorkSize::from_recent(&[]), None);
        assert_eq!(WorkSize::from_recent(&[0, 0]), None);
        let p = ReachabilityProbe::from_recent(&[]);
        assert_eq!(p.estimated_cost_chars(), None);
        assert_eq!(p.run(|_| panic!("nothing may be sent, and nothing may be billed")), ReachabilityVerdict::Unmeasured);
    }

    /// INVARIANT: the floor is the LARGEST recent request, not the typical one — under a
    /// size-dependent failure the median can be sailing through while the brief dies.
    #[test]
    fn the_floor_is_the_largest_recent_request_not_the_median() {
        let w = WorkSize::from_recent(&[10, 12, 11, 120_000, 9]).unwrap();
        assert_eq!(w.largest_chars, 120_000);
        assert_eq!(w.sample, 5);
    }
}
