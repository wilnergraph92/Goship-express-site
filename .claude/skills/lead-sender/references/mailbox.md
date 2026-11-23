# Your Own Mailbox: The Login That Sends

Steps checked November 2026. One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

`<python>` means the same as in the skill. `<finder-scripts>` is the `scripts` folder of the `lead-finder` skill, and `<scripts>` is this skill's own.

Ask first: "What do you use for email: Gmail, Google Workspace, Microsoft 365 or Outlook, or something else?"

## Gmail And Google Workspace

**1. Turn on 2-Step Verification.** App passwords need it. Help page: https://support.google.com/accounts/answer/185839

Open https://myaccount.google.com , click **Security & sign-in**, and under "How you sign in to Google", turn on **2-Step Verification**. Follow the steps on the screen. If it is already on, go to step 2.

**2. Make an app password.** Go to https://myaccount.google.com/apppasswords . Sign in if asked. Type a name like `Lead Emails`, then create it. Google shows the password once. Keep that window open for the next step. Do not paste it into this chat.

If the page says this setting is not available, one of two things is likely: 2-Step Verification is off, or this is a work account where an admin has turned app passwords off. A work account needs the admin. Help page: https://support.google.com/accounts/answer/185833 . Google itself says app passwords are not recommended for most uses, so tell them that: this is a real password to their mailbox, and they can delete it on that same page any time.

**3. Put the login in the key file.**

```
<python> <finder-scripts>/setup_check.py keyfile --add SMTP_HOST --add SMTP_PORT --add SMTP_USER --add SMTP_PASSWORD --open
```

They fill it in like this, then save and close. Use the app password, with any spaces removed, not their normal password:

```
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=their full email address
SMTP_PASSWORD=the app password
```

**4. Prove it works.**

```
<python> <scripts>/send_queue.py check-login
```

The right result is "Login works. No email was sent." Then:

```
<python> <finder-scripts>/setup_check.py mark mailbox done
```

**Limits:** Google lists 500 emails a day on personal Gmail (https://support.google.com/mail/answer/22839) and 2,000 a day through this route on Workspace (https://support.google.com/a/answer/176600). This skill stops well below those: 25 a day by default.

## Microsoft 365 Or Outlook

Tell them plainly: Microsoft is moving away from password logins for sending. It says this kind of login will be off by default for existing Microsoft 365 organizations from the end of December 2026, though an admin can still turn it on. Look for the post on the SMTP AUTH deprecation timeline on Microsoft's Exchange blog: https://techcommunity.microsoft.com/blog/exchange . So do not plan on it. Offer a separate Google Workspace mailbox, which is also the safer way to send cold email (see `sending-domain.md`), or the drafts route.

## Anything Else

Look up that provider's current help page for its SMTP settings with your web search, and turn it into clicks. You need the outgoing server name, a port (587 is usual, and 465 also works) and how it wants passwords. Many need an app password. This script will not send a password over an unencrypted connection.

## If It Cannot Connect

If `check-login` cannot connect, check SMTP_HOST and SMTP_PORT. Some networks block outgoing mail. If theirs does, they can try another network, or send the drafts by hand.

## If They Skip This

Say in one line: "No problem. I will write the emails to a file, and you paste them into your own email yourself." That is the `drafts` command in the skill.
