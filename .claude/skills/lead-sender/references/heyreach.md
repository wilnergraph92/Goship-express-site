# HeyReach: LinkedIn Messages

Full tier, optional. Steps checked November 2026. Help pages: https://docs.heyreach.io/hey-reach-api and https://help.heyreach.io . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

`<python>` and `<scripts>` mean the same as in the skill. `<finder-scripts>` is the `scripts` folder of the `lead-finder` skill.

## Say This First

HeyReach sends connection requests and messages from their own LinkedIn account. LinkedIn's help page on prohibited software says members may not use bots or other unauthorized automated methods to send messages (https://www.linkedin.com/help/linkedin/answer/a1341387). So using it can get their LinkedIn account restricted. Many businesses use it anyway; it is their call. If they say no, skip this and LinkedIn leads get an email only when one was found.

## What It Costs

Read November 2026 at https://www.heyreach.io/pricing : Growth is $79 a month per LinkedIn sender, with API and webhooks included, and a free trial. HeyReach allows up to 40 connection requests a day and 200 a week per sender (the article "How do Connection Request Limits Work in HeyReach?" at https://help.heyreach.io), so 1,000 LinkedIn leads take about five weeks on one sender.

## 1. Make The Account And Connect LinkedIn

Send them to https://app.heyreach.io/account/register . Then, in HeyReach, open the LinkedIn accounts page and add their LinkedIn account, following HeyReach's own screens. They log in to LinkedIn inside HeyReach themselves. Never ask for their LinkedIn password, and never log in for them.

## 2. Build The Campaign In HeyReach

In HeyReach, create a campaign with their LinkedIn account as the sender. In the sequence, a connection request (a short note without variables, or no note), then a message step. In the message step, click **Add variables** and insert the custom variable named exactly `personal_message`, and nothing else, because each lead's whole message, opt-out line and address included, is already in it. Set the fallback message to something plain, or have it skip the lead. Save it without starting it. Then:

```
<python> <scripts>/heyreach_send.py campaigns
<python> <scripts>/heyreach_send.py accounts
```

Note the campaign id and the LinkedIn account id.

## 3. Get The API Key

In HeyReach, open **Integrations**, **HeyReach API**, then **Get API Key**, or go to https://app.heyreach.io/app/integrations/public-api/api . Click the copy icon. Do not paste it into this chat.

## 4. Put It In The Key File

```
<python> <finder-scripts>/setup_check.py keyfile --add HEYREACH_API_KEY --open
```

They paste the key right after `HEYREACH_API_KEY=` with no spaces, save and close.

## 5. Prove It Works

```
<python> <scripts>/heyreach_send.py check
<python> <finder-scripts>/setup_check.py mark heyreach done
```

**If they skip it:** say "No problem. LinkedIn leads get an email only if one is found."
