# Anthropic API Key: For Profiles In Bulk

Optional. Steps checked November 2026. Help page: https://platform.claude.com/docs/en/get-started . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

**They do not need this.** Without it, Claude builds the same profiles in their session with parallel subagents, at no cost beyond their Claude plan. The key is for thousands of people at once, run on Anthropic's side so their session is free and their plan's usage is not spent. It is a separate, pay-as-you-go account from their Claude plan.

**What it costs:** the Message Batches API charges half the normal price per token. Per million tokens, read November 2026 at https://platform.claude.com/docs/en/about-claude/pricing : Claude Opus 5.5 $2 in and $10 out, Claude Sonnet 5.5 $1 in and $5 out, Claude Haiku 5.5 $0.05 in and $0.25 out. For 1,000 people that is roughly $6 on Opus 5.5 or $3 on Sonnet 5.5, by this skill's own estimate (about 40 requests of 25 people each), not yet measured on a real run. `profile_batches.py estimate` prints the likely and the highest cost for their real batches before anything is sent. Most batches finish within an hour; Anthropic allows up to 24.

`<python>` and `<scripts>` mean the same as in the skill.

## 1. Make The Account

Send them to https://platform.claude.com . They sign in or sign up; it is the Claude Console, separate from the Claude app. Done means they see the Console dashboard.

## 2. Add Credit

In the Console, open **Settings**, then **Billing**, and add a small amount of credit, for example $10. Pay-as-you-go accounts need credit before the API answers.

## 3. Set A Spend Limit In The Console

Recommended. In **Settings**, set a monthly spend limit for the workspace. That is the limit Anthropic enforces; everything this skill does is a check on itself. Help: https://platform.claude.com/docs/en/manage-claude/workspaces

## 4. Make The Key

Go to https://platform.claude.com/settings/keys and click the button to create a key. Name it something like lead-finder. Copy it when it is shown. Do not paste it into this chat.

## 5. Put It In The Key File

```
<python> <finder-scripts>/setup_check.py keyfile --add ANTHROPIC_API_KEY --open
```

`<finder-scripts>` is the `scripts` folder of the `lead-finder` skill. They paste the key right after `ANTHROPIC_API_KEY=` with no spaces, save and close. If they want a ceiling above $10 for one profile run, they add a line such as `ANTHROPIC_MAX_USD=25` themselves. You never edit that line.

## 6. Prove It Works

```
<python> <scripts>/profile_batches.py check
<python> <finder-scripts>/setup_check.py mark anthropic done
```

`check` reads the list of models, which costs nothing. The right result says the key works.

**If they skip it:** say "No problem. I build the profiles here with parallel helpers instead, which uses your Claude plan."
