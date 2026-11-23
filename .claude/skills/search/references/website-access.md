# Website Access: By Platform

Optional. The check never needs this. It is only for having Claude make the fixes, and each change still needs a yes. Ask what their site runs on. The crawl's `platform_guess` gives a first guess.

Checked November 2026:
- Application passwords: https://developer.wordpress.org/advanced-administration/security/application-passwords/
- WordPress REST API sign in: https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/

## The Site Is A Folder Or Repo

Nothing to set up: they tell you where the folder is.

Prove it: list the folder and find the home page file. Say which file you found. It does not commit or push, so they publish their site their usual way.

## WordPress

One step per message. Wait for "done". The site must be on https.

1. Log in to their WordPress dashboard. It is usually their site address plus `/wp-admin`.
2. Make a separate user just for this. In the left menu click **Users**, then **Add New**. Give it a username and an email, set the role to **Editor**, and save. An Editor can change pages and cannot change the site's setup. Never use their own login or their normal password, and do not make this on an administrator: if it ever leaked, it could change the whole site. If they would rather not add a user, use the paste route below.
3. Open that user's profile: **Users**, then **All Users**, then **Edit** on that user.
4. Scroll down to **Application Passwords**. If there is no such section, the site may not be on https, or a security plugin or the host has turned it off. Say so, and offer the paste route below instead.
5. In the **New Application Password Name** box, type `Claude`, and click **Add New Application Password**. WordPress shows a password made of groups of letters, once only. Keep that page open. This is not their login password, and they can revoke it from this same section at any time.
6. Run `setup_state.py keys-file` and give them the line it prints to open the file. They remove the `#` from these three lines, fill them in and save. Not in the chat. If it landed in the chat, tell them to revoke it in step 5 and make a new one.

```
WP_SITE_URL=https://your-website.com
WP_USER=the username from step 2
WP_APP_PASSWORD=the password from step 5
```

7. Prove it. This only reads:

```
<python> <search-fixer's folder>/scripts/apply.py check-wp
```

It says who it signed in as, and that this user can edit pages. If it warns that this is an administrator, go back to step 2. If it says the site tried to send the request to another address, it stopped and the password did not go with it, so read that message to them.

What this gets them: page titles changed, answers added to existing pages, and new pages created as drafts they publish themselves. A change to a page that is already live needs their own approval code each time. WordPress has no description box by itself, and structured data usually lives in an SEO plugin, so those often come back as text to paste. The script reads every change back, so it never reports a change that did not stick.

## Any Other Builder (Wix, Squarespace, Shopify, Webflow And Others)

Nothing to set up. Claude writes every approved change as paste-ready text and walks them through where it goes. If they are not sure where a builder keeps a page's title, look up its current help page during the run and turn it into clicks.
