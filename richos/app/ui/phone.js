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
      <!-- SCREEN 6's LIMIT, on the one screen where they live with it. Said on Screen 1 where they
           commit, and here — and on none of the four screens in between, because a limitation
           repeated on every screen is nagging. -->
      <p class="overlay-note" id="phone-ts-limit" hidden>You can use this away from the office. Both
        devices have to be signed in to Tailscale for it to connect — including at home.</p>
      <!-- THE FORGET NOTE IS CONDITIONAL, and that is the point. On the Tailscale route there is no
           profile, and telling someone to go and remove one that does not exist is the kind of
           leftover that makes a product feel untended. -->
      <p class="overlay-note" id="phone-forget-note-home">Forgetting it here stops this Mac answering
        it, and deletes the keys. It does <strong>not</strong> remove the certificate from your
        phone. To remove that too, on your phone open Settings, then General, then VPN and Device
        Management, then the RichOS profile, then Remove Profile.</p>
      <p class="overlay-note" id="phone-forget-note-ts" hidden>Forgetting it here stops this Mac
        answering it, deletes the keys, and stops this Mac answering at its Tailscale name. There is
        nothing to remove from your phone.</p>
      <div class="desk-card-actions">
        <button id="phone-forget" class="desk-btn" type="button">Forget this phone</button>
      </div>
    </div>

    <div id="phone-pairing" hidden>
      <!-- SCREEN 5 — YOUR PHONE, THREE THINGS. Shown on the Tailscale route INSTEAD of the two
           warnings, the trust code and the sixteen steps below, which are the home path's and are
           absent here rather than hidden. The no-certificate note is a tripwire, not a boast: a
           user on this path who is asked to install a profile is on the wrong origin, and the only
           person who can notice that is the user. -->
      <!-- THESE FOUR STEPS ARE THE CEO'S OWN, AND THEY OVERRIDE URBAN'S THREE.
           He installed and uninstalled Tailscale on Android THREE TIMES looking for a "connect to
           Mac" step that does not exist. Urban's Screen 5 had three steps and stopped at "sign in",
           which is where that hunt begins: the app is signed in, nothing says it is finished, and
           the user goes looking for the pairing screen Tailscale does not have. So the two missing
           steps — the VPN permission prompt, and the switch reading Connected — are what end the
           hunt, and the sentence below says outright that the thing he was hunting for is not
           there. Recorded in docs/verification/tailscale-path-2026-09-18.md.

           NOTHING ABOUT TAILNETS, MagicDNS OR MACHINE NAMES ON THIS SCREEN, by the same ruling.
           Those words belong on the Mac's own screens; here they are vocabulary for a thing the
           user does not have to think about. -->
      <div id="phone-ts-steps" hidden>
        <h3 class="phone-step-title">On your phone, four things</h3>
        <!-- THE WHY COMES BEFORE THE STEPS, and it is here because the CEO said it is not obvious:
             *"in hindsight this sounds obvious, but it's absolutely NOT obvious at all. Especially
             given that I would normally absolutely NEVER use the same identity on the Mac and on
             the phone."* A person whose habit is to keep two identities apart will follow a step
             that says "sign in" and use the WRONG one, correctly by their own lights, and the
             result is two networks that never see each other with nothing on either screen saying
             why. So the reason is given before the instruction, and it names the habit it is
             asking them to break. -->
        <p class="overlay-note">Your Tailscale account <strong>is</strong> your private network.
          Devices signed in to it can reach each other. So sign in on your phone with the same
          account you used on your Mac, even if you normally keep them separate. Nothing else
          connects them.</p>
        <ol class="phone-steps">
          <li class="overlay-note">Install Tailscale from the store.</li>
          <li class="overlay-note">Sign in with the <strong>same</strong> identity you used on this
            Mac — Google, Microsoft, GitHub, whichever it was. A different provider makes a
            different network, and then the two will never see each other.</li>
          <li class="overlay-note">Allow the VPN connection your phone asks about.</li>
          <li class="overlay-note">The switch says Connected.</li>
        </ol>
        <p class="overlay-note phone-url" id="phone-ts-store"></p>
        <p class="overlay-note"><strong>There is no pairing step in Tailscale.</strong> Sign in with
          the same account on both devices and they are connected.</p>
        <p class="overlay-note">There is no certificate to install on this path. If your phone asks
          you to install a profile, something is wrong — tell me.</p>
      </div>
      <div id="phone-home-warnings">
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
      </div>

      <h3 class="phone-step-title" id="phone-code-title">2. Then point it at this, to open Rich</h3>
      <div class="phone-qr-row">
        <canvas id="phone-qr-pair" class="phone-qr" width="1" height="1" role="img"></canvas>
        <div>
          <p class="overlay-note phone-url" id="phone-pair-url"></p>
          <p class="overlay-note" id="phone-countdown" role="status"></p>
        </div>
      </div>

      <h3 class="phone-step-title" id="phone-words-title">3. Check the six words match</h3>
      <p class="overlay-note">Your phone will show six words. They have to be these six, in this
        order. If they are not, something other than this Mac answered — tap Cancel and tell me.</p>
      <p class="phone-words" id="phone-words"></p>

      <!-- THE ONE FAILURE THIS PATH ACTUALLY DIES OF, named where it happens. Sage's §2.3 failure
           mode is that the name simply stops resolving; from the phone that looks like "cannot
           connect" with nothing saying why, and two different Tailscale accounts produce exactly
           that, silently. -->
      <p class="overlay-note" id="phone-ts-failure" hidden>If the code opens to a page that cannot
        connect, your phone is signed in to a different Tailscale account than this Mac.</p>

      <p class="overlay-note" id="phone-bound"></p>
      <p class="overlay-note" id="phone-message" role="status"></p>
      <div class="desk-card-actions">
        <button id="phone-refresh" class="desk-btn desk-btn--confirm" type="button">Show me another code</button>
      </div>
    </div>

    <!-- SCREEN 1 — WHERE WILL YOU USE IT? Urban's §2, in front of the shipped one-route block.
         The order is fixed and is never reordered by what detection happens to find: §61 says a
         phone app inside the home network is the weaker tool, so "Anywhere" is first, always. A
         screen whose options move is a screen that cannot be learned. -->
    <div id="phone-route" hidden>
      <p class="overlay-note">This is an extra. Rich on this Mac does not need it.</p>
      <h3 class="phone-step-title">Where do you want to use it?</h3>
      <div class="desk-card-actions">
        <button id="phone-route-anywhere" class="desk-btn" type="button">Anywhere, including away from the office</button>
      </div>
      <p class="overlay-note">On the go, on cellular, anywhere your phone has a signal. It costs you
        two app installs, one free Tailscale account, and no certificate at all.</p>
      <p class="overlay-note">Rich on your phone stops connecting whenever Tailscale is off or
        signed out on either device — at home too.</p>
      <div class="desk-card-actions">
        <button id="phone-route-home" class="desk-btn" type="button">At home only</button>
      </div>
      <p class="overlay-note">Your phone talks to this Mac over your own home network, with no
        account and no third party. Away from the house it will not connect, and setting it up means
        installing a certificate on your phone: sixteen taps, once.</p>
    </div>

    <!-- SCREENS 2, 3 and 7 — the three "something is happening elsewhere" states. One block,
         because they differ only in their words and their one address: each is a thing the user
         does in somebody else's software, and detection is what moves the screen on. -->
    <div id="phone-ts-wait" hidden>
      <h3 class="phone-step-title" id="phone-ts-heading"></h3>
      <p class="overlay-note" id="phone-ts-note1"></p>
      <p class="overlay-note" id="phone-ts-note2"></p>
      <p class="overlay-note phone-url" id="phone-ts-url"></p>
      <div class="desk-card-actions">
        <button id="phone-ts-recheck" class="desk-btn desk-btn--confirm" type="button">Check again</button>
        <button id="phone-ts-back" class="desk-btn" type="button">Pick a different way</button>
      </div>
    </div>

    <!-- SCREEN 4 — THIS MAC IS READY. No separate "turn serving on": once the name is known there
         is no decision left, so "Set my phone up" does both, under the label the product already
         uses. -->
    <div id="phone-ts-ready" hidden>
      <h3 class="phone-step-title">This Mac is ready</h3>
      <p class="overlay-note phone-url" id="phone-ts-name"></p>
      <p class="overlay-note">That is this Mac's name on your own Tailscale network. Only devices
        signed in to your Tailscale account can reach it, and no port on this Mac is open to the
        internet.</p>
      <div class="desk-card-actions">
        <button id="phone-ts-start" class="desk-btn desk-btn--confirm" type="button">Set my phone up</button>
        <button id="phone-ts-ready-back" class="desk-btn" type="button">Pick a different way</button>
      </div>
    </div>

    <div id="phone-off" hidden>
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
  let poller = null;

  /// **WHICH ROUTE HE PICKED, AND IT IS NEVER REMEMBERED.** Urban's §1 consequence 2: open the
  /// sheet unpaired and it asks again. A remembered choice with no visible way to change it is a
  /// trap, and re-asking costs one screen that is already there. `null` means Screen 1.
  let route = null;

  /// Every external address these screens name, each one verified against Tailscale's own install
  /// documentation rather than recalled — see `docs/verification/tailscale-path-2026-09-18.md` §4a.
  ///
  /// **They are written out rather than linked, and that is deliberate twice over.** The app has no
  /// way to open a URL at all — there is no opener plugin and no command for it — so a clickable
  /// control here would be a button that does nothing. And the printed form is Urban's own
  /// requirement anyway: *"a control that opens somewhere the user cannot see first is a control
  /// that asks for trust it has not earned."* On 2026-09-19 the CEO could not find the download
  /// from `tailscale.com`'s home page nor from the admin console, so every one of these goes
  /// straight to the thing to do rather than to a page he has to navigate.
  ///
  /// **The two Apple IDs are different and must not be swapped**: `1470499037` is the iPhone and
  /// iPad app, `1475387142` is the Mac app. Sending him to the wrong one sends him to a listing his
  /// device cannot install from.
  const LINKS = {
    mac: "tailscale.com/download/mac",
    phone: "apps.apple.com/app/tailscale/id1470499037",
    android: "play.google.com/store/apps/details?id=com.tailscale.ipn",
    console: "console.tailscale.com/admin/dns",
  };

  /// Screens 2, 3 and 7 — the three states whose next step happens in somebody else's software.
  /// The Mac cannot advance the user and the user cannot advance the Mac, so there is no Next and
  /// no Back: detection moves the screen, and `Check again` is the button for the impatient and
  /// for the failure.
  const WAITING = {
    absent: {
      heading: "Install Tailscale on this Mac",
      note1:
        "Tailscale is somebody else's app, and it is free for one person. It gives this Mac a name your phone can reach from anywhere, and it is the whole reason this path has no certificate in it.",
      note2: "Download it, install it, then come back here. This screen moves on by itself when it sees it.",
      url: LINKS.mac,
    },
    "needs-sign-in": {
      heading: "Sign in to Tailscale on this Mac",
      note1:
        "Tailscale is installed here but not signed in. Open it and sign in. Any of the sign-in choices it offers is fine, and the free plan is enough. I cannot do this part for you.",
      // THE SHORTENED WHY, ON THE SCREEN WHERE THE IDENTITY IS ACTUALLY CHOSEN. Same CEO ruling as
      // the phone screen's opening paragraph: he would "normally absolutely NEVER use the same
      // identity on the Mac and on the phone", so the choice has to be made KNOWING it will be
      // reused. Telling him afterwards, on the phone screen, is telling him after he has already
      // picked — and by then the fix is signing out of an account he just created.
      note2:
        "Whichever you pick, you will sign in to the SAME one on your phone — your Tailscale account is your private network, and devices signed in to it are what can reach each other. Nothing else connects them.",
      url: "",
    },
    "certificates-off": {
      heading: "Tailscale is signed in, but this Mac has no name yet",
      note1:
        "Tailscale gives each machine a name on your network, and this Mac does not have one I can use. In Tailscale's own admin console, turn on MagicDNS and HTTPS certificates for your network, then come back.",
      note2: "",
      url: LINKS.console,
    },
  };
  // The states that are not a step of their own borrow the nearest screen that tells the truth.
  // Each of these is "Tailscale is on this Mac and is not usable yet", and the sign-in screen is
  // the one that says so without claiming to know more than detection does.
  WAITING["not-running"] = WAITING["needs-sign-in"];
  WAITING["needs-approval"] = WAITING["needs-sign-in"];
  WAITING["stopped"] = WAITING["needs-sign-in"];
  WAITING["other-user"] = WAITING["needs-sign-in"];

  function render(status) {
    const pairing = !!status.pairUrl;
    const tailnet = status.tailnet || { state: "absent" };
    const onTailscale = route === "anywhere";

    // Rows 1 and 9 of Urban's §3: unpaired with no route chosen is Screen 1.
    //
    // **`!status.listening` is mine, and it is not in Urban's table.** His row 1 says "any, not
    // paired" and does not distinguish a Mac that is already serving. A listening, unpaired Mac is
    // someone MID-FLOW on the home path — commonest case, a code that expired while they were
    // looking at their phone — and sending them back to the route question there loses their place
    // and strands the pairing window. Screen 1 is the entry point, not an interruption. Found by
    // `ui/tests/phone.js` check 8, which is exactly that case.
    const choosing = !status.paired && !pairing && !status.listening && route === null;
    // Rows 2, 3 and 5: a route is chosen, nothing is serving yet, and the Mac is not ready.
    const waiting = onTailscale && !status.paired && !pairing && tailnet.state !== "ready";
    // Row 4: ready, and the only thing left is the code.
    const ready = onTailscale && !status.paired && !pairing && tailnet.state === "ready";

    field("phone-route").hidden = !choosing;
    field("phone-ts-wait").hidden = !waiting;
    field("phone-ts-ready").hidden = !ready;
    field("phone-paired").hidden = !status.paired;
    field("phone-pairing").hidden = status.paired || !pairing;
    field("phone-off").hidden = status.paired || pairing || choosing || waiting || ready;

    // Rows 2, 3 and 5 poll; nothing else does. The screen redraws itself as he installs and signs
    // in, with no action of his — which is the whole reason there is no Next button.
    setPolling(waiting);

    if (status.paired) {
      field("phone-device-name").textContent = status.deviceName || "Your phone";
      field("phone-push-state").textContent = status.pushReady
        ? "It can reach you with a notification when Rich has something for you."
        : "It cannot send you notifications yet. Add Rich to your phone's Home Screen and allow notifications when it asks.";
      // Screen 6 against the shipped paired block: the limit appears, and the forget note is the
      // one that is true of the route he is actually on.
      field("phone-ts-limit").hidden = !onTailscale;
      field("phone-forget-note-ts").hidden = !onTailscale;
      field("phone-forget-note-home").hidden = onTailscale;
      return;
    }
    if (waiting) {
      // The Mac's own sentence for this state is the floor; the screen says more, never less and
      // never something different.
      const screen = WAITING[tailnet.state] || WAITING.absent;
      field("phone-ts-heading").textContent = screen.heading;
      field("phone-ts-note1").textContent = screen.note1 || tailnet.sentence || "";
      field("phone-ts-note2").textContent = screen.note2 || "";
      field("phone-ts-note2").hidden = !screen.note2;
      field("phone-ts-url").textContent = screen.url;
      field("phone-ts-url").hidden = !screen.url;
      return;
    }

    if (ready) {
      field("phone-ts-name").textContent = tailnet.name || "";
      return;
    }

    if (!pairing) {
      field("phone-off-message").textContent = status.listening
        ? "Nearly there. Ask for a code and point your phone's camera at it."
        : "I will make a certificate for your phone, then show you two codes to scan. It takes a few minutes, once, ever.";
      return;
    }

    // SCREEN 5 versus the shipped home flow. The trust code, the two warnings and the sixteen
    // steps belong to the home path and are absent here rather than hidden behind a smaller font.
    field("phone-ts-steps").hidden = !onTailscale;
    field("phone-home-warnings").hidden = onTailscale;
    field("phone-ts-failure").hidden = !onTailscale;
    field("phone-ts-store").textContent = onTailscale
      ? "iPhone: " + LINKS.phone + "      Android: " + LINKS.android
      : "";
    field("phone-code-title").textContent = onTailscale
      ? "Then point your phone's camera at this"
      : "2. Then point it at this, to open Rich";
    field("phone-words-title").textContent = onTailscale
      ? "Check the six words match"
      : "3. Check the six words match";

    paint(field("phone-qr-trust"), onTailscale ? "" : status.trustUrl);
    paint(field("phone-qr-pair"), status.pairUrl);
    field("phone-trust-url").textContent = onTailscale ? "" : status.trustUrl || "";
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

  /// **The screens that wait, redraw themselves; nothing else polls.**
  ///
  /// Urban's §3: rows 2, 3 and 5 advance with no user action, because every step in them is
  /// completed in somebody else's software. The interval matches the Mac's own recheck ceiling
  /// (`TAILNET_RECHECK_MS`, two seconds in `phone/mod.rs`), so a poll is never served a cached
  /// answer it has already seen and the two cannot drift into a slower effective rate.
  ///
  /// **It stops the moment the screen stops waiting, and on close.** A settings sheet that keeps
  /// spawning a subprocess after it is hidden is exactly the untended-garbage shape the standing
  /// cleanup rule is about.
  function setPolling(on) {
    if (on && !poller) {
      poller = window.setInterval(refresh, 2000);
    } else if (!on && poller) {
      window.clearInterval(poller);
      poller = null;
    }
  }

  function close() {
    if (busy) return;
    stopTicking();
    setPolling(false);
    sheet.hidden = true;
    if (returnFocus && returnFocus.focus) returnFocus.focus();
  }

  async function open() {
    returnFocus = document.activeElement;
    field("phone-message").textContent = "";
    // THE ROUTE IS FORGOTTEN ON EVERY OPEN. Urban's §1: a remembered choice with no visible way to
    // change it is a trap, and re-asking costs one screen that is already there.
    route = null;
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

  // THE ROUTE CONTROLS. "At home only" is the shipped flow with nothing changed — it does not even
  // start pairing, because the shipped `#phone-off` block already has that button and its own
  // explanation of what is about to happen.
  field("phone-route-anywhere").addEventListener("click", async () => {
    route = "anywhere";
    await refresh();
  });
  field("phone-route-home").addEventListener("click", async () => {
    route = "at-home";
    await refresh();
  });
  // "Pick a different way" — the only user-driven move backward, and it never tears down a live
  // pairing window, because it is not offered on the screen that has one.
  for (const id of ["phone-ts-back", "phone-ts-ready-back"]) {
    field(id).addEventListener("click", async () => {
      route = null;
      await refresh();
    });
  }
  // `Check again` — the button for the impatient and for the failure. The poll is invisible, and a
  // detection path with no manual retry is a dead end the moment detection is wrong once.
  field("phone-ts-recheck").addEventListener("click", refresh);
  field("phone-ts-start").addEventListener("click", begin);
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
