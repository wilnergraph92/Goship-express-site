# Google Places Key: Click By Click

For the Full version. It gives the review count, the rating and up to 5 recent reviews for the owner and for each competitor Google's AI names, straight from Google. Without it, the owner reads their own numbers off their profile, and competitors' numbers come from the map results the answer reader returns (DataForSEO includes them; SerpApi usually does).

Checked November 2026:
- Getting a key: https://developers.google.com/maps/documentation/places/web-service/get-api-key . It needs a Google Cloud project with billing turned on, which means a card on file.
- Price: https://developers.google.com/maps/billing-and-pricing/pricing . A lookup with reviews is billed as Text Search Enterprise + Atmosphere: the first 1,000 a month are free, then $40 per 1,000.
- Fields: https://developers.google.com/maps/documentation/places/web-service/data-fields . At most 5 reviews come back per place, picked by relevance.

**What it costs in practice.** One lookup per business: the owner plus up to 11 competitors is 12 lookups a run. The key file line `PLACES_MAX_CALLS=900` stops this computer at 900 a month, under Google's free 1,000, so a slip costs nothing. Only the owner raises it.

For Claude: one step per message, wait for "done". If a screen looks different, ask what they see.

1. Go to https://console.cloud.google.com and sign in. If this is their first time, Google asks them to agree to terms. Make a project: click the project picker at the top, **New project**, name it anything, **Create**, then pick it.
2. Turn on billing: go to https://console.cloud.google.com/billing , link a billing account to this project, or create one with **Manage billing accounts**. Say plainly: this needs a card, and the line in step 5 keeps use inside the free amount.
3. Turn on the API: go to https://console.cloud.google.com/apis/library/places.googleapis.com and click **Enable**. It is called **Places API (New)**.
4. Make the key: open **Google Maps Platform**, then **Keys & Credentials**, click **Create credentials**, then **API key**. In **Select API restrictions**, choose **Places API (New)** only. Click **Create**, and keep the key on screen.
5. Run `setup_state.py keys-file` and give them the line it prints to open the file. They remove the `#` from these two lines, fill in the key, and save. Not in the chat.

```
GOOGLE_PLACES_KEY=the key from step 4
PLACES_MAX_CALLS=900
```

6. Optional and wise: set a budget alert in Google Cloud Billing, under **Budgets and alerts**, at $1. Google emails them if anything is ever charged.
7. Prove it. This lookup asks only for place IDs, which Google does not charge for:

```
<python> <this skill's folder>/scripts/places.py check
```

If the key lands in the chat, tell them to delete it in **Keys & Credentials** and make a new one.
