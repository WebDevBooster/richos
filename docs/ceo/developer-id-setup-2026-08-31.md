# Two things only you can do — about 20 minutes, once, ever

You bought the Apple Developer membership today. Everything else about signing RichOS is
built and waiting. Two items are locked to your Apple account and cannot be delegated: a
**certificate**, and a **key**. Both are just files you download from a website.

**Why it is worth twenty minutes.** Right now, every time a new RichOS build reaches your
Mac, macOS treats it as a completely different app and silently takes away its microphone
and its permission to type into other windows. Rich comes back deaf. Turning the switch
back on in System Settings does not fix it — that was measured, it genuinely does not
work. After these twenty minutes, macOS recognises every future build as the same app and
the permissions stay put forever.

You do not need to understand any of the words below. Follow the steps.

---

## Before you start — the file we made for you

We have already generated the file Apple will ask you to upload. It is here:

```
/Users/alex/.richos-signing/developer-id.certSigningRequest
```

In the Finder, press **⌘⇧G** and paste that path to find it. It is safe to send to Apple —
it is the public half. The private half sits beside it and never leaves this Mac.

---

## Task 1 — the certificate  (about 10 minutes)

1. Go to **<https://developer.apple.com/account>** and sign in.
2. Click **Certificates, IDs & Profiles** (left side), then **Certificates**.
3. Click the **blue + button** at the top of the list.
4. You will see a long list of certificate types with radio buttons. Scroll to the
   **Software** section and choose:

   > ### ✅ Developer ID Application

   **This is the one that matters, and three of its neighbours look right and are not:**

   | Do not pick | Why not |
   |---|---|
   | Developer ID **Installer** | Signs installer packages, not the app. Wastes a day. |
   | **Apple Development** | For testing on your own devices. macOS will still block RichOS. |
   | **Apple Distribution** | For the App Store. RichOS is not going to the App Store. |
   | **Mac Installer Distribution** | App Store again, and installers again. |

   If the list ever shows two Developer ID Application options, pick the one mentioning
   **G2 Sub-CA** or **Xcode 11.4.1 or later**. That is the current one.

5. Click **Continue**. Apple now asks for a "Certificate Signing Request".
   Click **Choose File** and pick the file named at the top of this page.
6. Click **Continue**, then **Download**.

**You are done when** a file lands in your Downloads folder called something close to
`developerID_application.cer`.

**One caution:** Apple lets you create at most **five** of these, ever. Do not make spares
"just in case" — one is all RichOS will ever need.

Tell Rich it has downloaded. That is all; the rest of task 1 is a single command on this
Mac and nobody needs you for it.

---

## Task 2 — the notarisation key  (about 8 minutes)

Apple also has to *inspect* each build before other Macs will open it. That inspection
needs a key. There is an old way that involves storing your Apple password in a file, and
we are not doing that.

1. Go to **<https://appstoreconnect.apple.com>** and sign in with the same account.
2. Click **Users and Access** (top of the page).
3. Click the **Integrations** tab, then **App Store Connect API** in the sidebar.
4. **Make sure you are on the "Team Keys" tab, not "Individual Keys".**
   This is the single most common mistake here: an Individual key looks identical, is
   created the same way, and simply cannot notarise. It fails much later with a message
   that does not mention the tab you were on.
5. Click the **+** button. Give it a name — `RichOS notarisation` is fine.
6. For **Access**, choose **Developer**. That is enough; nothing here needs more.
7. Click **Generate**.
8. Click **Download API Key**.

   > **You get exactly one download.** Apple will not give you this file a second time.
   > If you lose it, the key has to be revoked and the whole task redone. It is not a
   > disaster, just tedious.

9. Before you leave the page, copy down two things next to your new key:
   - the **KEY ID** — ten characters, in the table row;
   - the **Issuer ID** — a long dashed code shown *above* the table.

   Paste both to Rich, or leave them somewhere you can find them. Neither is secret in the
   way the file is.

**You are done when** you have a file called `AuthKey_XXXXXXXXXX.p8` in your Downloads
folder, plus those two codes.

Then move the file out of Downloads, because Downloads gets tidied:

```
mkdir -p ~/.richos-signing
mv ~/Downloads/AuthKey_*.p8 ~/.richos-signing/
chmod 600 ~/.richos-signing/AuthKey_*.p8
```

---

## What "it worked" looks like

You will not have to judge this. After task 1, the command that installs the certificate
prints one line, and it either says this or it refuses:

```
OK: 'Developer ID Application: Alex Booster (XXXXXXXXXX)' is installed and usable.
```

And the first properly signed, notarised build ends with a line that reads, in part:

```
OK: RichOS.app is bundled, Developer ID signed, notarized, STAPLED and verified
```

If either of those does not appear, nothing pretends it did — every one of these scripts
refuses out loud rather than reporting a success it did not earn.

---

## One thing that is still not proven, and you will be the one who proves it

The whole point is that your microphone permission survives the next update. That cannot
be demonstrated by a single install — a build that has only ever been installed once has
never tested the thing that breaks. So once there is a signed build, the sequence is:
install it, grant the microphone and accessibility, then install the *next* one and check
that Rich still hears you **without asking you for anything**.

There is a harness for it (`app/scripts/rebuild-survival.sh`) and it will do everything it
can automatically. It cannot see whether a permission dialog appeared on your screen. That
last part is you, and it takes about thirty seconds.

---

## What is still missing after these two tasks

Being honest about the queue rather than letting these two look like the finish line:

- **The app icon.** RichOS currently ships placeholder art, and the packaging script
  refuses to build at all until real artwork exists. That is a separate decision of yours.
- **Windows.** No certificate, and deliberately so — v1 is your Mac. Nothing here is
  wasted when Windows comes up; it is a different vendor and a different purchase.
