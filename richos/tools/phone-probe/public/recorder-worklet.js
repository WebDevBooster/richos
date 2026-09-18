// The capture node for check 2.
//
// It does one thing: copy every block of microphone samples to the main thread. No codec, no
// MediaRecorder, no format negotiation — plan §3.3's whole point is that the Safari-versus-Chrome
// container question does not arise if we never ask for a container. Downsampling to 16 kHz and
// writing the WAV header happen on the main thread in app.js, because they are not real-time work
// and the audio thread must not be given anything it can be late for.
//
// `inputs[0][0]` is REUSED by the engine between calls, so it is copied. Posting the view itself
// hands the main thread a buffer whose contents change underneath it — silence or garbage, and the
// bug reads as a broken microphone, which is the one wrong answer this probe must not give.

class ProbeCapture extends AudioWorkletProcessor {
	constructor() {
		super();
		this.running = true;
		this.port.onmessage = (event) => {
			if (event.data === 'stop') this.running = false;
		};
	}

	process(inputs) {
		if (!this.running) return false; // let the node be collected
		const channel = inputs[0] && inputs[0][0];
		if (channel && channel.length) {
			const copy = new Float32Array(channel);
			this.port.postMessage(copy, [copy.buffer]);
		}
		// Keep alive even on an empty block: a microphone that has not produced its first block yet
		// is normal for the first few milliseconds, and returning false there would end capture.
		return true;
	}
}

registerProcessor('probe-capture', ProbeCapture);
