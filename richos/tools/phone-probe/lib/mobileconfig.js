'use strict';

// The `.mobileconfig` that carries the root certificate onto the iPhone.
//
// A bare `.crt` served as `application/x-x509-ca-cert` also works — iOS 12.2 and later treat it as a
// profile download — but it arrives with no name, no description and no author, so what he is being
// asked to install is a mystery. A configuration profile is the same certificate with a sentence
// explaining itself, which is the difference between a security decision and a leap of faith. Both
// are offered; this is the one the page leads with.
//
// UNSIGNED, and it says so in the description. iOS marks an unsigned profile "Not Signed" in red.
// Signing it would need a certificate from a CA Apple already trusts — which is the exact thing this
// whole file exists because we do not have. Pretending otherwise, or hiding the red text, would be
// worse than naming it.
//
// The UUIDs are DERIVED from the certificate, not random: installing the same CA twice replaces the
// profile in place instead of stacking up a second copy he then has to tell apart.

const crypto = require('node:crypto');

// A UUID-shaped identifier derived from bytes. Version nibble 5 and the RFC 4122 variant bits, so it
// is a well-formed name-based UUID rather than something that merely looks like one.
function derivedUuid(namespace, bytes) {
	const digest = crypto.createHash('sha1').update(namespace).update(bytes).digest();
	const b = Buffer.from(digest.subarray(0, 16));
	b[6] = (b[6] & 0x0f) | 0x50;
	b[8] = (b[8] & 0x3f) | 0x80;
	const hex = b.toString('hex');
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`.toUpperCase();
}

function escapeXml(text) {
	return String(text)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;');
}

// Apple's plist `<data>` is base64, conventionally wrapped. The wrapping is cosmetic; the line
// length is not, because a single 1.2 KB line in a file a person may open in a text editor is a file
// nobody reads.
function dataBlock(buffer, indent) {
	const base64 = buffer.toString('base64').replace(/(.{60})/g, '$1\n').trimEnd();
	return base64.split('\n').map((line) => indent + line).join('\n');
}

/**
 * @param {{ certDer: Buffer, commonName: string, hostNames: string[], fileName?: string }} options
 * @returns {string} a complete .mobileconfig
 */
function caProfile(options) {
	const { certDer, commonName } = options;
	const fileName = options.fileName || 'richos-local-ca.crt';
	const hostNames = options.hostNames || [];
	const fingerprint = crypto.createHash('sha256').update(certDer).digest('hex').replace(/(..)/g, '$1:').slice(0, -1).toUpperCase();

	const rootUuid = derivedUuid('richos.phone-probe.profile', certDer);
	const certUuid = derivedUuid('richos.phone-probe.certificate', certDer);

	// Written as plain text rather than assembled with a plist library for the same reason the rest
	// of this tool has no dependencies, and because a profile is a file a person may want to read
	// before installing it.
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>com.richos.phone-probe.ca</string>
			<key>PayloadUUID</key>
			<string>${certUuid}</string>
			<key>PayloadDisplayName</key>
			<string>${escapeXml(commonName)}</string>
			<key>PayloadDescription</key>
			<string>The certificate that lets this iPhone open the RichOS probe page on your own Mac over HTTPS. It is valid only for ${escapeXml(hostNames.join(', ') || 'this Mac')} and for nothing on the internet.</string>
			<key>PayloadCertificateFileName</key>
			<string>${escapeXml(fileName)}</string>
			<key>PayloadContent</key>
			<data>
${dataBlock(certDer, '\t\t\t')}
			</data>
		</dict>
	</array>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadIdentifier</key>
	<string>com.richos.phone-probe</string>
	<key>PayloadUUID</key>
	<string>${rootUuid}</string>
	<key>PayloadOrganization</key>
	<string>RichOS</string>
	<key>PayloadDisplayName</key>
	<string>RichOS local certificate</string>
	<key>PayloadDescription</key>
	<string>Not signed, which is why iOS shows this in red: signing it would need a certificate from a company Apple already trusts, and the point of this one is that no such company is involved. It was generated on your own Mac a moment ago and it never left your home network. SHA-256: ${fingerprint}. After installing, you must also switch it on under Settings, General, About, Certificate Trust Settings. Delete the profile to undo all of it.</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
</dict>
</plist>
`;
}

module.exports = { caProfile, derivedUuid };
