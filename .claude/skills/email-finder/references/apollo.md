# Apollo: Account, Plan And Key

Full tier. Steps checked November 2026. Help pages: https://docs.apollo.io/docs/create-api-key and https://docs.apollo.io/docs/api-pricing . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

`<python>` and `<scripts>` mean the same as in the skill. `<finder-scripts>` is the `scripts` folder of the `lead-finder` skill.

## What It Costs

Read November 2026 at https://www.apollo.io/pricing :

- **Free:** $0, 900 credits a year given monthly (75 a month), API access. Apollo's docs say a free account needs to be registered with a work email address to use people enrichment.
- **Basic:** $49 a seat a month billed yearly, with 30,000 credits a year given up front, and API enrichment. Several third-party price guides list monthly billing at $65 a month; the toggle on Apollo's page shows the current figure.
- **Professional:** $79 a seat a month billed yearly, 48,000 credits a year.

Each person Apollo finds an email or other data for uses 1 credit; no match uses 0. Phone numbers cost 8 credits each and this skill never asks for them. So 1,000 lookups use at most 1,000 credits: more than the free plan gives in a year, and a small part of Basic.

Rate limits on the enrichment endpoints: the free plan allows 20 bulk calls a minute (each call is up to 10 people) and 600 a day; paid plans allow 1,000 a minute with no daily limit (https://docs.apollo.io/reference/rate-limits). The script pauses between calls to stay under the free plan's limit.

## 1. Make The Account

Send them to https://www.apollo.io and have them sign up, with their work email address. Done means they see the Apollo home screen.

## 2. Pick The Plan

For more than about 75 lookups a month, they need a paid plan. In Apollo, open **Settings**, then the plans page, or go to https://app.apollo.io/#/settings/plans/upgrade . Basic is enough for this skill. Skip it to stay on the free plan and look up a few dozen people a month.

## 3. Make The Key

In Apollo, open **Settings**, **Integrations**, **API Keys**, or go to https://developer.apollo.io/#/keys . Click **Create new key**. Name it lead-finder. Tick **People Enrichment** and **Bulk People Enrichment**, which are all this skill uses. They can leave **Set as master key** off. Choose **Private** as the integration type, click **Create API key**, then **Copy**. Do not paste it into this chat.

## 4. Put It In The Key File

```
<python> <finder-scripts>/setup_check.py keyfile --add APOLLO_API_KEY --open
```

They paste the key right after `APOLLO_API_KEY=` with no spaces. While the file is open, ask how many credits one lookup may use at most, and have them add a line such as `APOLLO_MAX_CREDITS=1000`. With no line, the limit is 100. You never edit that line. Save and close.

## 5. Prove It Works

```
<python> <scripts>/apollo_match.py check
<python> <finder-scripts>/setup_check.py mark apollo done
```

`check` calls Apollo's health check, which uses no credits. If it says the key cannot use people enrichment, go back to step 3 and tick both boxes.

**If they skip it:** say "No problem. You get the emails people published themselves, and most leads without a website stay blank."
