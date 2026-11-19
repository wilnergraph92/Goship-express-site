# Google Search Console: Click By Click

Checked November 2026 against Google's help pages:
- Adding a site: https://support.google.com/webmasters/answer/34592
- Proving it is yours: https://support.google.com/webmasters/answer/9008080
- Exporting: the page "Export data directly from a Search Console report" at https://support.google.com/webmasters

For Claude: give one step per message and wait for "done". Say what the screen should show. If a button has moved, ask what they see and work it out with them, or read the help pages above.

Search Console is Google's free record of how a site shows up in search. It is the single biggest upgrade to this skill, because it turns "here are your faults" into "here is what each fix is worth".

## First: They May Already Have It

1. Go to https://search.google.com/search-console and sign in with the Google account they use for the business.
2. If it shows a dropdown at the top left with their site in it, they have it. Skip to **The Export** below. A web designer may also have set it up under another account, so ask: "Did someone build your site for you?" If yes, they can ask that person to add them. Google calls this granting access to the property.
3. If it shows a welcome screen asking them to add a site, they do not have it yet. Carry on.

## Adding The Site

Google calls a site a "property". The welcome screen shows two choices: **Domain** and **URL prefix**. (If they already have another site, open the dropdown at the top left and choose **+ Add property**. If it asks what kind, choose **Website property**.)

Pick for them from these:

- **Their site builder has its own way:** use that (see **Site Builders** below). Fastest.
- **They can log in where they bought their domain:** **Domain**. It covers every version of the address, with or without www. It is the better one.
- **Neither:** **URL prefix**, typing the address exactly as it appears in the browser, with the `https://`.

Adding the site does not change anything on it, and they can stop and come back. Google says a half finished setup will not hurt the site.

## Proving It Is Theirs

**Domain (a DNS record).**

1. Type the address with no `https://` and no `www`, like `example.com`, and click **Continue**.
2. Google shows a line starting `google-site-verification=` and a **Copy** button. Click Copy. If Google lists their domain company with a **Start verification** button, use that: they log in and it does the rest.
3. Ask where they bought the domain, if they are not sure. In another tab, log in there and find the settings called **DNS**, **DNS records** or **Manage DNS**. Look up that company's own steps with a web search if the screen is not clear.
4. Add a new record. Type: **TXT**. Name or Host: leave blank or type `@`, whichever the screen asks for. Value: paste the copied line. Save.
5. Back in Search Console, click **Verify**. Google says a new record can take up to two or three days to work. If it fails, nothing is wrong. Come back in a day and click **Verify** again. Tell them not to delete the record later, because they stay verified only while it is there.

**URL prefix.** Type the full address and click **Continue**. Google lists ways to prove it. In order of ease:

- **Google Analytics:** one click on **Verify** if the site already has Analytics and they use the same Google account with edit rights.
- **Google Tag Manager:** same idea, if they have it.
- **HTML tag:** copy the line Google shows, paste it inside the site's `<head>` section, publish, and click **Verify**. Site builders usually have a box for this. If their site is in a folder Claude can reach, this is a change to the site, so show it and get a yes first.
- **HTML file:** download the file Google gives them, put it in the top folder of the site without changing it, and click **Verify**.

## Site Builders

Google says to check the builder's own help first. Checked November 2026:

- **WordPress:** Google's own Site Kit plugin handles it. https://sitekit.withgoogle.com/
- **Wix:** the SEO Setup Checklist can connect it for you, or use the HTML tag route. Wix help page "Verifying Your Site with Google Search Console" at https://support.wix.com
- **Squarespace:** open Analytics, click Search keywords, click Connect, sign in to Google, click Allow, then wait 72 hours. Squarespace help page "Verifying your site with Google Search Console" at https://support.squarespace.com
- **Shopify:** URL prefix, HTML tag, then paste the tag into the theme's `theme.liquid` file and click Verify. https://help.shopify.com/en/manual/promoting-marketing/seo/find-site-map
- **Anything else:** search the web for that builder's name plus "Search Console verification", read the page, and turn it into steps.

## How Long Until There Are Numbers

Google says it starts collecting as soon as the site is added, even before it is verified, and that it takes a few days for data to appear. So:

- **If they just added the site:** say it plainly: "Google needs a few days. There is nothing more to do today. Come back in 3 days and say add Search Console." Record it with `setup_state.py mark search_console later --days 3`. Then carry on and give them today's report without it.
- **If there is still no data after several days:** Google says the site may not have been seen in search yet, or the wrong address was added, like http instead of https. Check which it is.

## The Export

1. Go to https://search.google.com/search-console and pick the site from the dropdown at the top left.
2. In the left menu click **Performance**, then **Search results**. A chart appears with clicks and impressions.
3. Near the top, click the **Date** filter and pick **Last 3 months**. A longer range is fine. Remember which one.
4. Click **Export** at the top right, then **Download CSV**. Not Google Sheets and not Excel.
5. A zip file lands in their Downloads folder. Do not unzip it. Drag it into the chat.

What this route cannot give them:

- It stops at 1,000 rows of searches and 1,000 rows of pages, per Google's own limit.
- It lists searches and pages separately, so Claude matches them by words, and the report says when that is a guess.

For more rows and exact matching, see `google-sign-in.md`.
