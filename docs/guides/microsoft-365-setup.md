<!-- STAGED FILE — ITS HOME IS `richos-hq/docs/guides/microsoft-365-setup.md`, BESIDE THE GOOGLE
     GUIDE. It is committed here only because this teammate was given a workspace in `richos` and
     none in `richos-hq`; the two guides must not end up living in two repositories. MOVE it, do not
     copy it. Escalation: esc-20260917T014803Z-562c65cd. -->

# RichOS — Microsoft 365 setup (the CEO's one-time step)

**Audience:** you (or whoever administers your Microsoft 365 tenant).
**Why:** RichOS reads *your own* Outlook calendar, OneDrive and mailbox to build loro's memory — the
meetings decisions can be anchored to ("that came out of your 12 Aug leadership meeting"), the
documents those decisions changed, and the correspondence around both. This is the human prerequisite
that unlocks the live end-to-end; until it's done, the Microsoft layer runs green in tests against a
**mock** Graph API but cannot pull anything of yours.

**This is the alternative to the Google setup, not an addition to it.** RichOS is vendor-agnostic by
design: one core, one governance layer, one memory pipeline, and an adapter set per vendor. Connect
Google, or Microsoft, or both. Nothing below changes anything about an existing Google connection.

**The privacy promise this setup preserves (why it's built this way):** the app you register below
belongs to **you**, inside **your own** Entra ID tenant. RichOS ships *these instructions and a config
template* — never a bundled credential. Every API call then goes **your machine → your own Microsoft
cloud, directly**; no RichOS server is ever in the path, and your tokens live only in your Mac's
Keychain. The design this comes from is §1 of the Workspace/M365 source architecture, which lives in
the private record, not in this repository:
`richos-hq/docs/plans/richos-workspace-m365-source-architecture-2026-08-24.md`.

---

## What you'll end up with

- An **app registration** in your own Entra ID tenant, single-tenant.
- **Three read-only delegated permissions**, and no write permission of any kind.
- A **public client** — an *Application (client) ID*, and **no secret**.
- Your **Directory (tenant) ID**, which pins the sign-in to your own organization.

Total time: ~10 minutes. You need to be able to sign in to the Azure portal with your work account.
If your organization restricts app registrations, you may need an administrator for Step 5.

---

## Step 1 — Open the app registrations page

1. Go to <https://entra.microsoft.com/> and sign in with the **Microsoft 365 account whose calendar,
   files and mail you want RichOS to read**.
2. Left menu → **Applications → App registrations**.
3. Click **+ New registration**.

## Step 2 — Register the app

1. **Name:** `RichOS`.
2. **Supported account types:** choose the first option —
   **Accounts in this organizational directory only (single tenant)**.

   > This is the one that needs no Microsoft review of any kind. The app is usable only by people in
   > your own directory, which is exactly one person: you.
   >
   > *If you are using a personal Microsoft account rather than a business tenant,* choose
   > **Personal Microsoft accounts only** instead, and read the note at the bottom about mailboxes —
   > it is the one case that behaves differently.

3. **Redirect URI:** select platform **Public client/native (mobile & desktop)** and enter
   `http://127.0.0.1:53682/callback`.

   > Plain `http` on `127.0.0.1` is correct and deliberate here: this is the standard desktop
   > sign-in pattern, the address is your own machine, and the response never crosses a network. A
   > certificate for `127.0.0.1` would have to be self-signed and trusted machine-wide, which is
   > worse. RichOS refuses any redirect that is not loopback, and refuses a plain-`http` call to
   > anything else.

4. **Register.**

## Step 3 — Copy two IDs

On the app's **Overview** page, copy both of these. Neither is a secret, and RichOS needs both:

- **Application (client) ID** — a GUID.
- **Directory (tenant) ID** — a GUID. (You may use your verified domain, e.g.
  `yourcompany.onmicrosoft.com`, instead; either works.)

## Step 4 — Confirm it is a PUBLIC client (do not skip this)

1. Left menu → **Authentication**.
2. Scroll to **Advanced settings → Allow public client flows**.
3. Set it to **Yes**. **Save.**

> **This is the step that decides whether RichOS needs a secret, so it is worth thirty seconds.** A
> public client proves itself with PKCE — a one-time code RichOS generates on your machine and never
> transmits — instead of a stored password. A desktop app that holds a secret is holding a
> credential it cannot actually keep secret, which is why RichOS would rather not have one.
>
> **Do not create a client secret.** If you already did, delete it under **Certificates & secrets**.
> RichOS will refuse a secret it was not told to expect, and the refusal names what to do — so if
> your organization's policy genuinely requires a confidential app, nothing is stuck.

## Step 5 — Add the three read-only permissions

1. Left menu → **API permissions → + Add a permission → Microsoft Graph → Delegated permissions**.
2. Search for and tick exactly these three:

   | Permission | What RichOS reads with it |
   |---|---|
   | `Calendars.Read` | your meetings |
   | `Files.Read` | your OneDrive documents, and their text |
   | `Mail.ReadBasic` | who wrote to you, when, and about what — **not** the message bodies |

3. **Add permissions.**
4. If your tenant shows a **Grant admin consent for \<your org\>** button and you are an
   administrator, click it. If you are not, you can leave it: you will be asked to consent yourself
   when RichOS signs you in.

**Every one of them is read-only. There is no write permission on this list and RichOS has none:**
this layer observes your cloud, it never modifies it. No message is sent, no file is changed, no
meeting is created or moved.

**Why `Mail.ReadBasic` and not `Mail.Read`.** `Mail.ReadBasic` cannot return message bodies,
previews, or attachments — Microsoft enforces that at the permission itself, not in RichOS's code.
Participants, subjects and timing are enough for "who do I talk to, how often, about what", which is
the part of mail loro actually needs. If you later want RichOS to read message *bodies*, that is a
deliberate decision you make and re-consent to; it is not a setting anything can flip on your behalf.

`offline_access` is requested automatically and does not need adding here. It is what lets RichOS
stay signed in instead of asking you to sign in every hour.

---

## Step 6 — Give RichOS the two IDs and authorize

> **Not wired yet.** The `workspace connect microsoft` command is the one remaining piece; the
> adapters, the transport, the Entra sign-in and the permission wiring underneath it are built and
> tested. This section is written so that the moment that command lands, the steps above are already
> done and nothing here changes.

When it lands, it will be one command that takes the two IDs from Step 3, opens your browser once to
the Microsoft sign-in page, receives the response on `127.0.0.1`, and stores the result in your
Keychain. You will see a consent screen listing exactly the three read-only permissions from Step 5 —
**read it, and if it lists anything else, stop and say so.**

After that, `workspace status` will show what RichOS can see, and `workspace sync` will pull it.

---

## Things worth knowing afterwards

**Where your tokens live.** In your Mac's Keychain, under `com.richos.workspace.microsoft`, encrypted
at rest by macOS — never in a file in any RichOS folder. You can see the entry in Keychain Access.

**How to disconnect.** `workspace disconnect microsoft` deletes those tokens, and from that moment
this machine cannot read anything of yours. It will also tell you, plainly, that **the consent record
in your Microsoft account is still there** — Microsoft gives an app no way to revoke its own
permission. To finish the job, go to <https://myapps.microsoft.com/>, find **RichOS**, and remove it.
RichOS will never tell you it revoked something it could not revoke.

**If RichOS asks you to reauthorize.** Microsoft publishes no fixed lifetime for a desktop app's
sign-in — it depends on your organization's policies — so RichOS does not display a countdown it
would be guessing at. It asks you to sign in again when, and only when, Microsoft actually refuses,
and it shows you the `AADSTS…` code Microsoft gave so the reason is searchable.

**No mailbox?** Some accounts have no Exchange mailbox behind them — a personal Microsoft account, or
a work account without an Exchange Online license. RichOS treats that as a plain fact rather than an
error: calendar and files sync normally, mail is reported as *unavailable* with the reason, and it
starts working by itself if the account later gains a mailbox. You do not have to reconnect.

**Times.** RichOS pins every calendar time to UTC when it asks Microsoft for it, and converts using
your declared timezone. Changing your timezone in Outlook will not silently change what RichOS has
recorded about when a meeting happened.

**If you connect both Google and Microsoft,** they stay completely separate: separate consent,
separate Keychain entries, separate sync positions. Disconnecting one does nothing to the other.
