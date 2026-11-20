# Email Verifier And Dedicated Sender

Both optional. Steps checked November 2026.

## An Email Verifier: NeverBounce

**What bounces cost them.** An email to a dead address bounces. Mail providers read many bounces as a sign of a bought or scraped list, and that can get a mailbox throttled or blocked. Deliverability vendors put the warning line at about 2% (https://www.warmy.io/blog/email-sender-reputation-score/), and one reports an average of 7.5% on cold lists (https://www.warmforge.ai/blog/email-deliverability-statistics). Those are vendors' numbers, not Google's, and nothing here measured them.

**Cost:** $0.008 an email for up to 10,000, so 100 addresses is about $0.80: https://www.neverbounce.com/pricing

**Steps,** one per message, and wait for "done":

1. Make an account at https://app.neverbounce.com/register .
2. Go to https://app.neverbounce.com/clean and upload `leads.csv`. If it asks which column holds the email, choose `email`.
3. When it finishes, download the results as a CSV into the same folder, and tell me its name.
4. Read that file. NeverBounce marks each address Valid, Invalid, Accept All or Unknown: https://www.neverbounce.com/help/result-codes . Add every Invalid one to the suppression list with `send_queue.py suppress`. Tell them how many went. Accept All can still bounce, so leave those for them to decide.

Then:

```
<python> <leads-scripts>/setup_check.py mark verifier done
```

**If they skip it:** say "No problem. Keep the first batch small and watch for bounce emails in your inbox." The send script only sees refusals during sending. A bounce that comes back later lands in their inbox, so when they tell me about one, add it to the suppression list.

## A Dedicated Cold Email Sender: Instantly

**They do not need this.** For up to a few dozen emails a day, their own mailbox and this skill are enough. It starts to make sense when they want several mailboxes, warmup and automatic follow-ups at volume.

**Cost:** the Growth plan is $47 a month, or $37.60 a month billed yearly, for 5,000 emails and 1,000 contacts a month: https://instantly.ai/pricing

**Tell them plainly what changes:** if they send through it, this skill's approval step, refusals, suppression list and daily cap do not apply, because the other tool does the sending. They are responsible for the same rules there. This skill can still write the emails and hand over `leads.csv`.

If they want it, look up Instantly's current help pages with your web search and walk them through it. Then:

```
<python> <leads-scripts>/setup_check.py mark sender done
```
