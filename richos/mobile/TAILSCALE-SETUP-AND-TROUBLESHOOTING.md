# Tailscale setup and troubleshooting

**What this is for.** RichOS runs on your Mac. To reach it from your phone when you are away from the
office, one of the two paths is **your own Tailscale account** — a free private network between your own
devices, with no server of ours in between. This page is the whole setup, plus every dead end a real
technical user hit doing it for the first time, and what to do about each one.

**You do not need any of this** to run RichOS on one Mac in your office. Mobile is purely optional.

---

## 1. Read this first — the one thing nobody tells you

**Tailscale has no username and password.** You sign in with a Google, Apple, Microsoft or GitHub
identity, or with a passkey. There is no "create an account with an email and a password" option.

**That identity IS your private network.** Not a login to a network — the network itself. Everything
signed in with that identity can see everything else signed in with that identity, and nothing else.

**So your Mac and your phone must sign in with the SAME one.** If you sign in on the Mac with Apple and
on the phone with Google, you have created **two separate networks** that cannot see each other. Both
devices will say they are connected, both will look completely normal, and neither will ever see the
other. Nothing on Tailscale's screens says this.

**If you would never share a personal identity between your computer and your phone** — a common and
sensible habit — **create one identity used only for this.** A dedicated Google account, used for nothing
else, signed in on both devices. That gives you the separation you want and is the only form of "a
Tailscale-only account" that Tailscale actually supports.

**Decide this before you sign in anywhere.** Fixing it afterward means signing out of an account you just
created and signing in again, which is where most of the confusion below comes from.

---

## 2. Setup, step by step

### On your Mac

1. **Download Tailscale:** <https://tailscale.com/download/mac>
   Go straight there. The download is not linked from Tailscale's home page or from the admin console —
   this is the direct link.
   *(Alternative: the Mac App Store listing, <https://apps.apple.com/app/tailscale/id1475387142>.)*
2. **Open the downloaded `.pkg` and click through the installer.** It asks for your Mac's administrator
   password. This is the normal macOS installer; the package is signed and notarized by Apple.
3. **Open Tailscale.** It opens a browser page and asks you to sign in.
4. **Sign in with the identity you chose in section 1.** This is the decision that matters. Whichever
   button you press here, you will press the same one on your phone.
5. **Note which one you used.** Tailscale does not put it in front of you later, and "the same one" is not
   something you want to reconstruct from memory at 11pm.

### On your phone

1. **Install Tailscale.**
   - iPhone or iPad: <https://apps.apple.com/app/tailscale/id1470499037>
   - Android: <https://play.google.com/store/apps/details?id=com.tailscale.ipn>
2. **Open it and tap Sign in.**
3. **Sign in with the SAME identity you used on the Mac.** Same provider button, same account.
4. **Allow the VPN connection your phone asks about.** Both iOS and Android show this prompt. Tap OK or
   Allow.
5. **The switch at the top turns on and says Connected.**

**That is the entire setup. There is no step where you connect the phone to the Mac** — see entry 2 below.

### Turn on HTTPS certificates

RichOS needs your Mac to have a name with a publicly trusted certificate. That is one switch on a new
account, and new accounts start with it off.

1. Open <https://console.tailscale.com/admin/dns>
2. Make sure **MagicDNS** is on. On most new accounts it already is.
3. Under **HTTPS Certificates**, select **Enable HTTPS**.

**Careful:** that console page shows whichever Tailscale account **your browser** is signed in with. If
your browser is signed in with a different identity than the one your devices use, you are looking at a
different network's settings. See entry 6.

### Check both devices are on the same network

Open <https://console.tailscale.com/admin/machines>. **Both your Mac and your phone should be listed
there.** If only one is, they are on different networks — go to entry 3.

---

## 3. Troubleshooting — what you see, why, what to do

### 1. "There is no download link anywhere on tailscale.com"

**What you see.** Neither the home page nor the admin console offers any hint of where to download the
app for your Mac.

**Why.** The download pages exist but are not linked from where you are looking.

**What to do.** Go directly to <https://tailscale.com/download/mac>. For phones, use the store links in
section 2.

---

### 2. "I've installed the phone app three times and still can't find how to connect it to my Mac"

**What you see.** You install Tailscale on the phone, sign in, and then look for the pairing screen, the
"add a device" button, the QR code, the "connect to computer" step. There is none. You assume you missed
a step, uninstall, and start over.

**Why.** **There is no pairing step in Tailscale.** Devices do not connect to each other. Every device
signed in to the same account is already on the same private network, automatically. The thing you are
looking for does not exist.

**What to do.** Stop looking. Check <https://console.tailscale.com/admin/machines> — if both devices are
listed there, you are finished. If only one is listed, the problem is not a missing step, it is entry 3.

---

### 3. "Both devices say Connected but they cannot see each other"

**What you see.** Tailscale is on and looks healthy on the Mac and on the phone. RichOS does not find
your phone. The admin console's machines page shows **only one device**.

**Why.** The two devices are signed in with **different identities**, so they are on two separate
networks. This is by far the most common failure, and it is almost guaranteed if you habitually keep your
computer and phone on different accounts.

**How to tell for certain.** On the machines page, count the devices. One device = two networks. Two
devices = one network.

**What to do — pick the identity you want to keep, then move the other device to it.**

To move the **Mac** onto the phone's identity:

1. Click the Tailscale icon in the Mac's menu bar and choose **Log out**.
2. Click it again and choose **Log in**.
3. Pick the **same provider button** the phone used, and sign in with the phone's account.

Or from the command line:

```
/Applications/Tailscale.app/Contents/MacOS/Tailscale logout
```

then use **Log in** from the menu bar. (The `login` subcommand hands the sign-in to the app's window and
may fail on macOS — see entry 7.)

To move the **phone** onto the Mac's identity: sign out in the phone's Tailscale app and sign back in with
the Mac's provider and account.

**Your network name changes when you switch accounts.** Each account has its own network, so your Mac's
address changes too. That is expected, and RichOS picks the new one up on its own within a couple of
seconds.

---

### 4. "Which account did I even use? I don't know what the password is"

**What you see.** You are told to "sign in with the same identity" and have no idea which button you
pressed, or what the credentials for it are.

**Why.** There is no password to look up — the credential belongs to Google, Apple, Microsoft or GitHub,
not to Tailscale. The only thing you need is **which provider**, and **which account with that provider**.

**What to do.** Read it off the Mac, which knows:

```
/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json
```

Look at the `LoginName` under the `User` entry for your own machine. The address tells you the provider:
an `icloud.com` address means you used Sign in with Apple; a `gmail.com` address means Google; and so on.
Then use that provider button and that account on the phone.

RichOS also shows this for you on its Tailscale screens, so you do not have to run anything.

---

### 5. "I signed in with the right account on the website, but the Mac app still shows the old one"

**What you see.** You go to Tailscale's website, sign in with the account you want, and the Mac's
Tailscale app still shows the old account. It feels as though the app is stuck or lying.

**Why.** **Signing in to `tailscale.com` in a browser does not change which account your Mac is signed in
with.** They are separate. The website is the admin console; the account your Mac actually holds lives in
the Tailscale service on the Mac, and only signing out and in **from the app** changes it.

**What to do.** Check what the Mac really holds:

```
/Applications/Tailscale.app/Contents/MacOS/Tailscale switch --list
```

That lists every account stored on this Mac; the one marked with `*` is active. If the account you want
is not in that list, the Mac never signed in with it — use the menu-bar **Log out** then **Log in** as in
entry 3.

---

### 6. "The login opened in an incognito window" / "my regular browser has a different account"

**What you see.** The sign-in page opens in a private or incognito window, or you are signing in there
deliberately because your normal browser holds a different account you do not want mixed up with this one.

**Why this is fine — better than fine.** **An incognito window is the right place for this**, and it is
exactly the separation you want. An incognito window carries no session from your normal browser, so
signing in there with the Tailscale account touches nothing in your regular browser. The two accounts
never meet. This is a one-time sign-in: afterward, the Mac holds that account itself and the browser is
out of the picture entirely.

**What to do.**

- **If the incognito window is still open:** sign in there, with the account you chose in section 1, and
  approve.
- **If you closed the window and lost the link:** the Mac is still waiting for it, and will hand it back.
  Run:

  ```
  /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json
  ```

  and read the `AuthURL` field. It looks like `https://login.tailscale.com/a/<code>`. Paste that into a
  fresh incognito window and sign in there. If `AuthURL` is empty, the Mac is not waiting for a login —
  start one from the menu bar first.
- **Do not open the link in your regular browser** if that browser is signed in to a different account
  with the same provider; you will either sign Tailscale in with the wrong account or be forced to switch
  accounts in your normal browser.

**Afterward, do you still need the incognito window?** For day-to-day use, no. The Mac and the phone each
hold their own login and RichOS never touches the website. **The one exception is the admin console** —
it shows whichever account the browser is signed in with, so anything you do there (the HTTPS
certificates switch, removing an old device) must be done in the incognito window, signed in as the
account your devices use. Otherwise you will be changing settings on a different network and wondering
why nothing happens.

---

### 7. "The `tailscale login` command fails"

**What you see.**

```
The Tailscale GUI failed to start: The operation couldn't be completed. (Tailscale.CLIError error 3.)
```

**Why.** On macOS, the `login` subcommand delegates the sign-in to the app's own window and can fail to
reach it.

**What to do.** Use the menu-bar icon: **Log in**. `logout` from the command line works normally, so the
usual sequence is `logout` on the command line (or from the menu) and **Log in** from the menu bar. If you
need the pending sign-in link instead of the window, read `AuthURL` from `status --json` as in entry 6.

*(Also: `timeout` is not a macOS command. If you are copying a command from somewhere that wraps things in
`timeout`, it will fail with `command not found: timeout` on a Mac. Nothing to do with Tailscale.)*

---

### 8. "RichOS says HTTPS certificates are not enabled" / "getting a certificate fails with a 500"

**What you see.** RichOS reports that certificates are not enabled for your network, or a certificate
request returns:

```
500 Internal Server Error: your Tailscale account does not support getting TLS certs
```

**Why.** Every brand-new free Tailscale network starts with HTTPS certificates **off**. The error is your
account's control plane saying "this network has not been told to issue certificates" — it is a setting,
not a fault.

**What to do.** Open <https://console.tailscale.com/admin/dns>, make sure **MagicDNS** is on, and under
**HTTPS Certificates** select **Enable HTTPS**. Make sure you are looking at the console **for the account
your devices use** — see entry 6. The change takes effect within a minute or so; RichOS notices on its own.

---

### 9. "My phone is listed but shows as offline"

**What you see.** The phone appears on the machines page, and in RichOS, but is marked offline.

**Why.** Tailscale is switched off on the phone. The device is registered on the network; it just is not
currently connected to it.

**What to do.** Open Tailscale on the phone and turn the switch on. Note that the switch being off is the
normal state after a reboot on some phones, and that it also stops the Mac's Tailscale name from resolving
**on the phone**, including at home.

---

### 10. "My phone is listed twice"

**What you see.** The same phone appears two or more times on the machines page, usually with only one of
them online.

**Why.** Each install registers a new device. If you uninstalled and reinstalled the app — which is
exactly what entry 2 makes people do — each round left a registration behind.

**What to do.** **Nothing, if you do not mind the clutter.** The stale entries are harmless: they are
offline forever and cost nothing. If you want them gone, open
<https://console.tailscale.com/admin/machines> in a browser signed in to that account, and remove the
offline duplicates.

---

### 11. "Which Tailscale app listing is which?"

**What you see.** Two different Apple App Store listings for Tailscale.

**Why.** One is the iPhone and iPad app, the other is the Mac app. They are different products with
different IDs, and installing the wrong one from a link is a real possibility.

**What to do.** Use these exactly:

| Device | Link |
|---|---|
| Mac (direct download) | <https://tailscale.com/download/mac> |
| Mac (App Store) | <https://apps.apple.com/app/tailscale/id1475387142> |
| iPhone / iPad | <https://apps.apple.com/app/tailscale/id1470499037> |
| Android | <https://play.google.com/store/apps/details?id=com.tailscale.ipn> |

---

### 12. Checking the connection actually works

From the Mac, with both devices signed in to the same account and Tailscale on:

```
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
/Applications/Tailscale.app/Contents/MacOS/Tailscale ping -c 2 <your-phone's-tailnet-ip>
```

A healthy result replies twice — typically the first through a Tailscale relay and the second directly,
once the two devices have found a direct route to each other. The second reply is usually much faster than
the first. Both are normal; direct is preferred and happens on its own.

Your Mac's address on the network looks like `<your-machine>.<your-tailnet>.ts.net`, and that is the
address RichOS uses for your phone once certificates are enabled.

---

## 4. If a support walk needs your Android over a cable

Only needed if someone is helping you drive the phone from the Mac. Skip this otherwise.

**On an HONOR phone (MagicOS)** — other Android phones are similar:

1. **Settings** → **About phone**.
2. Find **Build number**. If it is not there, open **Software version** or **Version information** first;
   it is sometimes one level down.
3. Tap **Build number** seven times. A countdown appears, then "You are now a developer."
4. **Settings** → **System & updates** → **Developer options**. On some versions it is **Settings** →
   **System** → **Developer options**.
5. Turn on **USB debugging** and confirm the warning.
6. With the cable plugged in, the phone shows **"Allow USB debugging?"** with the computer's fingerprint.
   Tick **"Always allow from this computer"** and tap **Allow**.

**If the Mac still does not see the phone after all that,** the cable is in charging-only mode:

1. Pull down the notification shade on the phone. There is a notification like "Charging this device via
   USB."
2. Tap it and choose **Transfer files** (also called "File transfer" or "MTP").
3. The "Allow USB debugging?" prompt appears now. Tick "Always allow from this computer" and tap **Allow**.
4. If no prompt appears, unplug and replug the cable once, with USB debugging already on.

---

## 5. The short version

- The account is the network. **Same identity on both devices, or nothing works.**
- There is **no pairing step**. Signing in on both devices is the whole connection.
- Download the Mac app from **<https://tailscale.com/download/mac>** — it is not linked from the home page.
- Signing in **on the website** does not sign in **the Mac app**. They are separate.
- An **incognito window is the right place** to sign in when your normal browser holds another account.
- New networks have **HTTPS certificates off**: <https://console.tailscale.com/admin/dns> → **Enable
  HTTPS**.
- The admin console shows **whichever account the browser is signed in with**. Check that before believing
  what it shows you.
