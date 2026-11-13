# Trial-ending reminder

The brief asks for a reminder before the 14-day trial turns into a paid plan,
so nobody is charged by surprise.

## In the app (shipped in 1.1.0)

In the last 3 days of a trial that will renew, Today shows a "Free trial
ending" card with the end date and a "Manage in Google Play" button. It uses
the trial end date RevenueCat reports (`ProRenewal.trialEndingReminder`). A
trial the clinician already cancelled shows nothing.

## By email (needs the SOLIS Worker; not built yet)

The Worker (`cloudflare-healthcare-rcm-agentic-cloud`) is not in GitHub, so
this part can't be built from here. The plan:

1. **RevenueCat webhook.** RevenueCat dashboard, Project settings,
   Integrations, Webhooks. The URL is `https://<worker>/api/v2/revenuecat`,
   with an Authorization header value saved as the Worker secret
   `REVENUECAT_WEBHOOK_AUTH`. The Worker rejects any call without it.
2. **Store trial ends.** On an `INITIAL_PURCHASE` event with
   `period_type = TRIAL`, save `app_user_id` and `expiration_at_ms` in D1 or
   KV. On `CANCELLATION`, `EXPIRATION` or `RENEWAL`, delete the row. The
   `app_user_id` is the SOLIS account ID, so the email comes from the SOLIS
   account table. Never take it from the webhook body.
3. **Daily cron** (`[triggers] crons = ["0 15 * * *"]`). For rows ending in
   48 to 72 hours that have not been reminded yet, send one email and mark
   the row reminded.
4. **Sending.** Use Amazon SES in the existing AWS account: a verified
   sending domain, with `AWS_SES_*` as Worker secrets. That costs about $0.10
   per 1,000 emails. Cloudflare Email Routing can't send to arbitrary
   addresses.
5. **Content.** No patient data, ever. Use the same words as the in-app card:
   the end date, the plan they picked, and a "Manage or cancel in Google Play"
   link (`https://play.google.com/store/account/subscriptions?package=com.solis.clinical.solis_mobile`).

The owner needs to decide the sending domain and the support address before
this ships (the support email is still an open item in the Play listing).
