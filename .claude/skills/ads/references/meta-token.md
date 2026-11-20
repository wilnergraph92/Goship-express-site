# Meta Read-Only Token

Optional, and the hardest step in this pack. It takes about ten minutes. It is only needed for auditing their own account. **Say so, and offer the skip.** Steps checked November 2026. One step per message, and wait for "done". Meta moves these screens around, so if a button is not there, ask what they see and work it out with them.

`<python>` and `<scripts>` mean the same as in the skill.

**What this gives you:** a token that can read their ad account and cannot change anything. They need to be an admin or advertiser on the ad account, and logged in to Facebook on the computer they are using.

## 1. Make An App

Meta only hands out tokens through an "app". It is just a container here. Nothing gets published. Help page: https://developers.facebook.com/docs/development/create-an-app/

1. Go to https://developers.facebook.com/apps/creation/ . If this is their first time, Meta asks them to register as a developer first. Follow it through.
2. **App details:** type a name like `My Ads Audit` and their email. Click **Next**.
3. **Use cases:** choose **Create & manage ads with Marketing API**. Click **Next**.
4. **Business:** choose their business portfolio if they see it, or **I don't want to connect a business portfolio yet**. Click **Next**.
5. **Requirements:** click **Next**.
6. **Overview:** click **Go to dashboard**.

## 2. Get The Token

Help page: https://developers.facebook.com/documentation/development/create-an-app/marketing-api-use-cases

1. In the app's dashboard, open the Marketing API use case and find **Tools**. It lists a way to generate new access tokens.
2. Click to generate a token. A popup lists permissions.
3. **Tick `ads_read`. Leave `ads_management` unticked.** This is the part that makes it read-only.
4. Click **Get Token**. Meta says this token is valid for 2 months. Copy it, and do not paste it into this chat.

**If they cannot find Tools,** use the Graph API Explorer instead: https://developers.facebook.com/tools/explorer . Choose their app in the **Meta App** menu, choose **User Token** under **User or Page**, use **Add a Permission** to add `ads_read`, and click **Generate Access Token**, then approve the popup. Copy the token from the **Access Token** box at the top. This kind expires within hours, which is fine for one audit: https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived/

## 3. Put It In The Key File

```
<python> <scripts>/setup_check.py keyfile --add META_ACCESS_TOKEN --open
```

They paste the token right after `META_ACCESS_TOKEN=`, then save and close.

## 4. Find The Account Number

Open Ads Manager at https://adsmanager.facebook.com . The address bar has `act=` followed by a number. That number is what you need. They can paste this one in chat: it is not a secret.

## 5. Prove It Works

```
<python> <scripts>/meta_audit.py --account <number> --check
```

The right result names their ad account and currency. This reads and changes nothing. Then:

```
<python> <scripts>/setup_check.py mark meta done
```

- **It stops because of `ads_management`:** the token can do more than it needs. Go back to step 2 and leave that box unticked. There is an override, `--allow-broad-token`, used only if they choose it after hearing why.
- **It says it cannot read that account:** they are not on that ad account, or it is the wrong number.
- **Token expired:** make a new one in step 2.

This tool has no code that can change an ad account, whatever the token allows.
