# FemcBoost

Written 2026-09-06 from the sources named at the bottom. **Not yet confirmed by him.**

## What it is

FemcBoost sells **Avelor**, a coaching platform. The customer is the fitness coach; the coach's
own clients are the people who use it day to day. So there are two audiences and only one of them
pays.

The coaches are women running their own coaching businesses. Their clients are men, roughly 30 to
45, who have been coached before and want the plan followed rather than explained.

The paid offer it is built around is a premium program: **$2,500, three months, ten pounds.**

## How the product is split

Two different people use two different things, and confusing them has cost real time:

- **Clients use the phone apps only** — Android and iPhone. They log food and weight, take
  progress photos, message their coach, and see their streaks and trophies.
- **Coaches use the web app only.** They review check-ins, reply to messages, adjust plans, and
  manage their roster.

There is no client web app. When someone is asked to "look at what the client sees," the answer
is a phone, never a browser.

An older product called fitapp is still around but is maintenance only. Nothing new is built
there.

## House rules

- **It is not white-label.** A coach gets her logo, her photo and her name on it. Nothing else
  changes per coach.
- **No page numbers, no paginated lists, anywhere.** Scrolling, always.
- **American English, and readable contrast in both light and dark mode.** These are floors, not
  preferences, and they apply to every screen and every piece of marketing.
- **A coach's client data is hers alone.** Nothing about one coach's clients may ever be visible
  to another. This is the rule the engineering treats as absolute.

## Words used here

- **Coach** — the paying customer. **Client** — the person she coaches.
- **Check-in** — the client's regular submission the coach reviews.
- **Pantry** — the coach's curated list of foods a client can log from.
- **Avelor** is the product; **FemcBoost** is the business. Both names are in use.

---

## Where these lines came from

| Claim | Source |
|---|---|
| Two audiences; coaches are the buyers | `femcboost/docs/research-role-marketing-director.md` |
| Female coaches; male clients 30-45 | same |
| $2,500 / 3 months / 10 lbs | the premium-program record |
| Clients native only, coaches web only, fitapp legacy | `femcboost/docs/surfaces.md` — the canonical map |
| Not white-label; logo, photo and name only | the white-label ruling |
| No pagination; American English; contrast floor | standing CEO rulings |
| One coach's data never visible to another | the tenant-isolation rule the backend enforces |

**Not from him, and still open:** whether "FemcBoost" or "Avelor" is the name he wants used when
talking to him about this; who the competition is; what he considers this business's one number.
These are interview questions and are deliberately left blank rather than guessed.
