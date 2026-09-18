# RichOS on your phone

**Purely optional.** RichOS runs completely on one Mac in your office. Nothing here is needed for that,
in the same way that syncing a second Mac through GitHub is optional.

**What a mobile app is, here:** an app that lets you use RichOS while you are on the go and away from
the office, outside your home network. Inside your home network the desktop app is the better tool.

Native mobile apps for iOS and Android are coming soon.

Until then, the web app can already be used for talking to Rich from your phone. It has similar looks
and functionality to a native mobile app: open it once, add it to your home screen, and it runs like an
app.

**The web app lives here: [`richos/web/web-app`](../web/web-app/).** Its README explains how to pair
your phone with RichOS on your Mac.

**Reaching your Mac from outside the office** takes one of two paths:

- **Technical users:** your own Tailscale account on the Mac and on the phone. RichOS guides you
  through it with simple how-to screens in the app. Full setup and troubleshooting, including the one
  thing that trips up almost everybody: [**Tailscale setup and
  troubleshooting**](./TAILSCALE-SETUP-AND-TROUBLESHOOTING.md).
- **Everyone else:** a hosted relay, coming later.

The web app ships inside RichOS on your Mac and talks only to it. There is no server of ours in
between today, nothing to sign up for with us, and nothing to pay us for.
