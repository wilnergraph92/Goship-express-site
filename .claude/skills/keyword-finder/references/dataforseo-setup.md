# DataForSEO: Click By Click

Optional and paid, on their own account. It adds real search volumes and a list of what a rival ranks for. **It is the only route in this pack to the searches competitors win.** Without it you see the pages rivals have, not the searches they rank for. Even with it, the list is DataForSEO's estimate of what it has seen, not everything, because nobody can see inside a rival's Search Console.

Checked November 2026:
- Sign in details: https://docs.dataforseo.com/v3/auth/
- Prices and top up: https://dataforseo.com/pricing
- Search volume price: https://dataforseo.com/pricing/keywords-data/google-ads
- Rival keyword price: https://dataforseo.com/pricing/dataforseo-labs/dataforseo-google-api

**Prices.** Pay as you go with no subscription. New accounts get a $1 trial credit. The smallest top up is $50, and it does not expire. Search volumes cost $0.09 per request of up to 1,000 searches. Rival keywords and ideas cost $0.012 per request plus $0.00012 per row, so 200 rows costs $0.036. The script always shows the most a run can cost, and it refuses to pass the cap for that run or the monthly ceiling in step 3.

For Claude: one step per message, wait for "done".

1. Go to https://app.dataforseo.com/register and make a free account. Confirm the email.
2. Go to https://app.dataforseo.com/api-access. This page shows an API login, which is their email, and an API password. The API password is made for them and is not the password they just chose. DataForSEO shows it for the first 24 hours after sign up. After that it is hidden, and a **Send by e-mail** button sends it to them.
3. Run `setup_state.py keys-file` from the `seo` skill and give them the line it prints to open the file. They remove the `#` from these two lines, fill them in and save. Not in the chat.

```
DATAFORSEO_LOGIN=the email they signed up with
DATAFORSEO_PASSWORD=the API password from step 2
DATAFORSEO_MAX_USD=2
```

That last line is the most this computer may spend in a calendar month. They pick the number. No run and no option can go past it, and nothing can be bought until it is there. Claude does not set it.

4. Prove it. This call is free and shows their balance:

```
<python> <this skill's folder>/scripts/keywords.py check
```

5. Start with the trial credit. A rival list of 200 rows costs under 4 cents, so $1 goes a fair way. Top up only if they want more: billing is in the same dashboard. Ask what they see there, and do not guess at the screen.
