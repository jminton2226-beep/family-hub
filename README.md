# Family Hub 2.0 — Vizio TV + Fire TV Stick + iPhone

A lightweight family dashboard that runs as a static website on **GitHub Pages** with **Supabase** for multi-device accounts, shared family data, private photos, and live updates. No npm, build step, or paid app-store submission is needed.

> **Status:** The demo and UI were smoke-tested in Chromium at desktop-TV (1920 × 1080) and iPhone-sized viewports. The Supabase deployment has **not** been connected to your project or tested on an actual Fire TV Stick. You must complete the cloud setup below for sharing to work between devices.

## Features included

| TV display | iPhone companion |
|---|---|
| Rotating family photo area | Upload, change captions, delete photos |
| Today's weather: conditions, high/low, sunrise/sunset, wind, precipitation | Select weather city / coordinates |
| **Rolling 4-week** Sunday–Saturday calendar, always showing the current week first | Create/edit/delete events, including all-day events |
| **Month** calendar showing every day, including empty days | Set each day's dinner |
| **Week** calendar with 7 Outlook-like columns and timed events | Change the TV's calendar view and move earlier/later |
| **Day** timeline and **Agenda** list | Add, edit, complete and assign chores |
| Walmart shopping sorted by manually assigned aisle | Edit aisle labels and grocery items |
| Today's chores and family point balances | Earn points, redeem rewards, adjust balances, inspect history |

**Calendar behavior:** The four-week view contains 28 days, not 30–31. Select **Month** when you want an entire calendar month, including overflow dates as appropriate. Week/Day/Agenda expand the calendar across the TV; Rolling/Month show the original five-panel family dashboard.

**Chore/reward behavior:** One-time, daily and weekly chores are supported. The assigned family member or a family admin marks the chore complete. Points are automatically credited once per chore occurrence. Rewards deduct points, and family admins can make manual positive/negative adjustments with an explanation. Changes are recorded in a transaction history. A completion can be undone if enough points remain to reverse it. Family admins can manage rewards and assign other admins.

## 1. Preview locally (no Supabase required)

Extract the ZIP. In the folder containing `index.html`, run:

```sh
python -m http.server 8000
```

Open on that computer:

- TV dashboard: `http://localhost:8000/?mode=tv`
- Phone companion: `http://localhost:8000/?mode=phone`

The app includes *fictional* sample entries. Demo mode stores changes only in that browser's local storage. **The demo does not synchronize between phones and the Fire TV** and does not automatically migrate into Supabase.

## 2. Create your Supabase project

1. Create a project at https://supabase.com/dashboard .
2. For a **brand-new, empty project**, open **SQL Editor → New query**, paste and run **`supabase-full-setup.sql`** once. This contains both the base schema and the Family Hub 2.0 upgrades. Do **not** run it on a populated database without reviewing it first.
3. If you **already ran the previous Family Hub v1 `supabase-schema.sql`** in your project, **DO NOT** run the full setup. Instead paste and run **`upgrade-v1-to-v2.sql`** once. This adds points, rewards, completion ledger, and TV remote state while keeping existing records. Review and back up existing production data first.
4. In **Authentication → Providers**, enable email sign-in. Keeping email confirmation enabled is recommended. Set **Authentication → URL Configuration** to include the final GitHub Pages URL as a redirect URL/site URL as appropriate.
5. In your Supabase project, find the **Project URL** and **publishable API key** (or legacy public anon key). Edit `config.js`:

```js
window.FAMILY_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
  supabasePublishableKey: 'YOUR_PUBLIC_PUBLISHABLE_KEY'
};
```

**IMPORTANT:** Only a publishable/anon key belongs in the browser. **Never** add a Supabase `service_role`, secret key, or database password to `config.js`, GitHub, or a client app. RLS policies limit each signed-in member to their own family's records. The private photo bucket serves temporary signed URLs.

6. Run the deployed phone app, create an account, and confirm email if prompted. Choose **Create family**. Have each additional family member register with their *own* email and join using the code shown under **More → Family members**. This is a family-wide editor: members can change each other's entries, as requested. The first account that creates a family is its admin.

**Permissions:** Every joined family member can edit entries and shopping. Only admins manage the reward catalog, point adjustments and admin roles. A family member can complete their own chore; an admin can complete any. The TV uses a signed-in family account but exposes a display-only *interface*; it is **not** a security-isolated read-only account.

## 3. Publish through GitHub Pages

1. Create a GitHub repository, e.g. `family-hub` (a **private** repo may require a plan/Pages entitlement; GitHub Pages URLs themselves are typically public). You can use a **public repo** safely if it only contains the application files and the *publishable* key; **never include personal photos, family data, or secret keys in GitHub**.
2. Upload the contents of this folder to the **repository root**, including `index.html`, `app.js`, `styles.css`, `v2.css`, `config.js`, `sw.js`, `manifest.webmanifest`, `assets/`, and `.nojekyll`. Do not upload the ZIP itself as the site.
3. In **Settings → Pages**, choose **Deploy from a branch**, branch **main**, folder **/(root)**, and save.
4. The URL will usually resemble `https://YOUR-USERNAME.github.io/family-hub/` (the exact URL is shown by GitHub Pages).
5. Open these two URLs in a normal desktop browser to verify the deployed version:

```
https://YOUR-USERNAME.github.io/family-hub/?mode=tv
https://YOUR-USERNAME.github.io/family-hub/?mode=phone
```

6. If you update `config.js` or any app files, commit/push the updated files to GitHub and refresh the browser. On first deployment, check that Supabase's email redirect settings include the GitHub address.

**Hosting:** GitHub Pages serves the static app; Supabase is the actual database/authorization/sync system. Putting the app on GitHub Pages **does not** sync demo data by itself.

## 4. Install the companion on iPhones

1. Open your published `?mode=phone` URL in **Safari**.
2. Tap **Share → Add to Home Screen**; select **Open as Web App** if shown.
3. Open the new Family Hub Home Screen icon and sign in with each person's account.
4. In the app, select **TV** to change the TV calendar view, or move to earlier/later dates. The display receives the updated settings via Supabase Realtime (with a periodic refresh fallback).

It's a Home Screen web app (PWA), not a native App Store binary.

## 5. Display on your Vizio 55-inch TV

1. Plug in the **Fire TV Stick** and set the TV's source to its HDMI input.
2. Connect the Fire TV Stick to Wi-Fi and open **Amazon Silk**.
3. Navigate to your GitHub Pages URL with **`?mode=tv`** at the end. Bookmark it in Silk if available.
4. Sign in using a family account, preferably with a Bluetooth keyboard for the first setup. The TV layout is read-only from the screen itself.
5. On an iPhone, open **TV**, change **4 weeks → Week** and verify that the TV switches to the seven-column view. Select **4 weeks** again to restore the full dashboard.
6. Test whether your Fire TV Stick's Silk version remains open, preserves login, and avoids sleep/idle interruption. TV energy-saving settings and Fire TV idle behavior vary by model; an always-on kiosk mode is **not** guaranteed by Silk.

An optional HDMI mini-PC in full-screen kiosk browser mode is the fallback if Silk's sleep, address bar, or sign-in behavior is inconvenient. No Vizio native app is supplied or needed for the first deployment.

## 6. Notes and limitations

- **Walmart aisles are manual and remembered** per product in this version, because Walmart store-specific aisle-location data is not connected. The selected store name is displayed as a reference only.
- **Weather** uses Open-Meteo and needs an internet connection. The initial city is a placeholder (`Chicago, IL`); set the actual city and coordinates under **More**. Do not assume the initial weather is for your home.
- **Calendar entries** are native to Family Hub. Google/Apple/Outlook calendar import is **not** included.
- **Photos** are resized before uploading. Cloud photos are stored in a private Supabase bucket; demo photos stay on the device and may fill browser storage.
- **Rewards redemption is immediate.** It does not include parent approval or automatic delivery of a physical reward.
- **Realtime/SQL:** The web front-end was tested locally without Supabase credentials. Server-side SQL migrations, account onboarding, RLS enforcement, and real Fire TV/iPhone-to-TV live sync need to be tested in your Supabase project with multiple accounts before relying on them with private family photos.
- **TV security:** A member signed in on a TV has the same authentication privileges as that account. While TV mode has no editing controls, someone with access to its browser could navigate to the phone editor. Use an account appropriate for a shared household screen and keep the device physically private.

## Troubleshooting

| Problem | Check |
|---|---|
| `LOCAL DEMO` appears | `config.js` has empty URL/key, or your edits have not been deployed |
| Phone edit doesn't show on TV | Both devices signed into same Supabase project/family; TV URL has `?mode=tv`; try refreshing after one minute |
| Error mentions `rewards` or `tv_display_settings` table | Correct v2 SQL script hasn't been run |
| Photos don't load | Confirm private bucket policies, family membership and internet connection |
| Email confirmation link goes to a different site | Set Supabase Auth URL Configuration to the actual GitHub Pages domain/path |
| TV pauses, shows address bar or logs out | Silk/Fire TV limitations; consider a small HDMI-connected PC |
| Forecast unavailable | Weather service/network access and coordinates under More |

## Files

- `index.html`, `app.js`, `styles.css`, `v2.css`: front-end application.
- `config.js`: public Supabase project configuration (blank for demo mode).
- `supabase-full-setup.sql`: **new project only**.
- `upgrade-v1-to-v2.sql`: **existing v1 database only**.
- `manifest.webmanifest`, `sw.js`, `assets/`: PWA/Home Screen support.
- `README.md`: this guide.

**This is an independently hosted starter project, not an audited commercial service.** For sensitive family information, verify Supabase policies with at least two family accounts before uploading personal content.
