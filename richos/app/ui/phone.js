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
    <!-- THE LEAD FOLLOWS THE OPTION HE PICKED, and it used to be a fixed sentence describing
         the home-network option. It stayed on screen unchanged after he chose "Anywhere",
         which is not the home network and DOES involve making an account — so every screen of
         the Tailscale path opened by telling him the opposite of the path he was on. Ray's
         candidate .11 defect 3.1, screenshots 13, 14, 15 and 17. Filled from LEAD below. -->
    <p class="overlay-note" id="phone-lead"></p>

    <div id="phone-paired" hidden>
      <p class="overlay-note"><strong id="phone-device-name"></strong> is paired. Open Rich on it and
        keep talking.</p>
      <p class="overlay-note" id="phone-push-state"></p>
      <!-- SCREEN 6's LIMIT, on the one screen where they live with it. Said on Screen 1 where they
           commit, and here — and on none of the four screens in between, because a limitation
           repeated on every screen is nagging. -->
      <p class="overlay-note" id="phone-ts-limit" hidden></p>
      <!-- ONE FORGET NOTE, FILLED FROM THE DEVICE RECORD. It was two paragraphs, one shown and
           one hidden, chosen by the sheet's own route variable — which is forgotten on every
           open by design, so reopening this card for a paired phone always redrew the home
           path's iOS profile-removal steps. Ray's candidate .11 defect 3.2 caught it on an
           ANDROID phone that had paired over Tailscale and installed no certificate at all.
           One node, filled from status.pairedVia and status.platform, is the only shape in
           which the two cannot disagree — see PAIRED_FORGET_NOTE below. -->
      <p class="overlay-note" id="phone-forget-note"></p>
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
        <p class="overlay-note" id="phone-ts-why"></p>
        <ol class="phone-steps">
          <li class="overlay-note">Install Tailscale from the store.</li>
          <li class="overlay-note" id="phone-ts-step2">Sign in with the <strong>same</strong>
            identity you used on this Mac. A different provider makes a different network, and then
            the two will never see each other.</li>
          <li class="overlay-note">Allow the VPN connection your phone asks about.</li>
          <li class="overlay-note">The switch says Connected.</li>
        </ol>
        <p class="overlay-note phone-url" id="phone-ts-store"></p>
        <p class="overlay-note"><strong>There is no pairing step in Tailscale.</strong> Sign in with
          the same account on both devices and they are connected.</p>
        <!-- THE MISMATCH IS DETECTED, NOT ONLY DESCRIBED — the CEO puts it at 9 in 10 users. A
             phone on the SAME account shows up in the daemon's own Peer list; one on a different
             provider's account is in a different tailnet and shows up nowhere. So this line is
             evidence rather than advice, and it names the account to use. -->
        <p class="overlay-note" id="phone-ts-peer" role="status"></p>
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
      <!-- IT GOES WITH THE CODE, AND IT NAMES A CONTROL THAT IS ON THE SCREEN. Ray's
           candidate-.12 defect B: after the code ran out this paragraph stayed, telling him to
           compare against "these six" with no six words under it and to "tap Cancel" with no
           Cancel button anywhere in the sheet (frame 19). Two things a person is asked to do
           that are not there. The heading above it and the words below it were already cleared
           with the code; this one was missed, so it is now hidden by the same live test they
           are — and the control it names is Close, which is the button this sheet actually has
           (id phone-close, and the sheet's own data-dismiss). -->
      <p class="overlay-note" id="phone-words-note">Your phone will show six words. They have to
        be these six, in this order. If they are not, something other than this Mac answered —
        press Close and tell me.</p>
      <p class="phone-words" id="phone-words"></p>

      <!-- THE ONE FAILURE THIS PATH ACTUALLY DIES OF, named where it happens. Sage's §2.3 failure
           mode is that the name simply stops resolving; from the phone that looks like "cannot
           connect" with nothing saying why, and two different Tailscale accounts produce exactly
           that, silently. -->
      <p class="overlay-note" id="phone-ts-failure" hidden>If the code opens to a page that cannot
        connect, your phone is signed in to a different Tailscale account than this Mac.</p>

      <p class="overlay-note" id="phone-bound"></p>
      <p class="overlay-note" id="phone-message" role="status"></p>
      <!-- WHAT HAPPENS WHEN THE CODE RUNS OUT, ON THE SCREEN IT RAN OUT ON. It used to happen
           in silence: the Mac dropped the window, the next poll returned no code, and the
           dialog fell back to an earlier screen with the QR, the code and the six words simply
           gone. Ray's candidate .11 defect 3.3 — "he comes back to a screen that looks like he
           imagined the whole thing". The screen stays; the code is replaced by this. -->
      <div id="phone-expired" hidden>
        <h3 class="phone-step-title">That code ran out</h3>
        <p class="overlay-note" id="phone-expired-note" role="status"></p>
      </div>
      <!-- THE WAY BACK OUT, ON THE ONE SCREEN THAT DID NOT HAVE ONE — Urban's G2.
           "Pick a different way" is on Screen 0, on Screens 2/3/7 and on Screen 4, and it was
           absent from exactly the screen a person is most likely to want it on: the one they
           reached by pressing a button. Urban, live: *"once Set my phone up is pressed, the
           route chooser is unreachable for the life of the app process"* — the expired state
           sets "pairing" as well, so waiting does not give it back either, and he could not
           re-reach the route chooser or "This Mac is ready" in dark at all after his walk.

           AND IT STOPS SERVING, which is the half that is not a button. The other four copies
           of this control move between screens with nothing running behind them; this one undoes
           a socket and a live code, so it calls phone_stop_pairing rather than only setting
           route = null. See PhoneRuntime::stop_pairing for why that is not phone_forget. -->
      <div class="desk-card-actions">
        <button id="phone-refresh" class="desk-btn desk-btn--confirm" type="button">Show me another code</button>
        <button id="phone-pairing-back" class="desk-btn" type="button">Pick a different way</button>
      </div>
    </div>

    <!-- SCREEN 1 — WHERE WILL YOU USE IT? Urban's §2, in front of the shipped one-route block.
         The order is fixed and is never reordered by what detection happens to find: §61 says a
         phone app inside the home network is the weaker tool, so "Anywhere" is first, always. A
         screen whose options move is a screen that cannot be learned. -->
    <div id="phone-route" hidden>
      <p class="overlay-note">This is an extra. Rich on this Mac does not need it.</p>
      <h3 class="phone-step-title">Where do you want to use it?</h3>
      <div class="phone-route">
        <button id="phone-route-anywhere" class="desk-btn" type="button">Anywhere, including away from home</button>
        <p class="overlay-note phone-route-note">On the go, on cellular, anywhere your phone has a
          signal. It costs you two app installs, one free Tailscale account, and no certificate at
          all.</p>
        <p class="overlay-note phone-route-note">Rich on your phone stops connecting whenever
          Tailscale is off or signed out on either device — at home too.</p>
      </div>
      <div class="phone-route">
        <button id="phone-route-home" class="desk-btn" type="button">At home only</button>
        <p class="overlay-note phone-route-note">Your phone talks to this Mac over your own home
          network, with no account and no third party. Away from home it will not connect, and
          setting it up means installing a certificate on your phone: sixteen taps, once.</p>
      </div>
    </div>

    <!-- SCREEN 0 — THE IDENTITY TRAP, AND IT COMES BEFORE THE DOWNLOAD.
         CEO §61.1, his ruling in his own words: *"this barrier or I would call it stupidity would
         need to be made ABSOLUTELY UBER MEGA SUPER CRYSTAL-CLEAR to ever user of RichOS"*. What he
         hit: Tailscale has no email-and-password sign-in, only "Sign in with Apple / Google /
         Microsoft / GitHub"; the account IS the network; he signed in with Apple on the Mac and
         Google on the Android, got two networks that cannot see each other, and REINSTALLED
         Tailscale on the Android three times looking for a "connect to Mac" step that does not
         exist. Nothing on Tailscale's screens says any of this.

         **WHY IT IS ITS OWN SCREEN AND NOT A LINE ON THE DOWNLOAD SCREEN.** By the time somebody
         is on the download screen the next thing they do is create the account, and the choice of
         identity is made inside somebody else's sign-in sheet where nothing of ours can reach
         them. A warning that arrives after that choice is a warning that costs a sign-out. His
         own sentence is the reason it cannot be a footnote: *"in hindsight this sounds obvious,
         but it's absolutely NOT obvious at all. Especially given that I would normally absolutely
         NEVER use the same identity on the Mac and on the phone."*

         It is shown while the Mac has no Tailscale account yet — which is exactly the window in
         which the choice can still be made freely — and never again after detection can name one,
         because from then on the screens say WHICH account rather than warning about the choice. -->
    <div id="phone-identity" hidden>
      <h3 class="phone-step-title">First: Tailscale has no password</h3>
      <p class="overlay-note">Tailscale has no username and password. It only offers
        <strong>Sign in with Google</strong>, <strong>Apple</strong>, <strong>Microsoft</strong> or
        <strong>GitHub</strong> — and whichever one you pick, that identity <strong>is</strong> your
        private network.</p>
      <p class="overlay-note">So this Mac and your phone have to sign in with the
        <strong>same</strong> one. Two different identities make two separate networks that cannot
        see each other, and neither device says so — the phone simply never finds this Mac.</p>
      <p class="overlay-note">There is no "connect to my Mac" step in Tailscale, on either device.
        Signing in on both with the same identity is the whole connection. If the phone cannot find
        this Mac, reinstalling Tailscale will not help — the identity is the only thing that
        decides it.</p>
      <p class="overlay-note">If you would rather not use a personal identity on both devices, make
        one that is only for this — a new Google account, which costs nothing — and sign in with
        that one here and on the phone.</p>
      <div class="desk-card-actions">
        <button id="phone-identity-ok" class="desk-btn desk-btn--confirm" type="button">I understand — show me what to do</button>
        <button id="phone-identity-back" class="desk-btn" type="button">Pick a different way</button>
      </div>
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
        <button id="phone-ts-open" class="desk-btn desk-btn--confirm" type="button"></button>
        <button id="phone-ts-recheck" class="desk-btn" type="button">Check again</button>
        <button id="phone-ts-back" class="desk-btn" type="button">Pick a different way</button>
      </div>
    </div>

    <!-- SCREEN 4 — THIS MAC IS READY. No separate "turn serving on": once the name is known there
         is no decision left, so "Set my phone up" does both, under the label the product already
         uses. -->
    <div id="phone-ts-ready" hidden>
      <h3 class="phone-step-title">This Mac is ready</h3>
      <p class="phone-tailnet-name" id="phone-ts-name"></p>
      <!-- WHICH IDENTITY IT SIGNED IN WITH, READ OFF THE MAC (§61.1). "Use the same account" is
           advice nobody can follow, because the one thing the user does not know is which one they
           used — that is the CEO's own account of the evening. This names it. -->
      <p class="overlay-note" id="phone-ts-account"></p>
      <p class="overlay-note">That is this Mac's name on your own Tailscale network. Only devices
        signed in to your Tailscale account can reach it, and no port on this Mac is open to the
        internet.</p>
      <!-- AND THE WATCH LIVES HERE TOO, not only on the phone step. MEASURED: the pairing window
           is 60 s (PAIRING_WINDOW_MS) and the join grace is 60 s, and the watch starts strictly
           AFTER the window opens — so on the phone step alone the mismatch sentence could never
           be reached at all: by the time it was due, the code had expired and the block was
           hidden. Installing Tailscale on a phone and signing in takes minutes, not seconds, so
           this screen — the one the user is returned to when the code runs out — is where the
           sentence has to be able to appear. -->
      <p class="overlay-note" id="phone-ts-peer-ready" role="status"></p>
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

  /// **WHAT THE PAIRED PHONE HAS TO DO BEFORE IT CAN BE REACHED — in that phone's own words.**
  ///
  /// Ray's candidate .11 defect 4.5. The card said *"Add Rich to your phone's Home Screen and
  /// allow notifications when it asks."* On his HONOR X6b, Chrome's menu offers **"Install and
  /// create shortcut"** and has no item by the other name at all — so the Mac named a control
  /// the device does not have.
  ///
  /// **AND ON ANDROID THE INSTRUCTION IS WRONG, NOT ONLY MISNAMED.** Chrome on Android
  /// subscribes to push from a tab; nothing has to be installed first. It is iOS Safari that
  /// cannot take a push until the app is on the Home Screen. The phone page records the same
  /// division (`web/web-app/app.js`, `installControlName` / `installSentence`), and the two
  /// surfaces now say the same thing about the same phone.
  ///
  /// The menu and item names are exactly the phone page's, so a person reading the Mac and then
  /// his phone is not reading two names for one control. `null`-equivalent — a phone this Mac
  /// cannot name — gets the sentence that is true of both and names neither as the one to use.
  const PUSH_NOT_READY = {
    ios:
      "It cannot send you notifications yet. On your phone, open the Share menu in Safari and " +
      "choose \u201cAdd to Home Screen\u201d, then allow notifications when Rich asks.",
    android:
      "It cannot send you notifications yet. Allow notifications on your phone when Rich asks " +
      "\u2014 Chrome on Android does not need Rich installed first.",
    other:
      "It cannot send you notifications yet. Allow notifications on your phone when Rich asks. " +
      "On an iPhone you have to add Rich to the Home Screen first, from Safari\u2019s Share menu.",
  };

  /// Which of the three, from the platform on the device record. Anything unrecognized —
  /// including a record written before the field existed — gets the sentence that is true
  /// whatever the phone is, rather than a guess at which menu it has.
  function pushNotReadyFor(platform) {
    return Object.prototype.hasOwnProperty.call(PUSH_NOT_READY, platform)
      ? PUSH_NOT_READY[platform]
      : PUSH_NOT_READY.other;
  }

  /// **THE PAIRED CARD'S COPY, DERIVED FROM THE RECORD AND FROM NOTHING THE SHEET REMEMBERS.**
  ///
  /// Ray's candidate .11 walk, defect 3.2: immediately after pairing an ANDROID phone over
  /// Tailscale the card said *"There is nothing to remove from your phone."* Closing and
  /// reopening the same card for the same phone said, instead, *"…open Settings, then General,
  /// then VPN and Device Management, then the RichOS profile, then Remove Profile"* — an iOS
  /// procedure, on a card whose own first line reads "Android phone is paired", on the one path
  /// that never installs a certificate. Reproduced twice.
  ///
  /// **The cause was not the copy, it was where the copy was keyed from.** `route` below is
  /// forgotten on every open, on purpose (Urban §1). So on a reopen `route === null`, which is
  /// not "anywhere", which selected the home path's paragraph — a default presented as a fact.
  ///
  /// So the two answers are recorded on the Mac at pairing (`device.rs`'s `paired_via` and
  /// `platform`) and arrive on every `phone_status`. **Four combinations, and a fifth for a
  /// record written before those fields existed**, which says it does not know rather than
  /// picking one of the four.
  const PAIRED_FORGET_NOTE = {
    // BOTH PLATFORMS, ONE SENTENCE, on the Tailscale path — because on this path the answer
    // genuinely does not depend on the phone: no profile is ever installed on it. The flow says
    // so on the way in ("There is no certificate to install on this path"), and this is the same
    // fact at the other end of the feature.
    "tailnet:ios":
      "Forgetting it here stops this Mac answering it, deletes the keys, and stops this Mac " +
      "answering at its Tailscale name. There is nothing to remove from your phone.",
    "tailnet:android":
      "Forgetting it here stops this Mac answering it, deletes the keys, and stops this Mac " +
      "answering at its Tailscale name. There is nothing to remove from your phone.",
    "tailnet:other":
      "Forgetting it here stops this Mac answering it, deletes the keys, and stops this Mac " +
      "answering at its Tailscale name. There is nothing to remove from your phone.",
    // THE SIXTEEN TAPS' OTHER END, and the only combination this paragraph was ever true of.
    // Apple's own screen names, in Apple's own order, exactly as the sixteen steps use them —
    // "VPN &amp; Device Management" is what the phone says, and the flow spelled it "VPN and
    // Device Management" in this one place.
    "home:ios":
      "Forgetting it here stops this Mac answering it, and deletes the keys. It does " +
      "<strong>not</strong> remove the certificate from your phone. To remove that too, on your " +
      "phone open Settings, then General, then VPN &amp; Device Management, then the RichOS " +
      "profile, then Remove Profile.",
    // AND THE COMBINATION THE OLD COPY WAS ACTUALLY SHOWN FOR. What this Mac serves at the trust
    // endpoint is an Apple `.mobileconfig` and nothing else (`ca.rs`'s `mobileconfig`, served by
    // `listen.rs` on TRUST_PORT), so RichOS has never put anything on an Android phone to
    // remove. It does not name an Android menu path, because it cannot know one it did not use.
    "home:android":
      "Forgetting it here stops this Mac answering it, and deletes the keys. There is nothing " +
      "RichOS put on your Android phone to remove — the certificate step on this path installs " +
      "an Apple profile, which an Android phone never took. If you added this Mac's certificate " +
      "to it by hand, remove it in your phone's own security settings.",
    "home:other":
      "Forgetting it here stops this Mac answering it, and deletes the keys. If you installed " +
      "this Mac's certificate on your phone during setup, that stays on the phone until you " +
      "remove it there — on an iPhone it is under Settings, then General, then VPN &amp; Device " +
      "Management.",
  };

  /// The fifth answer: a phone paired by a build that did not write either field down.
  /// **It says it does not know.** A default here would be the original defect with a longer
  /// comment on it, and the honest version costs him one re-pair.
  const FORGET_NOTE_UNKNOWN =
    "Forgetting it here stops this Mac answering it, and deletes the keys. This phone was " +
    "paired by an older version of RichOS, which did not record which way it connected, so I " +
    "cannot tell you whether it has a certificate on it to remove. Pair it again and I will be " +
    "able to.";

  /// **THE FIRST PARAGRAPH OF EVERY SCREEN, AND IT FOLLOWS THE OPTION HE CHOSE.**
  ///
  /// Ray's candidate .11 defect 3.1. Every screen in this flow opened with *"Your phone talks
  /// to this Mac directly, over your own home network. Nothing of what you say goes anywhere
  /// else, and there is no account to make."* That describes **At home only**. It stayed there,
  /// word for word, after he chose **Anywhere** — which is not the home network, and which does
  /// involve making an account. §61 exists because he wants this usable away from home, and the
  /// standing first sentence told him the opposite. Screenshots 13, 14, 15, 17.
  ///
  /// **The Tailscale lead does not repeat the home path's privacy claim, and that is the
  /// point.** "Nothing of what you say goes anywhere else" is true of a phone and a Mac on one
  /// home network. On the tailnet the packets are encrypted end to end between the two devices
  /// but they can be relayed by Tailscale's own servers when a direct connection cannot be
  /// made, so the honest claim is about what is ENCRYPTED and about where the conversation is
  /// KEPT — both of which this Mac can stand behind — and not about what never travels.
  ///
  /// **ONE WORD FOR THE PLACE, and the word is "home".** The flow called it "the office", "the
  /// house" and "home" in three adjacent sentences (same defect, Ray's related note). "At home
  /// only" is the option's own name and "your own home network" is the thing it describes, so
  /// the other two were the odd ones out: the button now reads "Anywhere, including away from
  /// home" and the home option's note "Away from home it will not connect".
  const LEAD = {
    // Before he has chosen. It says the one thing that is true of both options and makes no
    // claim that belongs to either.
    none:
      "Rich on your phone talks to this Mac and to nothing else. Your conversations stay here, " +
      "on this Mac, whichever way you set it up.",
    anywhere:
      "Your phone reaches this Mac over your own Tailscale network, from anywhere it has a " +
      "signal. The connection to this Mac is encrypted, your conversations stay here, and it " +
      "costs one free Tailscale account signed in on both devices.",
    "at-home":
      "Your phone talks to this Mac directly, over your own home network. Nothing of what you " +
      "say goes anywhere else, and there is no account to make.",
  };

  /// **WHAT AN EXPIRED CODE SAYS**, on the screen it expired on. It names what happened, says
  /// the codes are meant to run out, and points at the button beside it — so the one thing he
  /// does next is the one control on the screen. Before this he was shown nothing at all.
  const EXPIRED_NOTE =
    "Pairing codes run out on purpose, so one left on a screen cannot be used later. Nothing " +
    "is wrong and nothing was lost. Press Show me another code and a fresh one appears here.";

  /// **The one line that is true only of the Tailscale path.** Same source as the note above,
  /// for the same reason: it was keyed off `route` and vanished on a reopen.
  const PAIRED_TAILNET_LIMIT =
    "You can use this away from home. Both devices have to be signed in to Tailscale for it to " +
    "connect — at home too.";

  /// Which of the five the record selects. `via` and `platform` are the tokens `device.rs`
  /// writes; an empty string is a record from before they existed, and anything unrecognized is
  /// treated the same way rather than folded into one of the four.
  function forgetNoteFor(via, platform) {
    const key = String(via || "") + ":" + String(platform || "");
    return Object.prototype.hasOwnProperty.call(PAIRED_FORGET_NOTE, key)
      ? PAIRED_FORGET_NOTE[key]
      : FORGET_NOTE_UNKNOWN;
  }

  let ticker = null;
  let busy = false;
  let returnFocus = null;
  let poller = null;

  /// **WHICH ROUTE HE PICKED, AND IT IS NEVER REMEMBERED.** Urban's §1 consequence 2: open the
  /// sheet unpaired and it asks again. A remembered choice with no visible way to change it is a
  /// trap, and re-asking costs one screen that is already there. `null` means Screen 1.
  let route = null;

  /// **Whether the identity screen has been read, this open.** Same lifetime as `route` and for
  /// the same reason: it is a thing the user has been told, not a thing the Mac knows, and a
  /// "don't show me again" on the one warning §61.1 exists for would be the warning quietly
  /// deleting itself.
  let identityUnderstood = false;

  /// When the phone step first appeared, so "it has not joined" can be told from "it has not
  /// finished signing in". `null` whenever that screen is not up.
  let waitingForPhoneSince = null;

  /// **How long a phone is given to appear on the tailnet before the screen calls it a mismatch.**
  ///
  /// `unverified:` **sixty seconds is a judgment, not a measurement.** Measuring it properly needs
  /// a second device signing in to a fresh account while this Mac watches, and I had one Mac and no
  /// phone. What decided the number is which way the error costs more: too SHORT and a user who is
  /// still typing their password is told they got it wrong — which would send them to re-do a
  /// sign-in that was correct, the exact loop that had the CEO uninstalling the app three times.
  /// Too long merely means a few more seconds of "waiting". So it is biased long on purpose.
  /// Settled by one measurement with a real phone, and the constant is here to be changed.
  const PHONE_JOIN_GRACE_MS = 60000;

  /// Escape text destined for `innerHTML`. Only one string needs it — the account name, which comes
  /// from another program's output — and it gets it rather than being trusted for being ours.
  function escapeText(text) {
    const box = document.createElement("span");
    box.textContent = String(text);
    return box.innerHTML;
  }

  /// Every external address these screens name, each one verified against Tailscale's own install
  /// documentation rather than recalled — see `docs/verification/tailscale-path-2026-09-18.md` §4a.
  ///
  /// **They are both written out AND opened by a control.** The printed form is Urban's own
  /// requirement — *"a control that opens somewhere the user cannot see first is a control that
  /// asks for trust it has not earned"* — and it is the fallback for a Mac where the opener does
  /// not work. The control is there because on 2026-09-19 the CEO could not find the download
  /// from `tailscale.com`'s home page nor from the admin console, and an address a person has to
  /// retype into a browser is an address half of them will mistype.
  ///
  /// **`open_external` takes these strings as KEYS, not as URLs.** `src-tauri/src/opener.rs`
  /// matches the whole string against a five-entry table and refuses everything else; a test over
  /// there reads THIS object and proves every value in it is one the command will open, so a new
  /// address added here without an allowlist entry fails the suite rather than producing a button
  /// that quietly does nothing.
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
  /// The app itself, not a page — `opener.rs`'s fifth allowlist entry. "Open Tailscale" has to
  /// bring the app the user already installed to the front; sending somebody who has it to a
  /// download page would be telling them to install it again.
  const TAILSCALE_APP = "Tailscale.app";

  const WAITING = {
    absent: {
      heading: "Install Tailscale on this Mac",
      note1:
        "Tailscale is somebody else's app, and it is free for one person. It gives this Mac a name your phone can reach from anywhere, and it is the whole reason this path has no certificate in it.",
      note2: "Download it, install it, then come back here. This screen moves on by itself when it sees it.",
      url: LINKS.mac,
      action: { label: "Get Tailscale", target: LINKS.mac },
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
      action: { label: "Open Tailscale", target: TAILSCALE_APP },
    },
    "certificates-off": {
      heading: "Tailscale is signed in, but this Mac has no name yet",
      note1:
        "Tailscale gives each machine a name on your network, and this Mac does not have one I can use. In Tailscale's own admin console, turn on MagicDNS and HTTPS certificates for your network, then come back.",
      note2: "",
      url: LINKS.console,
      action: { label: "Open the Tailscale console", target: LINKS.console },
    },
  };

  /// **Ask the Mac to open one of the five addresses these screens name.**
  ///
  /// The refusal is a sentence rather than a silence: a control that does nothing is the one
  /// failure a user cannot tell from a slow one, and the address is printed right beside it.
  async function openExternal(target) {
    try {
      await bridge.invoke("open_external", { target });
    } catch (error) {
      field("phone-message").textContent =
        "I could not open that on this Mac. The address is written out above — type it into your browser.";
    }
  }

  /// **Is the phone on this network, and can it answer?** Three states, three different things to
  /// do, and telling them apart is the whole of §61.1's detection half.
  ///
  /// * **A live peer** — nothing to fix, and saying so is what stops a user who has done it right
  ///   going round again.
  /// * **A peer that is switched off** — MEASURED on this Mac on 2026-09-19: his Android was in
  ///   the daemon's `Peer` map TWICE, one stale registration per reinstall, and both were
  ///   `"Online": false` because Tailscale on the phone was off. The fix is one switch in the
  ///   Tailscale app. Sending that user back to check their identity is the loop this screen
  ///   exists to end.
  /// * **No peer at all, after a wait** — a phone signed in to a DIFFERENT identity is in a
  ///   different tailnet and shows up nowhere at all, so absence is the evidence. It is named
  ///   only after the grace window, because before that "not here yet" and "still signing in"
  ///   are the same thing and calling it a mistake would be the screen guessing.
  function peerLine(line, tailnet) {
    if (tailnet.phone && tailnet.phoneOnline) {
      line.textContent = "Your phone (" + tailnet.phone + ") is on this network.";
      return;
    }
    if (tailnet.phone) {
      line.textContent =
        "Your phone (" + tailnet.phone + ") is on this network but Tailscale is switched off on " +
        "it. Turn it on in the Tailscale app.";
      return;
    }
    const waited = waitingForPhoneSince === null ? 0 : Date.now() - waitingForPhoneSince;
    if (waited < PHONE_JOIN_GRACE_MS) {
      line.textContent = "Waiting for your phone to join…";
      return;
    }
    line.textContent = tailnet.account
      ? "Your phone is not on this network yet. On the phone, sign in with " + tailnet.account +
        ", then come back here. Reinstalling the app will not help — the identity is the only " +
        "thing that decides it."
      : "Your phone is not on this network yet. On the phone, sign in with the same account this " +
        "Mac uses, then come back here. Reinstalling the app will not help — the identity is the " +
        "only thing that decides it.";
  }
  // The states that are not a step of their own borrow the nearest screen that tells the truth.
  // Each of these is "Tailscale is on this Mac and is not usable yet", and the sign-in screen is
  // the one that says so without claiming to know more than detection does.
  WAITING["not-running"] = WAITING["needs-sign-in"];
  WAITING["needs-approval"] = WAITING["needs-sign-in"];
  WAITING["stopped"] = WAITING["needs-sign-in"];
  WAITING["other-user"] = WAITING["needs-sign-in"];

  function render(status) {
    const live = !!status.pairUrl;
    // **A CODE THAT RAN OUT IS A STATE OF THIS SCREEN, NOT A REASON TO LEAVE IT.**
    //
    // Ray's candidate .11 defect 3.3: the Mac dropped the window, the next poll came back with
    // no `pairUrl`, and the dialog fell back to an earlier screen with the QR, the code and the
    // six words gone and nothing said. *"He reads the screen, walks to get his phone, unlocks
    // it, opens the camera — and comes back to a screen that looks like he imagined the whole
    // thing."*
    //
    // **`listening` IS THE EVIDENCE, and it is the Mac's rather than this sheet's.** The socket
    // comes up only inside `phone_begin_pairing` for an unpaired Mac (`mod.rs`'s `start`, and
    // `resume_if_paired` returns early unless something is paired), and it stays up after the
    // window closes. So a Mac that is serving, has nothing paired and has no live code is a Mac
    // whose code ran out — no matter how long ago, and no matter how many times this sheet has
    // been closed and reopened since. A flag in this file would have forgotten it on the open,
    // which is the same mistake defect 3.2 was.
    const expired = !live && !status.paired && !!status.listening;
    // Everything downstream that used to mean "a window is open" now means "the pairing screen
    // is the screen", because it is, in both states.
    const pairing = live || expired;
    const tailnet = status.tailnet || { state: "absent" };
    // **WHILE A WINDOW IS OPEN, THE MAC SAYS WHICH PATH IT IS SERVING. Never `route`.**
    //
    // Urban's blocker, `esc-20260919T041857Z-640acd39`, reproduced twice on candidate .12:
    // choose Anywhere, press Set my phone up, close the sheet, reopen it while the code is still
    // live — and the HOME path's screen came back. Two unverified-certificate warnings, the
    // trust QR at `http://mm1.local:8444/ca` and the sixteen certificate taps, wrapped around
    // the TAILNET pairing URL, on the one path that installs no certificate; and the sentence
    // written to catch exactly that ("There is no certificate to install on this path") hidden
    // by the same condition.
    //
    // The cause was two correct decisions meeting: `route` is reset to `null` on every open
    // (Urban §1 — the choice is never remembered), and `choosing` requires `!pairing`, which a
    // live OR an expired code makes true. So a reopen fell straight through to the pairing
    // screen with `onTailscale === false` and `:838-841` then hid every Tailscale-only node and
    // showed every home-only one. The comment two screens up stated the assumption that broke —
    // "a listening, unpaired Mac is someone MID-FLOW on the home path" — which stopped being
    // true the moment the Tailscale route also made the Mac listen.
    //
    // **The fix is `paired_via`'s ruling one state earlier: which path the OPEN window was
    // started for is a fact the Mac holds.** `status.servingVia` is `Channel::pairing_path` —
    // the same value a redeeming phone's record is stamped from, and the same value that moves
    // when the Tailscale addresses fail to bind and the whole channel falls back home. Nothing
    // is persisted and nothing is remembered here; `route` still answers only while he is
    // CHOOSING, which is the one state in which it is the truth.
    const onTailscale = pairing
      ? status.servingVia === "tailnet"
      : route === "anywhere";

    // **THE LEAD, FIRST, BECAUSE EVERY SCREEN BELOW CARRIES IT.** Once a phone is paired the
    // route is not a question any more and the record answers it — the same source the forget
    // note uses, and for the same reason: `route` is forgotten on every open, so a paired card
    // that read it would describe the wrong path on the second visit (defect 3.2).
    const leadKey = status.paired
      ? status.pairedVia === "tailnet"
        ? "anywhere"
        : status.pairedVia === "home"
          ? "at-home"
          : "none"
      : pairing
        // **AND THE LEAD FOLLOWS THE SAME FACT WHILE A WINDOW IS OPEN.** It is the first thing
        // on every screen below, so a reopen whose screens were right and whose opening
        // sentence still described the path he did not choose would be the blocker again, one
        // paragraph shorter.
        ? (status.servingVia === "tailnet" ? "anywhere" : status.servingVia === "home" ? "at-home" : "none")
        : route || "none";
    field("phone-lead").textContent = LEAD[leadKey];

    // Rows 1 and 9 of Urban's §3: unpaired with no route chosen is Screen 1.
    //
    // **`!status.listening` is mine, and it is not in Urban's table.** His row 1 says "any, not
    // paired" and does not distinguish a Mac that is already serving. A listening, unpaired Mac is
    // someone MID-FLOW on the home path — commonest case, a code that expired while they were
    // looking at their phone — and sending them back to the route question there loses their place
    // and strands the pairing window. Screen 1 is the entry point, not an interruption. Found by
    // `ui/tests/phone.js` check 8, which is exactly that case.
    const choosing = !status.paired && !pairing && !status.listening && route === null;
    // SCREEN 0 — the identity trap (§61.1). Shown while this Mac has no Tailscale account yet,
    // which is exactly the window in which the choice of identity can still be made freely. Once
    // detection can name an account the screens say WHICH one instead, and this never returns.
    const identity =
      onTailscale && !status.paired && !pairing && !tailnet.account && !identityUnderstood;
    // Rows 2, 3 and 5: a route is chosen, nothing is serving yet, and the Mac is not ready.
    const waiting =
      onTailscale && !status.paired && !pairing && !identity && tailnet.state !== "ready";
    // Row 4: ready, and the only thing left is the code.
    const ready =
      onTailscale && !status.paired && !pairing && !identity && tailnet.state === "ready";

    field("phone-route").hidden = !choosing;
    field("phone-identity").hidden = !identity;
    field("phone-ts-wait").hidden = !waiting;
    field("phone-ts-ready").hidden = !ready;
    field("phone-paired").hidden = !status.paired;
    field("phone-pairing").hidden = status.paired || !pairing;
    field("phone-off").hidden =
      status.paired || pairing || choosing || identity || waiting || ready;

    // Rows 2, 3 and 5 poll — and so do BOTH of the screens that are waiting for the phone, because
    // a phone joining the tailnet is another thing that happens elsewhere and has to move the
    // screen on its own. Screen 0 does not: nothing detection can find changes what it says.
    // This is the whole reason there is no Next button anywhere in the flow.
    setPolling(waiting || ready || (onTailscale && pairing && !status.paired));

    // **THE WATCH STARTS WHEN THE USER IS FIRST TOLD TO GO TO THEIR PHONE**, which is Screen 4 as
    // well as Screen 5 — see the note beside `#phone-ts-peer-ready` for the frame math that makes
    // Screen 5 alone unreachable: window 60 s, grace 60 s, and the watch starting after the
    // window opens leaves an empty interval.
    if (onTailscale && (ready || (pairing && !status.paired))) {
      if (waitingForPhoneSince === null) waitingForPhoneSince = Date.now();
    } else {
      waitingForPhoneSince = null;
    }

    if (status.paired) {
      field("phone-device-name").textContent = status.deviceName || "Your phone";
      field("phone-push-state").textContent = status.pushReady
        ? "It can reach you with a notification when Rich has something for you."
        : pushNotReadyFor(status.platform);
      // **SCREEN 6, DERIVED FROM THE RECORD.** `onTailscale` is deliberately NOT consulted
      // here: it reads `route`, which this sheet forgets on every open, and a card that
      // described the path from a forgotten answer is the whole of defect 3.2. What the phone
      // paired over is a fact the Mac wrote down at pairing, and it is the only thing that
      // decides these two lines — on the first open and on every reopen alike.
      const pairedOverTailnet = status.pairedVia === "tailnet";
      field("phone-ts-limit").textContent = PAIRED_TAILNET_LIMIT;
      field("phone-ts-limit").hidden = !pairedOverTailnet;
      field("phone-forget-note").innerHTML = forgetNoteFor(status.pairedVia, status.platform);
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
      // THE CONTROL THAT OPENS THE THING THE SCREEN JUST NAMED. Its label is the state's, because
      // "Get Tailscale", "Open Tailscale" and "Open the Tailscale console" are three different
      // actions and one generic verb over them would be a button whose effect the user has to
      // guess. The address stays printed above it either way.
      const opener = field("phone-ts-open");
      opener.textContent = screen.action ? screen.action.label : "";
      opener.hidden = !screen.action;
      opener.dataset.target = screen.action ? screen.action.target : "";
      return;
    }

    if (ready) {
      // THE SAME LINE THE PHONE SCREEN WILL REPEAT, on the Mac, after sign-in. The identity has to
      // be visible here or the user cannot know which one to reuse — that is the CEO's own
      // experience, and it is why the account is shown rather than only the machine name. It is
      // its own paragraph rather than two newlines inside the machine name, because the name is
      // monospace and read character by character and a sentence is neither.
      field("phone-ts-name").textContent = tailnet.name || "";
      field("phone-ts-account").textContent = tailnet.account
        ? "You signed in with " + tailnet.account + ". Use exactly this on your phone."
        : "I cannot tell which identity this Mac is signed in to. Whichever it is, sign in with exactly the same one on your phone.";
      peerLine(field("phone-ts-peer-ready"), tailnet);
      return;
    }

    if (!pairing) {
      // ONE MESSAGE, BECAUSE THERE IS NOW ONE STATE HERE. This used to branch on
      // `status.listening` and say "Nearly there. Ask for a code…" for a serving Mac with no
      // live code — which is precisely the expired state, and it is now drawn above with the
      // reason and the button rather than as a sentence on a screen he was thrown back to.
      // `pairing` is true whenever `listening && !paired`, so that branch is unreachable from
      // here: this block is a Mac that has never been asked for a code.
      field("phone-off-message").textContent =
        "I will make a certificate for your phone, then show you two codes to scan. It takes a few minutes, once, ever.";
      return;
    }

    // SCREEN 5 versus the shipped home flow. The trust code, the two warnings and the sixteen
    // steps belong to the home path and are absent here rather than hidden behind a smaller font.
    // **AN EXPIRED SCREEN IS THE EXPIRY AND THE WAY OUT, AND NOTHING ELSE.** The instructions
    // belong with a live code: warnings about a red word he is not about to meet, and steps
    // pointing at a QR that is not on the screen, are a screen asking him to do a thing that is
    // not there. They all come back with the next code.
    field("phone-ts-steps").hidden = !onTailscale || expired;
    field("phone-home-warnings").hidden = onTailscale || expired;
    field("phone-ts-failure").hidden = !onTailscale || expired;
    field("phone-ts-store").textContent = onTailscale && !expired
      ? "iPhone: " + LINKS.phone + "      Android: " + LINKS.android
      : "";

    if (onTailscale && !expired) {
      // THE WHY COMES BEFORE THE STEPS, AND IT NAMES THE ACCOUNT (§61.1 (c)). The reason is given
      // before the instruction because it is asking the user to break a habit: *"I would normally
      // absolutely NEVER use the same identity on the Mac and on the phone."* A person who
      // follows a step that says "sign in" and uses the wrong one is being correct by their own
      // lights, and the result is two networks that never meet with nothing saying why.
      field("phone-ts-why").innerHTML = tailnet.account
        ? "Your Tailscale account <strong>is</strong> your private network. Devices signed in to " +
          "it can reach each other. So on your phone, sign in with <strong>" +
          escapeText(tailnet.account) + "</strong> — exactly what this Mac used — even if you " +
          "would normally keep your phone and your Mac apart. Nothing else connects them."
        : "Your Tailscale account <strong>is</strong> your private network. Devices signed in to " +
          "it can reach each other. So sign in on your phone with the same account you used on " +
          "your Mac, even if you normally keep them separate. Nothing else connects them.";

      // STEP 2, FILLED IN. The CEO signed in with Apple on the Mac and Google on the Android and
      // "had no way to know they were different networks, or which to reuse". Naming the account
      // is the difference between an instruction he can follow and one he cannot.
      field("phone-ts-step2").innerHTML = tailnet.account
        ? "Sign in with <strong>" + escapeText(tailnet.account) +
          "</strong> — the same one this Mac is signed in to. A different provider makes a " +
          "different network, and then the two will never see each other."
        : "Sign in with the <strong>same</strong> identity you used on this Mac. A different " +
          "provider makes a different network, and then the two will never see each other.";

      // WAITING, THEN SAYING SO — the same three sentences Screen 4 uses, from the same helper,
      // so the two screens cannot word the same evidence differently.
      peerLine(field("phone-ts-peer"), tailnet);
    }
    field("phone-code-title").textContent = onTailscale
      ? "Then point your phone's camera at this"
      : "2. Then point it at this, to open Rich";
    field("phone-words-title").textContent = onTailscale
      ? "Check the six words match"
      : "3. Check the six words match";

    // **THE CODE, OR THE FACT THAT IT RAN OUT — never neither, and never a screen that just
    // went blank.** Defect 3.3. Everything that IS the code is drawn only while there is one;
    // when it has run out the same screen carries the reason and the button that replaces it.
    paint(field("phone-qr-trust"), live && !onTailscale ? status.trustUrl : "");
    paint(field("phone-qr-pair"), live ? status.pairUrl : "");
    field("phone-trust-url").textContent = live && !onTailscale ? status.trustUrl || "" : "";
    field("phone-pair-url").textContent = live ? status.pairUrl || "" : "";
    field("phone-words").textContent = live ? (status.fingerprintWords || []).join("  ") : "";
    field("phone-bound").textContent =
      live && status.bound && status.bound.length
        ? "This Mac is answering on " + status.bound.join(", ") + "."
        : "";
    // The headings above those blocks go with them: a numbered step over an empty space is a
    // screen telling him to do something that is not there.
    field("phone-code-title").hidden = !live;
    field("phone-words-title").hidden = !live;
    // AND THE SENTENCE UNDER THAT HEADING, which is the half defect B found: it survived the
    // expiry telling him to check "these six" with nothing to check them against.
    field("phone-words-note").hidden = !live;
    field("phone-expired").hidden = !expired;
    if (expired) {
      field("phone-expired-note").textContent = EXPIRED_NOTE;
      // One label, in both states, because it is the same act: ask the Mac for a code. It reads
      // "Show me another code" and that is true of a first code after an expiry too.
      field("phone-countdown").textContent = "";
    }
    tick(live ? status.pairingSecondsLeft : null);
  }

  /// **How long is left, in the units a person would say it in.**
  ///
  /// The window is five minutes now (`PAIRING_WINDOW_MS`), and "This code lasts 287 more
  /// seconds." is a number nobody converts. Minutes while there are minutes, seconds under one
  /// minute — and the last minute is where the seconds start to matter, which is the only place
  /// they are shown.
  function remaining(seconds) {
    if (seconds < 60) {
      return seconds + (seconds === 1 ? " more second" : " more seconds");
    }
    const minutes = Math.ceil(seconds / 60);
    return minutes + (minutes === 1 ? " more minute" : " more minutes");
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
        label.textContent = "This code lasts " + remaining(left) + ".";
      } else {
        // The last second of the countdown, and then the expiry block below takes over on the
        // next poll. Both say it; neither leaves the screen.
        label.textContent = "That code has run out. Ask for another one.";
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
        // **AND THE SCREEN REDRAWS ITSELF AT ZERO, ON EVERY PATH.** The poll only runs on the
        // Tailscale route, so on the home route nothing would ever have asked the Mac again and
        // the expiry block would never have appeared — the countdown would have hit zero and
        // the screen would have sat there. One refresh, from inside the interval that has just
        // been cleared, so it cannot recur: the render that follows calls `tick(null)`, which
        // starts no interval.
        if (left <= 0) refresh();
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
    identityUnderstood = false;
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
    identityUnderstood = false;
    await refresh();
  });
  field("phone-route-home").addEventListener("click", async () => {
    route = "at-home";
    await refresh();
  });
  // "Pick a different way" — the only user-driven move backward.
  // SCREEN 0's two controls. "I understand" is not a preference and is not remembered: it lasts
  // as long as this open, exactly like the route.
  field("phone-identity-ok").addEventListener("click", async () => {
    identityUnderstood = true;
    await refresh();
  });
  // AND THE LINKS ARE LIVE. The target is read off the control the render put it on, so the only
  // strings that can ever be asked for are the ones in `LINKS` — and `opener.rs` refuses anything
  // that is not one of its five entries anyway.
  field("phone-ts-open").addEventListener("click", () =>
    openExternal(field("phone-ts-open").dataset.target || "")
  );
  for (const id of ["phone-ts-back", "phone-ts-ready-back", "phone-identity-back"]) {
    field(id).addEventListener("click", async () => {
      route = null;
      await refresh();
    });
  }
  // **THE FIFTH COPY, AND THE ONLY ONE WITH SOMETHING TO PUT DOWN** — Urban's G2.
  //
  // The four above move between screens that are waiting on the user; this one is pressed on a
  // screen with a live code and an open socket behind it, so forgetting `route` is not enough:
  // `choosing` requires `!status.listening`, so a back button that only cleared `route` would
  // redraw the same pairing screen and read as a control that does nothing. The Mac has to be
  // asked to stop first, and the render that follows uses the status that call returns rather
  // than a second round trip — one answer, no window in which the two disagree.
  field("phone-pairing-back").addEventListener("click", async () => {
    if (busy) return;
    busy = true;
    field("phone-message").textContent = "";
    // The ticker is stopped before the call rather than after the render: it fires once a
    // second and calls `refresh()` at zero, and a countdown for a window that is being closed
    // is the one thing on this screen that must not outlive it.
    stopTicking();
    route = null;
    try {
      render(await bridge.invoke("phone_stop_pairing"));
    } catch (error) {
      field("phone-message").textContent = String(error);
    } finally {
      busy = false;
    }
  });
  // `Check again` — the button for the impatient and for the failure. The poll is invisible, and a
  // detection path with no manual retry is a dead end the moment detection is wrong once.
  field("phone-ts-recheck").addEventListener("click", refresh);
  field("phone-ts-start").addEventListener("click", () => begin(false));
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
