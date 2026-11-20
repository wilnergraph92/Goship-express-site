# A Separate Sending Domain

Recommended, not required. Steps checked November 2026. One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

**Why:** if people mark cold email as spam, the domain it came from takes the damage, and that can pull down quotes and invoices sent from it. A second domain keeps that away from the one they run the business on. It lowers the risk. It does not remove it.

**Cost:** a .com at Porkbun is from $11.81 a year (https://porkbun.com/products/domains) and one Google Workspace Business Starter mailbox is from $7.00 a month (https://workspace.google.com/pricing). Prices change, so check the pages. These are only examples. Any registrar and any mailbox provider works, though the clicks below are for these two.

## 1. Buy The Domain

Pick a name close to their real one, such as their name plus "team" or "hq". Never a misspelling of someone else's brand. At https://porkbun.com , search for it, add it to the cart and check out.

## 2. Make The Mailbox

At https://workspace.google.com , click to get started, and when asked, say they already have a domain and enter the new one. Google walks them through proving they own it by adding a record, which is the same kind of step as below. Done means they can open Gmail as the new address.

## 3. Open The DNS Page

At Porkbun: **Domain Management**, then the **Details** drop-down on that domain, then the edit icon next to **DNS Records**. Help pages: https://kb.porkbun.com

## 4. Add SPF

This tells mail servers that Google may send for this domain. Add one record. Help page: https://knowledge.workspace.google.com/admin/security/set-up-spf

- **Type:** TXT
- **Host:** leave blank, or `@` if the page asks for something
- **Value:** `v=spf1 include:_spf.google.com ~all`

If a TXT record starting `v=spf1` is already there, do not add a second one. Tell me what it says.

## 5. Add DKIM

This signs each email so nobody can fake it. Help page: https://support.google.com/a/answer/174124

1. Go to the Google Admin console at https://admin.google.com . Open the menu, then **Apps**, **Google Workspace**, **Gmail**, then click **Authenticate email**.
2. In **Selected domain**, choose the new domain, click **Generate New Record**, then **Generate**. Keep the suggested settings.
3. Copy the two values it shows, and add them on the Porkbun DNS page as a new record: **Type** TXT, **Host** `google._domainkey`, **Value** the long text starting `v=DKIM1`.
4. Back in the Admin console, click **Start authentication**. If it gives an error, the record has not spread yet. Try again later.

## 6. Prove It Works

They send one normal email from the new address to a personal Gmail account they own. In that Gmail, open the message, click the three dots, then **Show original**. They should see PASS beside SPF and DKIM. Then:

```
<python> <finder-scripts>/setup_check.py mark domain done
```

Then go back to `mailbox.md` and make the app password for this new address.

## Start Slowly

A brand new domain has no reputation. Start with a few emails a day and lower `daily_cap` in `sender.json` for the first couple of weeks. That is common advice, not a published rule, and no number guarantees anything. Above 5,000 messages a day, Google also asks for DMARC and one-click unsubscribe: https://support.google.com/a/answer/81126 . This skill stops at 200 a day, so that does not apply here.
