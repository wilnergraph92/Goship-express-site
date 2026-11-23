# The Google Sign In: Click By Click

Optional. It adds more than 1,000 rows (up to 50,000 a day) and the exact page for each search. About 15 minutes, no charge for this use, and it only ever asks to read. It uses their own Google Cloud project, so nothing goes through anyone else.

Checked November 2026:
- Desktop sign in: https://developers.google.com/identity/protocols/oauth2/native-app
- Testing status and Publish app: the page "Manage App Audience" at https://support.google.com/cloud
- Row limits: https://developers.google.com/search/blog/2022/10/performance-data-deep-dive

For Claude: one step per message, wait for "done". If a page has moved, ask what they see.

1. Go to https://console.cloud.google.com and sign in with the Google account that has their Search Console. Make a new project: click the project picker at the top, then **New project**, name it anything, click **Create**, and pick it.
2. In the search bar at the top, type **Google Search Console API**, open it, and click **Enable**.
3. Open **Google Auth Platform** (type it in the search bar). Under **Branding**, give the app a name and their email. Under **Audience**, choose **External**, and add their own Google address as a test user.
4. Under **Clients**, click **Create client**, choose **Desktop app**, name it anything, and click **Create**. A box shows a client ID and a client secret. Keep that box open.
5. Run `setup_state.py keys-file` and give them the line it prints to open the file. In that file they remove the `#` from these two lines, fill them in and save. Not in the chat.

```
GSC_CLIENT_ID=your client id
GSC_CLIENT_SECRET=your client secret
```

6. Under **Audience**, click **Publish app**. Read the trap below to them first.
7. Run `gsc.py auth`. A browser window asks them to sign in. Then run `gsc.py sites` to prove it works: it lists the sites this account can see. Then `gsc.py pull --site <one from that list> --out seo-work/gsc.json`.

## The 7 Day Trap

While the app's status is **Testing**, Google ends their sign in 7 days after they give it, with no warning. Pulls work for a week and then fail. Clicking **Publish app** under **Audience** stops that.

When they publish, Google may say the app needs verification, and when they sign in it may warn that it has not verified this app. That warning is about their own app, which only they use, so they can go on through **Advanced**. Full verification is for apps other people use. Google can change how this works. If it ever will not let them through, the export in `search-console-setup.md` always works.
