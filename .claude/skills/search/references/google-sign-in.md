# Business Profile Connection: Click By Click

For the Full version. It lets Claude read the whole Google Business Profile, with the review numbers and dates, and make an approved change to the description, the website link or the hours. Without it, the owner answers a short checklist from their profile (`business-profile-by-hand.md`) and pastes each approved change in by hand. Nothing is lost but speed.

**The catch, said plainly before they start:** Google only lets a project use these APIs after it approves an access request, and it asks that the profile has been verified and active for 60 days or more. Approval can take days and can be refused. So start the request now, carry on with the by-hand checklist today, and add the connection when Google says yes.

Checked November 2026:
- Access request: https://developers.google.com/my-business/content/prereqs . Form: https://support.google.com/business/contact/api_default , choose **Application for Basic API Access**. In Google Cloud, the API's quota shows 0 per minute until approved, and 300 per minute once approved.
- Changing a field: https://developers.google.com/my-business/reference/businessinformation/rest/v1/locations/patch
- Reviews: https://developers.google.com/my-business/content/review-data
- Desktop sign in: https://developers.google.com/identity/protocols/oauth2/native-app

For Claude: one step per message, wait for "done". If a screen looks different, ask what they see.

1. Go to https://console.cloud.google.com with the Google account that manages the profile. Use the same project as the Places key if they made one, or make a new one: the project picker at the top, **New project**, **Create**, then pick it.
2. Ask for access. Open https://support.google.com/business/contact/api_default , choose **Application for Basic API Access**, and fill it in with this project and their business. They submit it themselves. Google emails them when it has decided.
3. Turn on the APIs. In the search bar at the top, find and **Enable** each of: **My Business Account Management API** and **My Business Business Information API**. After approval, also enable **Google My Business API**, which reads reviews. If one cannot be found yet, that is normal before approval.
4. Open **Google Auth Platform** (type it in the search bar). Under **Branding**, give the app a name and their email. Under **Audience**, choose **External** and add their own Google address as a test user.
5. Under **Clients**, click **Create client**, choose **Desktop app**, name it anything, and click **Create**. A box shows a client ID and a client secret. Keep it open.
6. Run `setup_state.py keys-file` and give them the line it prints to open the file. They remove the `#` from these two lines, fill them in and save. Not in the chat.

```
GOOGLE_CLIENT_ID=the client ID
GOOGLE_CLIENT_SECRET=the client secret
```

7. Under **Audience**, click **Publish app**. Read the trap below to them first.
8. Sign in: `<python> <this skill's folder>/scripts/gbp.py auth` . A browser window asks them to sign in and allow managing the Business Profile. Signing in changes nothing.
9. Prove it: `<python> <this skill's folder>/scripts/gbp.py check` . Before approval it says Google has not approved the project yet: mark the tool `later` with a note, and use the checklist today. After approval it lists their profiles with the `--location` and `--account` to use.

## The 7 Day Trap

While the app's status is **Testing**, Google ends the sign in 7 days after they give it. Clicking **Publish app** under **Audience** stops that. Google may then warn, when they sign in, that it has not verified this app. That warning is about their own app, which only they use, so they can go on through **Advanced**. If it ever will not let them through, the by-hand checklist always works.

## What Changes Through It

Only three fields, and only after the owner approves the exact new text with their own code: the description (up to 750 characters), the website link, and the opening hours. Google reviews some edits before they show. Categories, services, photos, the name and the address are always done by hand with the clicks Claude gives, because a wrong change there can put the profile under review.
