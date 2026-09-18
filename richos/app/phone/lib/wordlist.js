// THE WORD LIST — 256 words, one per byte, so a certificate fingerprint can be SAID rather than
// read character by character.
//
// Why this file exists at all: the CEO's own probe walk ended with
//
//     "On the second page ... an ugly horizontal scroll bar appeared. I suspect that was caused by
//      the long SHA256 which was all in one line on the second page."
//
// He was right about the cause, and the fix is not to wrap the hash. It is to stop putting a hash
// in front of him. Plan §4.1 already says the pairing screens show a SIX-WORD fingerprint of the
// certificate authority on both the Mac and the phone, and he compares words. Six words spoken
// aloud are a comparison a person can actually perform; sixty-four hexadecimal characters are a
// comparison a person pretends to perform.
//
// THE CONSTRAINT THAT SHAPED THE LIST, and it is not "nice words":
//
//   * 256 entries exactly, so the encoding is one byte to one word with no bit packing. A Rust
//     implementation on the Mac is an array index — which matters, because the Mac must show the
//     SAME six words or the comparison means nothing (CONTRACT-STUB.md §2(d)).
//   * lowercase a-z only, three to seven letters. Nothing to spell out, nothing with a hyphen or an
//     accent, nothing that changes shape when a phone capitalizes it.
//   * NO TWO WORDS WITHIN ONE EDIT of each other. "cat" and "cap" are a mishearing waiting to
//     happen; `test/fingerprint.test.js` computes the edit distance between all 32,640 pairs and
//     fails under two. That test is the reason this list can be trusted rather than admired.
//   * Concrete and ordinary. A word he has to think about is a word he will read twice.
//   * American English (standing rule): `harbor`, `fiber`, `parlor`, `meter` — never the British
//     spellings. The list is scanned for the common British variants by the same test.
//
// Sixteen rows of sixteen, so the count is countable by eye and a dropped word is visible.
//
// Loads as a plain script (defines `globalThis.RichOSWordList`) and as a CommonJS module.

(function (root, factory) {
	const api = factory();
	if (typeof module === 'object' && module.exports) module.exports = api;
	root.RichOSWordList = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
	'use strict';

	const WORDS = [
		'anchor', 'apple', 'april', 'arrow', 'artist', 'aspen', 'autumn', 'avenue', 'bacon', 'badge', 'basket', 'beard', 'beetle', 'bench', 'berry', 'bishop',
		'blanket', 'blossom', 'bonus', 'border', 'bottle', 'boulder', 'branch', 'bridge', 'bronze', 'brush', 'bucket', 'buffalo', 'bundle', 'butler', 'cabin', 'cactus',
		'camera', 'candle', 'canyon', 'carbon', 'cargo', 'carpet', 'castle', 'cavern', 'cedar', 'cement', 'census', 'chapel', 'cherry', 'chimney', 'circus', 'clover',
		'cobalt', 'cobra', 'coffee', 'collar', 'column', 'comet', 'compass', 'copper', 'coral', 'cotton', 'cousin', 'cowboy', 'crayon', 'cricket', 'crystal', 'cushion',
		'dagger', 'dairy', 'dancer', 'decade', 'denim', 'desert', 'diamond', 'diesel', 'dinner', 'doctor', 'dolphin', 'domain', 'donkey', 'dragon', 'drawer', 'drummer',
		'eagle', 'elbow', 'elder', 'ember', 'engine', 'estate', 'expert', 'fabric', 'falcon', 'farmer', 'feather', 'fiber', 'fiddle', 'figure', 'filter', 'finger',
		'flame', 'flute', 'forest', 'fortune', 'fossil', 'freezer', 'friend', 'frozen', 'gadget', 'galaxy', 'gallon', 'garden', 'garlic', 'gazelle', 'giant', 'glacier',
		'glass', 'glove', 'granite', 'grape', 'gravel', 'guitar', 'gutter', 'hammer', 'harbor', 'harvest', 'helmet', 'hermit', 'hockey', 'honey', 'horizon', 'hornet',
		'hotel', 'hunter', 'iceberg', 'igloo', 'indigo', 'island', 'ivory', 'jacket', 'jaguar', 'jasmine', 'jelly', 'journal', 'jungle', 'junior', 'kayak', 'kernel',
		'kettle', 'kitchen', 'kitten', 'koala', 'ladder', 'lagoon', 'lantern', 'laptop', 'laser', 'lawyer', 'leader', 'legend', 'lemon', 'leopard', 'letter', 'lettuce',
		'lily', 'lizard', 'lobster', 'locker', 'lotus', 'lumber', 'lunar', 'magnet', 'mammal', 'mango', 'manor', 'maple', 'marble', 'margin', 'marine', 'market',
		'mason', 'meadow', 'medal', 'melody', 'mentor', 'mermaid', 'meteor', 'mirror', 'mixer', 'model', 'monarch', 'monsoon', 'moose', 'morning', 'mosaic', 'motor',
		'muffin', 'mural', 'museum', 'music', 'mustang', 'mustard', 'napkin', 'nectar', 'needle', 'neon', 'nephew', 'nickel', 'noodle', 'nugget', 'nurse', 'nutmeg',
		'oasis', 'ocean', 'octopus', 'office', 'olive', 'onion', 'orange', 'orbit', 'orchid', 'organ', 'otter', 'outlaw', 'oxygen', 'oyster', 'pajama', 'palace',
		'pancake', 'panda', 'panther', 'papaya', 'parade', 'parcel', 'parlor', 'parrot', 'pasta', 'pastry', 'patio', 'peanut', 'pebble', 'pelican', 'pencil', 'penguin',
		'pepper', 'petal', 'phantom', 'pianist', 'picnic', 'pigeon', 'pillow', 'pilot', 'pirate', 'pistol', 'planet', 'plaza', 'pocket', 'poet', 'polar', 'pony'
	];

	return { WORDS };
});
