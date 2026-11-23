# Email Verifier And Dedicated Sender

The verifier is optional. Instantly is part of the full tier. Steps checked November 2026.

## An Email Verifier: NeverBounce

**What bounces cost them.** An email to a dead address bounces. Mail providers read many bounces as a sign of a bought or scraped list, and that can get a mailbox throttled or blocked. Deliverability vendors put the warning line at about 2% (https://www.warmy.io/blog/email-sender-reputation-score/), and one reports an average of 7.5% on cold lists (https://www.warmforge.ai/blog/email-deliverability-statistics). Those are vendors' numbers, not Google's, and nothing here measured them.

**Cost:** $0.008 an email for up to 10,000, so 100 addresses is about $0.80: https://www.neverbounce.com/pricing

**Steps,** one per message, and wait for "done":

1. Make an account at https://app.neverbounce.com/register .
2. Go to https://app.neverbounce.com/clean and upload `lead-list.csv`. If it asks which column holds the email, choose `email`.
3. When it finishes, download the results as a CSV into the same folder, and tell me its name.
4. Read that file. NeverBounce marks each address Valid, Invalid, Accept All or Unknown: https://www.neverbounce.com/help/result-codes . Add every Invalid one to the suppression list with `send_queue.py suppress`. Tell them how many went. Accept All can still bounce, so leave those for them to decide.

Then:

```
<python> <finder-scripts>/setup_check.py mark verifier done
```

**If they skip it:** say "No problem. Keep the first batch small and watch for bounce emails in your inbox." The send script only sees refusals during sending. A bounce that comes back later lands in their inbox, so when they tell me about one, add it to the suppression list.

## A Dedicated Cold Email Sender: Instantly

On the full tier, Instantly sends the campaign for you, and this skill hands it each approved batch through Instantly's API, with the approval, the refusals and the stop list still checked in code. The steps and prices are in `instantly.md` beside this file.
