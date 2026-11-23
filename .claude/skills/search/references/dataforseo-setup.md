# DataForSEO: Click By Click

For the Full version, as the answer reader instead of SerpApi. It reads Google's real AI Overview and AI Mode answers, plus the map results with each business's rating and review count, pay as you go. Pick SerpApi or DataForSEO, not both.

Checked November 2026:
- Prices and top up: https://dataforseo.com/pricing . $1 trial credit for new accounts. Smallest top up $50, and the balance does not expire.
- AI Overviews come with the normal Google results: https://dataforseo.com/pricing/serp/google-organic-serp-api . Live mode $0.002 a search, plus $0.002 to load an AI Overview that Google builds after the page loads (refunded when there is none). So up to $0.004 a question.
- AI Mode: https://dataforseo.com/pricing/serp/google-ai-mode-serp-api . Live mode $0.004 a question.
- The fields read: https://docs.dataforseo.com/v3/serp/google/organic/live/advanced/ and https://docs.dataforseo.com/v3/serp/google/ai_mode/live/advanced/
- Sign in details: https://docs.dataforseo.com/v3/auth/

**What it costs in practice.** 20 questions, both kinds of answer: at most $0.16. A re-check of the same 20 later: the same again. The $1 trial covers several runs.

For Claude: one step per message, wait for "done".

1. Go to https://app.dataforseo.com/register and make a free account. Confirm the email.
2. Go to https://app.dataforseo.com/api-access . It shows an API login, which is their email, and an API password. The API password is made for them and is not the password they chose. It shows for the first 24 hours after sign up; after that a **Send by e-mail** button sends it.
3. Run `setup_state.py keys-file` and give them the line it prints to open the file. They remove the `#` from these three lines, fill them in and save. Not in the chat.

```
DATAFORSEO_LOGIN=the email they signed up with
DATAFORSEO_PASSWORD=the API password from step 2
DATAFORSEO_MAX_USD=2
```

The last line is the most this computer may spend there in a calendar month. They pick the number. No run and no option goes past it, and nothing is bought until it is there. Claude does not set it.

4. Prove it. This call is free and shows the balance:

```
<python> <this skill's folder>/scripts/answers.py check --provider dataforseo
```

5. Start on the trial credit. Top up only if they want more, in the same dashboard. Ask what they see there; do not guess at the screen.
