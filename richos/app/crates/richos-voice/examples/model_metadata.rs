//! Print the metadata seen by the actual compiled voice readers, without audio or disk state.
//! Used by engine/voice/tests/consumers.test.mjs to compare Rust, JS and shell consumers.
use richos_voice::{hardware::Costs, toolchain};
use serde_json::json;

fn main() {
    let costs = Costs::load();
    let models: Vec<_> = costs
        .models
        .values()
        .map(|m| {
            json!({
                "id": m.id,
                "sha256": toolchain::pinned_sha256(&m.id),
                "utterancePeakRssBytes": m.utterance_peak_rss,
                "referenceUtteranceSeconds": m.reference_utterance_secs,
                "longFormSecondsPerAudioSecond": m.long_form_rate,
                "longFormPeakRssBytes": m.long_form_peak_rss,
            })
        })
        .collect();
    println!(
        "{}",
        json!({
            "models": models,
            "liveLadder": costs.live_ladder,
            "batchLadder": costs.batch_ladder,
            "safeRung": costs.safe_rung,
            "liveCeilingSeconds": costs.live_ceiling_secs,
            "liveTargetSeconds": costs.live_target_secs,
            "batchRealTimeMultiple": costs.batch_real_time_multiple,
            "referenceVersion": toolchain::reference_version(),
        })
    );
}
