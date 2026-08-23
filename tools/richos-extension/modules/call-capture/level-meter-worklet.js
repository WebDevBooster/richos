/**
 * RichOS — level meter (AudioWorklet processor).
 *
 * Why a worklet and not an AnalyserNode polled on a timer: the recorder lives in a hidden
 * offscreen document, and Chrome throttles timers in hidden documents. A polled analyser
 * therefore samples a tiny, badly-aligned slice of the audio — measured live on this machine,
 * a polled meter read exactly 0.000 for a whole session while the recording itself was at
 * −20 dB. That would have made "digital silence" alarms fire on perfectly healthy calls and,
 * worse, made the level indicator lie.
 *
 * This processor runs on the audio thread and sees EVERY 128-sample block, so peak and mean
 * are exact for the reporting window regardless of what the main thread is doing.
 */

const REPORT_INTERVAL_SECONDS = 0.1;

class LevelMeter extends AudioWorkletProcessor {
  constructor() {
    super();
    this.peak = 0;
    this.sumSquares = 0;
    this.frames = 0;
    this.sinceReport = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (input && input.length) {
      for (const channel of input) {
        for (let i = 0; i < channel.length; i += 1) {
          const sample = channel[i];
          const magnitude = sample < 0 ? -sample : sample;
          if (magnitude > this.peak) this.peak = magnitude;
          this.sumSquares += sample * sample;
        }
        this.frames += channel.length;
      }
      this.sinceReport += input[0].length / sampleRate;
    } else {
      // No input at all is itself information: report zeros rather than going quiet.
      this.sinceReport += 128 / sampleRate;
    }

    if (this.sinceReport >= REPORT_INTERVAL_SECONDS) {
      this.port.postMessage({
        peak: this.peak,
        rms: this.frames ? Math.sqrt(this.sumSquares / this.frames) : 0,
        frames: this.frames,
      });
      this.peak = 0;
      this.sumSquares = 0;
      this.frames = 0;
      this.sinceReport = 0;
    }
    return true; // keep processing for the whole call
  }
}

registerProcessor('richos-level-meter', LevelMeter);
