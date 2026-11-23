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

## Their Spending Ceiling

Nothing they run through this can cost more than $5 per run unless they say so. To change that, they add one line to the key file themselves, such as `APIFY_MAX_USD=20`. You never edit that line, and no flag goes past it.

## What It Costs

The free plan includes $5 of usage a month with no card, and blocks runs when that is used up until the next month. A paid plan starts at $19 a month, and they do not need one to start. https://apify.com/pricing
