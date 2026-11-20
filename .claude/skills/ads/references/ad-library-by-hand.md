# The Meta Ad Library By Hand

The way to do this with no Apify and no cost. No Facebook login is needed to browse it. Steps checked November 2026 from two recent guides, since Meta's own help page gives no clicks: https://www.alenich.com/blog/meta-ads-library and https://www.addogs.ai/blog/meta-ad-library . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

## 1. Open It

Go to https://www.facebook.com/ads/library . There is a search bar with two menus beside it: one for country, one for ad category.

## 2. Set It Up

Pick the country they sell in. Results depend on it, and a brand can look quiet in one country and busy in another. Set the category to **All ads**.

## 3. Search One Competitor

Type the competitor's name and pick their Page from the list that drops down. They should see cards, and each card shows **Active**, **Library ID** and **Started running on** a date.

## 4. Copy What They See

On that page, press Ctrl+A then Ctrl+C on Windows, or Command+A then Command+C on a Mac. Paste it here, or into a text file in the folder you are working in if it is long. Screenshots of a few cards work too. To see more ads, scroll down before copying, because more load as you go. Ask them to look for the oldest "Started running on" dates, since those matter most.

If they want the image or the landing page, they right-click and copy that link for the few best ads. Skip it for the rest.

## 5. You Turn It Into A List

Read what they pasted and write `ads-out/<short-name>/items.json`. Use only what you can see in it, and leave out anything you cannot:

```json
[{"advertiser": "Example Roofing", "started": "Oct 21, 2026", "library_id": "123456", "format": "Image", "headline": "...", "copy": "...", "cta": "Get Quote", "landing_page": "https://..."}]
```

Then repeat from step 3 for the next competitor. Two to four competitors is plenty. Build the board the normal way:

```
<python> <scripts>/ads_board.py build --items ads-out/<short-name>/items.json --out ads-out/<short-name>
```

## What They Lose

Say this once: they get the ads they pasted, not 100 at a stroke, and many cards will have no image link. Days running, the copy, the ranking, `ad-writer` and `ad-images` all still work from what they paste.
