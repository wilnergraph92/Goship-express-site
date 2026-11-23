# SerpApi: Click By Click

Recommended for the Basic version. It reads Google's real AI Overview and AI Mode answers for the owner's questions, on their own account. Without it (and without DataForSEO), Claude cannot see those answers: its own web search does not show Google's AI box. The owner would then search a few questions by hand and paste what they see.

Checked November 2026:
- Plans: https://serpapi.com/pricing . Free: 250 searches a month, 50 an hour. Starter: $25 a month for 1,000. Developer: $75 a month for 5,000.
- AI Overviews: https://serpapi.com/ai-overview . Shown mostly for English searches in a limited set of countries. Sometimes Google needs a second request to get the AI Overview, which is a second search.
- AI Mode: https://serpapi.com/google-ai-mode-api
- What counts: https://serpapi.com/faq/general/do-you-charge-for-cached-searches . Only successful searches count. Cached repeats of the same search within an hour are free.
- Account check: https://serpapi.com/account-api

**How far the free plan goes.** Each question uses up to 3 searches: 1 or 2 for the AI Overview and 1 for AI Mode. So 250 a month covers about 80 question reads: a first run of 20 questions and a few re-checks. `answers.py estimate` shows the most a run can use before anything runs.

For Claude: one step per message, wait for "done". If a screen looks different, ask what they see.

1. Go to https://serpapi.com/users/sign_up and make a free account. They can sign in with Google. Confirm the email if asked, and verify the phone number if it asks.
2. Once signed in, go to https://serpapi.com/manage-api-key . The page shows **Your Private API Key**. Keep it open.
3. Run `setup_state.py keys-file` and give them the line it prints to open the file. They remove the `#` from these two lines, paste the key after the first `=`, and save. Not in the chat.

```
SERPAPI_KEY=the private API key from step 2
SERPAPI_MAX_SEARCHES=250
```

The second line is the most this computer will use in a calendar month. 250 matches the free plan. If they pay for a bigger plan, they raise it themselves.

4. Prove it:

```
<python> <this skill's folder>/scripts/answers.py check --provider serpapi
```

It names the plan and the searches left. It reads their account, not Google, so it runs no search.

If the key ever lands in the chat, tell them to replace it: ask what they see on that same page for making a new key, and if there is no way there, to contact SerpApi. Then the new key goes in the file.
