# Google Ads Report Export

Optional. No login, no token and nothing to install. Steps checked November 2026. Help page: https://support.google.com/google-ads/answer/2404176 . One step per message, and wait for "done". If a button has moved, ask what they see and work it out with them.

**Why a file:** direct Google Ads API access needs a developer token applied for through a manager account: https://developers.google.com/google-ads/api/docs/api-policy/developer-token . That is too much setup for this, so they download a report instead. The tool never connects to their account.

## 1. Open The Table

Sign in at https://ads.google.com and open **Campaigns**, so they see the table of campaigns. Set the date range at the top right to the last 30 days.

## 2. Check The Columns

The table needs these columns: **Campaign**, **Budget**, **Status** or **Campaign state**, **Cost**, **Clicks**, **Impr.** and **Conversions**. If one is missing, click the **Columns** icon above the table, then **Modify columns**, tick it and apply. Help page: https://support.google.com/google-ads/answer/2404037

## 3. Download

Click the download icon in the upper right corner above the table, click **Download**, and choose **Excel CSV**. If they only see .csv, that is fine too. Save it somewhere easy to find, like the folder you are working in, and tell me the file's name.

## 4. Run It

```
<python> <scripts>/google_csv_audit.py path/to/report.csv --out ads-out/<short-name>/audit
```

The right result says how many rows it read and writes `google-budget-moves.md`. If it says it cannot find the columns, ask them to paste just the first few lines of the file with no account details, and work out what the columns are called there. Then:

```
<python> <scripts>/setup_check.py mark google done
```
