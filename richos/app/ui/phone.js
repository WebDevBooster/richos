"use strict";
// USE RICH FROM YOUR PHONE — the Mac's half of pairing (plan §4.1).
//
// Two QR codes, the six words, and the two things he must be told BEFORE he starts rather than
// discover inside it. That last part is the whole reason this screen has so much prose on it, and
// the plan is explicit about both:
//
//   * *"The profile will say 'Unverified' in red. That is not a defect and it is not fixable …
//     The Mac's own screen must say, in his words, that the red word means 'nobody vouched for
//     this file except your own Mac — which is the entire point.'"*
//   * *"The trust toggle can be missing, and it is Apple's bug rather than ours … If his phone
//     shows any version of that, the home-network design is blocked."*
//
// A person who meets a red warning he was not warned about stops. A person who was told about it
// ten seconds earlier carries on. That difference is the only thing standing between this feature
// and a CEO who abandons it at step 9.
//
// WHY THE SIXTEEN STEPS ARE WRITTEN OUT. Because they are sixteen. The plan counted them for
// exactly this reason — *"'a one-time setup step' is how a plan hides a bad afternoon"* — and a
// screen that says "follow the prompts" over sixteen taps is a screen that lies about the cost.
//
// NO NEW COLORS. Every piece of text here uses a class the shipped shell already paints and the
// contrast suite already walks. The only new visual is the QR canvas, which paints its own white
// quiet zone and black modules — 21:1, and the quiet zone is part of the code rather than
// decoration: a code drawn flush to a dark page background does not scan.
(function () {
  const bridge = window.RichBridge;
  const qr = window.RichOSQr;

  const sheet = document.createElement("div");
  sheet.id = "phone-sheet";
  sheet.className = "overlay";
  sheet.hidden = true;
  sheet.setAttribute("role", "dialog");
  sheet.setAttribute("aria-modal", "true");
  sheet.setAttribute("aria-labelledby", "phone-title");
  sheet.setAttribute("data-dismiss", "control:#phone-close");
  sheet.innerHTML = `<div class="overlay-panel">
    <h2 id="phone-title" class="overlay-title">Use Rich from your phone</h2>
    <p class="overlay-note">Your phone talks to this Mac directly, over your own home network. Nothing
      of what you say goes anywhere else, and there is no account to make.</p>

    <div id="phone-paired" hidden>
      <p class="overlay-note"><strong id="phone-device-name"></strong> is paired. Open Rich on it and
        keep talking.</p>
      <p class="overlay-note" id="phone-push-state"></p>
      <p class="overlay-note">Forgetting it here stops this Mac answering it, and deletes the keys.
        It does <strong>not</strong> remove the certificate from your phone. To remove that too, on
        your phone open Settings, then General, then VPN and Device Management, then the RichOS
        profile, then Remove Profile.</p>
      <div class="desk-card-actions">
        <button id="phone-forget" class="desk-btn" type="button">Forget this phone</button>
      </div>
    </div>

    <div id="phone-pairing" hidden>
      <p class="overlay-note phone-warn"><strong>Two things before you start.</strong></p>
      <p class="overlay-note">Your phone will call this certificate <strong>Unverified</strong>, in
        red. That is not a fault and it is not something I can fix. It means nobody vouched for the
        file except your own Mac — which is the entire point. Making that warning go away would
        need a certificate from a company Apple already trusts, and Rich is free and open, so there
        is no such company involved.</p>
      <p class="overlay-note">Some iPhones running iOS 18.0 and 18.1 never show the switch you need
        at step 15. That is Apple's own fault rather than mine, and it is fixed in later versions.
        If you get there and the switch is simply not on the screen, stop and tell me — your phone
        cannot use this until it is.</p>

      <h3 class="phone-step-title">1. Point your camera at this, to install the certificate</h3>
      <div class="phone-qr-row">
        <canvas id="phone-qr-trust" class="phone-qr" width="1" height="1" role="img"></canvas>
        <p class="overlay-note phone-url" id="phone-trust-url"></p>
      </div>
      <ol id="phone-steps" class="phone-steps"></ol>

      <h3 class="phone-step-title">2. Then point it at this, to open Rich</h3>
      <div class="phone-qr-row">
        <canvas id="phone-qr-pair" class="phone-qr" width="1" height="1" role="img"></canvas>
        <div>
          <p class="overlay-note phone-url" id="phone-pair-url"></p>
          <p class="overlay-note" id="phone-countdown" role="status"></p>
        </div>
      </div>

      <h3 class="phone-step-title">3. Check the six words match</h3>
      <p class="overlay-note">Your phone will show six words. They have to be these six, in this
        order. If they are not, something other than this Mac answered — tap Cancel and tell me.</p>
      <p class="phone-words" id="phone-words"></p>

      <p class="overlay-note" id="phone-bound"></p>
      <p class="overlay-note" id="phone-message" role="status"></p>
      <div class="desk-card-actions">
        <button id="phone-refresh" class="desk-btn desk-btn--confirm" type="button">Show me another code</button>
      </div>
    </div>

    <div id="phone-off">
      <p class="overlay-note" id="phone-off-message"></p>
      <div class="desk-card-actions">
        <button id="phone-start" class="desk-btn desk-btn--confirm" type="button">Set my phone up</button>
      </div>
    </div>

    <!-- ONE CLOSE, OUTSIDE THE THREE STATES AND ALWAYS VISIBLE.
         The first version of this sheet had three, one inside each state block, and
         ui/tests/escape.js refused it on the spot: data-dismiss names ONE control, the
         document-level Escape handler clicks it, and a button hidden with its block does
         nothing at all. Two of the three states could not be dismissed from the keyboard. One
         button that is always on screen is both the simpler markup and the only shape that can
         satisfy the contract. -->
    <div class="desk-card-actions">
      <button id="phone-close" class="desk-btn" type="button">Close</button>
    </div>
  </div>`;
  document.body.appendChild(sheet);

  const field = (id) => sheet.querySelector("#" + id);

  // Apple's own screen names, in Apple's own order, because he is reading them off this screen and
  // looking for them on that one. Step 9 and step 15 are the two the prose above prepares him for.
  const STEPS = [
    "Tap Allow when your phone asks about a configuration profile.",
    "Tap Close.",
    "Open Settings on your phone.",
    "Tap General.",
    "Tap VPN & Device Management.",
    "Tap the RichOS profile.",
    "Tap Install, top right.",
    "Enter your passcode.",
    "Tap Install again — this is the screen with the red Unverified on it.",
    "Tap Install in the sheet that slides up.",
    "Tap Done.",
    "Go back to Settings.",
    "Tap General.",
    "Tap About.",
    "Tap Certificate Trust Settings — this is the switch some iOS 18.0 and 18.1 phones are missing.",
    "Turn on the switch beside RichOS, and tap Continue.",
  ];

  (function fillSteps() {
    const list = field("phone-steps");
    for (const step of STEPS) {
      const item = document.createElement("li");
      item.className = "overlay-note";
      item.textContent = step;
      list.appendChild(item);
    }
  })();

  /// Draw a QR matrix into a canvas: black modules, white background, and the four-module quiet
  /// zone the standard requires. The white is painted rather than inherited on purpose — the quiet
  /// zone is part of the symbol, and a code flush to a dark page does not scan.
  function paint(canvas, text) {
    if (!text) {
      canvas.hidden = true;
      return;
    }
    let matrix;
    try {
      matrix = qr.encode(text);
    } catch (error) {
      // A URL too long for a version-6 symbol. Saying so beats drawing a code that does not scan.
      canvas.hidden = true;
      field("phone-message").textContent = String(error && error.message ? error.message : error);
      return;
    }
    const quiet = 4;
    const scale = 5;
    const side = (matrix.size + quiet * 2) * scale;
    canvas.hidden = false;
    canvas.width = side;
    canvas.height = side;
    canvas.setAttribute("aria-label", "A code for your phone's camera. The address is written out beside it.");
    const paper = canvas.getContext("2d");
    paper.fillStyle = "#ffffff";
    paper.fillRect(0, 0, side, side);
    paper.fillStyle = "#000000";
    for (let row = 0; row < matrix.size; row++) {
      for (let column = 0; column < matrix.size; column++) {
        if (!matrix.modules[row][column]) continue;
        paper.fillRect((column + quiet) * scale, (row + quiet) * scale, scale, scale);
      }
    }
  }

  let ticker = null;
  let busy = false;
  let returnFocus = null;

  function render(status) {
    const pairing = !!status.pairUrl;
    field("phone-paired").hidden = !status.paired;
    field("phone-pairing").hidden = status.paired || !pairing;
    field("phone-off").hidden = status.paired || pairing;

    if (status.paired) {
      field("phone-device-name").textContent = status.deviceName || "Your phone";
      field("phone-push-state").textContent = status.pushReady
        ? "It can reach you with a notification when Rich has something for you."
        : "It cannot send you notifications yet. Add Rich to your phone's Home Screen and allow notifications when it asks.";
      return;
    }
    if (!pairing) {
      field("phone-off-message").textContent = status.listening
        ? "Nearly there. Ask for a code and point your phone's camera at it."
        : "I will make a certificate for your phone, then show you two codes to scan. It takes a few minutes, once, ever.";
      return;
    }

    paint(field("phone-qr-trust"), status.trustUrl);
    paint(field("phone-qr-pair"), status.pairUrl);
    field("phone-trust-url").textContent = status.trustUrl || "";
    field("phone-pair-url").textContent = status.pairUrl || "";
    field("phone-words").textContent = (status.fingerprintWords || []).join("  ");
    field("phone-bound").textContent = status.bound && status.bound.length
      ? "This Mac is answering on " + status.bound.join(", ") + "."
      : "";
    tick(status.pairingSecondsLeft);
  }

  /// The countdown, which is the one thing on this screen that has to be honest by the second: a
  /// code that has expired and still looks live is a code he scans and then has to be told about.
  function tick(secondsLeft) {
    if (ticker) {
      window.clearInterval(ticker);
      ticker = null;
    }
    let left = Number.isFinite(secondsLeft) ? secondsLeft : 0;
    const paintCountdown = () => {
      const label = field("phone-countdown");
      if (left > 0) {
        label.textContent =
          "This code lasts " + left + (left === 1 ? " more second." : " more seconds.");
      } else {
        label.textContent = "That code has expired. Ask for another one.";
        if (ticker) {
          window.clearInterval(ticker);
          ticker = null;
        }
      }
    };
    paintCountdown();
    if (left > 0) {
      ticker = window.setInterval(() => {
        left -= 1;
        paintCountdown();
      }, 1000);
    }
  }

  async function refresh() {
    try {
      render(await bridge.invoke("phone_status"));
    } catch (error) {
      field("phone-message").textContent = String(error);
    }
  }

  function stopTicking() {
    if (ticker) {
      window.clearInterval(ticker);
      ticker = null;
    }
  }

  function close() {
    if (busy) return;
    stopTicking();
    sheet.hidden = true;
    if (returnFocus && returnFocus.focus) returnFocus.focus();
  }

  async function open() {
    returnFocus = document.activeElement;
    field("phone-message").textContent = "";
    sheet.hidden = false;
    await refresh();
    const first = sheet.querySelector("button:not([disabled])");
    if (first) first.focus();
  }

  async function begin() {
    if (busy) return;
    busy = true;
    field("phone-message").textContent = "Making a certificate for your phone…";
    field("phone-start").disabled = true;
    field("phone-refresh").disabled = true;
    try {
      render(await bridge.invoke("phone_begin_pairing"));
      field("phone-message").textContent = "";
    } catch (error) {
      field("phone-message").textContent = String(error);
    } finally {
      busy = false;
      field("phone-start").disabled = false;
      field("phone-refresh").disabled = false;
    }
  }

  field("phone-start").addEventListener("click", begin);
  field("phone-refresh").addEventListener("click", begin);
  field("phone-close").addEventListener("click", close);
  field("phone-forget").addEventListener("click", async () => {
    if (busy) return;
    busy = true;
    field("phone-message").textContent = "";
    try {
      await bridge.invoke("phone_forget");
      await refresh();
    } catch (error) {
      field("phone-message").textContent = String(error);
    } finally {
      busy = false;
    }
  });

  sheet.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.stopPropagation();
      close();
    }
    if (event.key === "Tab") {
      const targets = [...sheet.querySelectorAll("button")].filter(
        (node) => !node.disabled && node.offsetParent !== null
      );
      if (!targets.length) return;
      if (event.shiftKey && document.activeElement === targets[0]) {
        event.preventDefault();
        targets.at(-1).focus();
      } else if (!event.shiftKey && document.activeElement === targets.at(-1)) {
        event.preventDefault();
        targets[0].focus();
      }
    }
  });

  window.RichSettings.registerPhone({ open });
})();
