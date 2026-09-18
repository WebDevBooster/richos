#!/usr/bin/env node
'use strict';

// Generate one VAPID key pair and print it as shell exports.
//
// The private key is a credential. It is printed to stdout and written nowhere, because this
// repository is published and `richos/engine`'s own doctrine (CEO decision §20) is that no shipped
// artifact contains one. Put it in the Railway service's variables and nowhere else.

const { generateVapidKeys } = require('../lib/webpush.js');

const keys = generateVapidKeys();

process.stdout.write(`# RichOS phone probe — VAPID key pair, generated ${new Date().toISOString()}
#
# The PUBLIC key is safe anywhere: the page fetches it from /api/config at runtime, which is why
# no key is committed in this repository at all.
#
# The PRIVATE key is a credential. Set it as a Railway service variable. Do not commit it, do not
# paste it into a document, and do not put it in a commit message.

export VAPID_PUBLIC_KEY='${keys.publicKey}'
export VAPID_PRIVATE_KEY='${keys.privateKey}'
export VAPID_SUBJECT='mailto:probe@richos.invalid'
`);
