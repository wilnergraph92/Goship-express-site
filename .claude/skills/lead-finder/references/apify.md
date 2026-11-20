# Apify: Account And Token

Steps checked November 2026. Help page: https://docs.apify.com/platform/integrations/api . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

`<python>` and `<scripts>` mean the same as in the skill.

## 1. Make The Account

Send them to https://console.apify.com/sign-up . They should see a sign-up form. They can use email or a Google account. Apify says no credit card is needed for the free plan. If it asks them to confirm their email, they do that first.

Done means they can see the Apify Console, with a menu down the left side.

## 2. Copy The Token

In the left menu, click **Settings**, then **API & Integrations**. The direct link is https://console.apify.com/settings/integrations .

They should see a list of personal API tokens, usually one called Default. Click the copy icon beside it. Do not paste it into this chat.

## 3. Put It In The Key File

```
<python> <scripts>/setup_check.py keyfile --add APIFY_TOKEN --open
```

That opens the file in their text editor, and prints how to open it if it could not. They paste the token right after `APIFY_TOKEN=` with no spaces, save and close.

## 4. Prove It Works

```
<python> <scripts>/apify_run.py check
```

The right result says the token works and names their account and plan. This spends nothing. Then:

```
<python> <scripts>/setup_check.py mark apify done
```

If it says Apify rejected the token, they copied it wrong, so go back to step 2. If it says it could not reach Apify, check their internet connection and try again.

## 5. Set A Monthly Limit In Apify Itself

Recommended. Everything this skill does is a check it runs on itself. The one limit nothing here can get around is the one Apify enforces. Send them to https://console.apify.com/billing#/limits and have them set a monthly usage limit they are comfortable with. On the free plan, Apify already stops runs when the $5 of monthly credit is used.

## 6. Full Tier: A Paid Plan

The full tier needs a paid plan: X only runs on one, the Facebook keyword search returns at most 100 posts per search on the free plan, and a run of a few thousand results costs more than the free $5 a month. Starter is $19 a month and includes $19 of usage, then pay as you go (https://apify.com/pricing).

In the Apify Console, click **Billing** in the left menu, then the subscription tab, or go straight to https://console.apify.com/billing#/subscription . They should see the plans side by side. Click **Choose plan** under Starter and follow the payment screen. Then:

```
<python> <scripts>/apify_run.py check
<python> <scripts>/setup_check.py mark apify-paid done
```

`check` should now name a paid plan.

## 7. Full Tier: Their Run Ceiling

Nothing here can cost more than $5 per run unless they say so. For the full tier, ask how much one run may cost at most, say $25, and have them add that one line to the key file themselves:

```
<python> <scripts>/setup_check.py keyfile --add APIFY_MAX_USD --open
```

They type the number after `APIFY_MAX_USD=`, with no dollar sign, save and close. You never edit that line, and no flag goes past it. Then go back to step 5 and make sure the monthly limit in Apify is set too: that is the lock, and this line is a check.

## Their Spending Ceiling

Nothing they run through this can cost more than $5 per run unless they say so. To change that, they add one line to the key file themselves, such as `APIFY_MAX_USD=20`. You never edit that line, and no flag goes past it.

## What It Costs

The free plan includes $5 of usage a month with no card, and blocks runs when that is used up until the next month. The Starter plan is $19 a month and includes $19 of usage. https://apify.com/pricing

**X (Twitter) needs a paid plan.** Its actor's maker lets free accounts run it only in a small demo mode, and not through the API this skill uses. Every other platform here works on the free plan, with the Facebook keyword search held to 100 posts per search. Say this before they pick X.
