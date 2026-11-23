# Platforms: Which Actor, What It Costs, What You Get

Checked November 2026 on each actor's own Apify page. Prices are Apify's free plan rates, which are the highest; paid plans pay the same or less. A result is one post or one comment, not one lead. `apify_run.py actors` prints this list from the script itself.

Every actor below reads public data with Apify's own setup. None asks for a login to the person's social accounts, and nothing in this skill opens or drives a browser on their computer. Each platform's own terms limit automated collection. The person is responsible for how they use what comes back.

| Platform | Posts Actor | Comments Actor | Free Plan Price Per 1,000 | Free Plan Works | What Is Thin |
|---|---|---|---|---|---|
| Instagram | `apify/instagram-scraper` | the same actor | $2.70 per result | Yes | Free plan returns only the newest 15 comments per post. Few personal emails; many business bios link a site |
| TikTok | `clockworks/tiktok-scraper` | `clockworks/tiktok-comments-scraper` | $3.70 per video, $1.25 per comment | Yes | Commenters rarely link a website, so few emails |
| LinkedIn | `harvestapi/linkedin-post-search` | `harvestapi/linkedin-post-comments` | $2.00 per post, $2.00 per comment | Yes | Made by a partner, not Apify. Profiles rarely show an email; the headline often says the job and company |
| Facebook, by keyword | `scraper_one/facebook-posts-search` | `apify/facebook-comments-scraper` | $5.00 per post ($4.00 on Starter), $2.50 per comment | Yes, but at most 100 posts per search on the free plan | Public posts only. Made by Scraper One, a community developer with about 27,000 users, not by Apify. Authors come with a name and profile link; few publish an email |
| Facebook, groups you name | `apify/facebook-groups-scraper` | `apify/facebook-comments-scraper` | $5.00 per group post, $2.50 per comment | Yes | Only public groups you name. Group authors often come with a name only, no profile link, so emails are rare |
| X | `apidojo/tweet-scraper` | none | $0.40 per post | No, paid plan only | At least 50 posts per search. Bios often link a site |
| YouTube | `streamers/youtube-scraper` | `streamers/youtube-comments-scraper` | $4.00 per video, $2.00 per comment | Yes | Commenters show a handle only, almost never a website |

Pages: https://apify.com/scraper_one/facebook-posts-search/pricing , https://apify.com/apify/instagram-scraper/pricing , https://apify.com/clockworks/tiktok-scraper/pricing , https://apify.com/clockworks/tiktok-comments-scraper/pricing , https://apify.com/harvestapi/linkedin-post-search/pricing , https://apify.com/harvestapi/linkedin-post-comments/pricing , https://apify.com/apify/facebook-groups-scraper/pricing , https://apify.com/apify/facebook-comments-scraper/pricing , https://apify.com/apidojo/tweet-scraper/pricing , https://apify.com/streamers/youtube-scraper/pricing , https://apify.com/streamers/youtube-comments-scraper/pricing

## Where The Leads Usually Are

- **Comments are where buyers talk.** A popular post about a problem draws comments from people who have it. So most plans are a posts step to find those posts, then a comments step on the top posts.
- **Posts are where owners talk about themselves.** Searching for words an owner would write ("my salon", "my first employee", "slow season") finds owners posting about their own business.
- **LinkedIn suits business-to-business offers. Instagram, TikTok and Facebook suit local and consumer-facing owners.** On the basic tier, pick two or three platforms where this person's customers actually post. On the full tier, plan all six unless one clearly does not fit, and say which you left out.

## Plan Steps, One Per Platform

Each step has an `id`, an `actor`, `max_items` (the most results it may return) and an `input`. A comments step has `comments_on` (the id of an earlier posts step) and `top_posts` (how many of that step's most commented posts to read). The script fills in the post links itself.

**Instagram, posts for a hashtag, then comments:**

```json
{"id": "ig-posts", "actor": "instagram", "max_items": 60, "input": {"search": "#smallbakery", "searchType": "hashtag", "searchLimit": 1, "resultsType": "posts"}}
{"id": "ig-comments", "actor": "instagram", "max_items": 150, "comments_on": "ig-posts", "top_posts": 10, "input": {}}
```

One hashtag per step. Fields: `search`, `searchType` (hashtag, profile, place, user), `searchLimit` (at most 250, the script holds it to 5), `resultsType` (posts, details, comments, reels, mentions, stories), `resultsLimit`, `directUrls`.

**TikTok, videos for a search, then comments:**

```json
{"id": "tt-videos", "actor": "tiktok", "max_items": 60, "input": {"searchQueries": ["bakery owner"], "searchSection": "/video"}}
{"id": "tt-comments", "actor": "tiktok-comments", "max_items": 200, "comments_on": "tt-videos", "top_posts": 10, "input": {"maxRepliesPerComment": 0}}
```

Fields: `searchQueries`, `hashtags`, `searchSection` ("/video" or "/user"), `resultsPerPage`. Comments: `postURLs`, `commentsPerPost`, `maxRepliesPerComment`. The script takes out the paid extras (comments inside the video actor, transcripts, downloads, date and popularity filters).

**LinkedIn, posts for a search, then comments:**

```json
{"id": "li-posts", "actor": "linkedin", "max_items": 60, "input": {"searchQueries": ["hiring my first salesperson"], "postedLimit": "month", "sortBy": "relevance"}}
{"id": "li-comments", "actor": "linkedin-comments", "max_items": 150, "comments_on": "li-posts", "top_posts": 10, "input": {}}
```

Fields: `searchQueries`, `maxPosts` (0 means all, so the script always sets it), `postedLimit` (any, 1h, 24h, week, month, 3months, 6months, year), `sortBy` (relevance or date). Comments: `posts`, `maxItems`. Profile lookups are held to the cheapest mode.

**Facebook, public posts for a keyword, then comments:**

```json
{"id": "fb-posts", "actor": "facebook-search", "max_items": 100, "input": {"query": "pricing custom cakes", "searchType": "latest"}}
{"id": "fb-comments", "actor": "facebook-comments", "max_items": 300, "comments_on": "fb-posts", "top_posts": 15, "input": {}}
```

One search per step, up to 100 characters. Fields: `query`, `resultsCount` (the script sets it to the step's size), `searchType` (`top` or `latest`), and optional `location`, `startDate`, `endDate` (YYYY-MM-DD). On Apify's free plan this actor returns at most 100 posts per search, so the full tier uses a paid plan or more searches. Checked November 2026 at https://apify.com/scraper_one/facebook-posts-search .

**Facebook, posts in public groups the person names, then comments:**

```json
{"id": "fb-groups", "actor": "facebook-groups", "max_items": 60, "input": {"startUrls": [{"url": "https://www.facebook.com/groups/<a public group>"}]}}
{"id": "fb-comments", "actor": "facebook-comments", "max_items": 150, "comments_on": "fb-groups", "top_posts": 10, "input": {}}
```

Ask the person which public groups their customers are in, or use your web search to find some. Private groups cannot be read. The date filter costs extra and is taken out.

**X, posts for a search (paid Apify plan only):**

```json
{"id": "x-posts", "actor": "x", "max_items": 100, "input": {"searchTerms": ["\"my bakery\" -filter:retweets lang:en"], "sort": "Latest"}}
```

Fields: `searchTerms` (X's own search syntax works), `maxItems`, `sort` (Top, Latest). At least 50 per search, so `max_items` has to be at least 50 times the number of searches.

**YouTube, videos for a search, then comments:**

```json
{"id": "yt-videos", "actor": "youtube", "max_items": 10, "input": {"searchQueries": ["how to price wedding cakes"]}}
{"id": "yt-comments", "actor": "youtube-comments", "max_items": 200, "comments_on": "yt-videos", "top_posts": 5, "input": {}}
```

Fields: `searchQueries`, `maxResults`, `startUrls`. Comments: `startUrls`, `maxComments`. Shorts, streams, transcripts and AI summaries cost extra and are switched off.

## Checked On A Real Run

In November 2026 a small real run on all six platforms (Instagram, TikTok, LinkedIn, Facebook search, X and YouTube, posts and comments) came back with names or handles, profile links, the words and the source link in the right places. Two things that run taught:

- **Instagram hashtags:** a hashtag search returns the hashtag, not its posts, so the script asks for the tag's own page instead. The newest posts under a tag often have no comments yet. For comments, ask for more posts (50 or more) so the comments step has posts people actually replied to.
- **Small runs:** Apify will not start some actors with a charge limit under $0.50, so each run is sent with at least that limit. The result limit still stops it, and you are charged only for what comes back.

`normalize.py` still accepts several spellings and drops anything it cannot read, counting it. If a platform ever changes its output, read a few lines of `raw/<step>.json` beside `people.json` and check names, text and links line up.
