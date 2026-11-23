# Instantly: Account, Mailboxes And API Key

Full tier. Steps checked November 2026. Help pages: https://developer.instantly.ai/quickstart , and the article "How to Add and Use Variables in Campaigns" at https://help.instantly.ai . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

`<python>` and `<scripts>` mean the same as in the skill. `<finder-scripts>` is the `scripts` folder of the `lead-finder` skill.

## What It Costs

Read November 2026 at https://instantly.ai/pricing :

- **Growth:** $47 a month. 5,000 emails and 1,000 uploaded contacts a month, unlimited sending mailboxes and warmup. Enough for about 1,000 leads a month.
- **Hypergrowth:** $107 a month. 125,000 emails and 25,000 uploaded contacts.
- Every plan includes API access, which this skill uses. A 14 day free trial needs no card and includes 250 contacts and 1,000 emails.
- Mailboxes to send from: their own Google or Microsoft mailboxes connected to Instantly, or ones bought through Instantly: a domain is $15 a year, a done-for-you Google mailbox $5 a month, a pre-warmed one $10 a month.

New mailboxes should warm up before a campaign, which Instantly does for them. Ask Instantly's help how long; it varies.

## 1. Make The Account

Send them to https://app.instantly.ai/auth/signup . Done means they see the Instantly dashboard.

## 2. Connect Or Buy A Mailbox To Send From

Recommended: a mailbox on a separate domain, not the one they run the business on (see `sending-domain.md`). In Instantly, open **Email Accounts** and click **Add New**. They can connect a Google or Microsoft mailbox they own, or buy a done-for-you one there. Have them turn warmup on for it. Done means the mailbox shows in the list.

## 3. Pick The Plan

In Instantly, open **Settings**, then **Billing**, and choose **Growth** under Outreach, unless they expect more than 1,000 leads a month. The API needs a paid plan or the trial.

## 4. Make The API Key

Open **Settings**, **Integrations**, **API Keys**, or go to https://app.instantly.ai/app/settings/integrations . Create an API v2 key, named lead-finder. For scopes, pick the ones for accounts, campaigns, leads and block list entries, or all scopes. Copy it when it is shown, because Instantly shows it once. Do not paste it into this chat.

## 5. Put It In The Key File

```
<python> <finder-scripts>/setup_check.py keyfile --add INSTANTLY_API_KEY --open
```

They paste the key right after `INSTANTLY_API_KEY=` with no spaces, save and close.

## 6. Prove It Works

```
<python> <scripts>/instantly_send.py check
<python> <finder-scripts>/setup_check.py mark instantly done
```

The right result says the key works and lists their sending mailboxes. If it lists none, go back to step 2.

## What Changes When Instantly Sends

The owner still approves each batch with their code, and `instantly_send.py push` refuses anything unapproved, changed or missing the opt-out line, postal address or an honest subject. After the push, Instantly does the sending: its schedule, its daily limit, its reply handling. The stop list is copied to Instantly's block list on every push, and with `suppress-sync`. If the owner edits the campaign inside Instantly, adds follow-ups or turns tracking on, the same laws apply, and they are responsible for that. Replies arrive in Instantly's Unibox.

**If they skip it:** say "No problem. I send from your own mailbox instead, 25 a day by default, or write drafts you send by hand."
