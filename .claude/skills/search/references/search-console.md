# Google Search Console: Click By Click

Free, for both versions. It is Google's own record of the site, and since August 31, 2026 it has a **Generative AI performance report**: how often links to the site were shown inside AI Overviews and AI Mode. That is the one number from Google itself for before and after. It also holds the real searches people used to find the site, which make the best customer questions.

Checked November 2026:
- The Generative AI report: Google's help page "Generative AI performance report (Search)", at https://support.google.com/webmasters . It counts impressions (times a link to the site was shown) by page, country, device and date, and has an export button.
- The setting that must say Include: Google's help page "Search generative AI control", at https://support.google.com/webmasters (Settings, Search generative AI). Include is the default.
- Adding a site: https://support.google.com/webmasters/answer/34592 ; proving it is theirs: https://support.google.com/webmasters/answer/9008080
- Google counts AI answers inside the normal Web numbers too: https://developers.google.com/search/docs/appearance/ai-features

For Claude: one step per message, wait for "done". If a button has moved, ask what they see.

## First: They May Already Have It

1. Go to https://search.google.com/search-console and sign in with the Google account they use for the business.
2. A dropdown at the top left with their site in it means they have it: go to **The Setting**. If a web designer built the site, ask them to add the owner as a user.
3. A welcome screen asking them to add a site means they do not have it yet: go to **Adding The Site**.

## Adding The Site

Two choices show: **Domain** and **URL prefix**.

- **If their site builder has its own way to connect Search Console** (WordPress with Google's Site Kit plugin, Wix's SEO setup checklist, Squarespace's Search keywords panel), use that. Look up the builder's current help page with your web search and turn it into clicks.
- **If they can log in where they bought the domain:** **Domain**. Type the address with no `https://` and no `www`, click **Continue**, copy the line starting `google-site-verification=`, add it as a **TXT** record in that company's DNS settings (Name or Host blank or `@`), save, and click **Verify**. A new record can take a day or more to work: if Verify fails, come back tomorrow.
- **Otherwise:** **URL prefix**, with the full address, and the easiest proof Google lists: Google Analytics if they have it, otherwise the HTML tag in the site's head section (a change to the site, so show it and get a yes first).

Then say plainly: Google needs a few days to collect numbers, there is nothing more to do today, and today's check runs without it. Run `setup_state.py mark search_console later --days 7 --note "added the site"`. The Generative AI report also needs enough AI answer impressions before it shows anything.

## The Setting

1. In Search Console, click **Settings** at the bottom of the left menu, then **Search generative AI**, or go straight to https://search.google.com/search-console/settings/search-gen-ai .
2. It should say **Include my site's links and content in Search generative AI features**. If it says **Exclude**, the site cannot appear in AI Overviews or AI Mode at all, whatever else is fixed. Ask whether someone chose that on purpose before changing it; Google says a change takes a few days.
3. Run `setup_state.py mark search_console done --note "AI setting: Include"` (or what it said).

## The Generative AI Report Export

1. Open https://search.google.com/search-console/performance/search-analytics/ai and pick the site.
2. Set the date range to the last 3 months, or the weeks before the fixes when this is the before picture.
3. Click **Export** and download the file. Do not unzip it. Drag it into the chat. Save it in the work folder as `search-console-ai-before.zip` (later, `search-console-ai-after.zip`).
4. If the page says there is no report, the site has not had enough impressions in AI answers yet, or the setting above says Exclude. That is a finding, not a failure: say so and carry on.

The format of this export was not checked against a real download when this file was written, so the reader finds the columns by name and says what it found. If it cannot read the file, ask them to read the total impressions off the chart instead, and write it down with the dates.

## The Searches People Use

1. In the left menu click **Performance**, then **Search results**. Set the date to the last 3 months.
2. Click the **Queries** tab under the chart. Ask them to copy the searches that read like questions or that name a service, or click **Export**, **Download CSV**, and drag the zip in. Use these as the first source for the customer questions.
