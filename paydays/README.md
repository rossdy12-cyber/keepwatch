# Paydays

A small web app on TrueNAS for keeping track of monthly bills against weekly pay, and how much is safe to
spend each week so you don't run out before the next payday. It works best on a phone: add it as a shortcut in
NAS Portal, or open it in Safari and choose *Share → Add to Home Screen*.

**Month tab**
- **Safe to spend:** a steady amount per week (and per day). Work it out as your pay over a year, minus a year of
  bills and savings, spread evenly over 52 weeks. Big bills like rent are smoothed out, so the week they land in
  doesn't leave you short.
- **Until payday:** what this pay leaves after putting money aside for the next bills, minus the spending you've
  logged with **+ Spent**, and what that works out to per day until payday.
- **This month:** pay in, bills out, left over, and what's still to pay.
- **Each payday:** what to put aside from that pay, which bill it's for, and what's left to spend. Each pay saves
  towards the next big bill: with rent £700 on the 5th and StepChange £494 on the 20th, the pays from the 5th to
  the 19th save for StepChange and the pays from the 20th to the 4th save for rent. Smaller bills are saved for
  alongside, from the last bill at least half their size.
- **Day by day:** a running balance, with a warning if a bill would take you below zero. Until you enter your real
  balance on the 1st, it starts from what the saving plan says should already be put aside.
- **Tick off** each bill as it leaves your account.

**Bills tab:** add each monthly payment with its amount and the day of the month it goes out.
**Pay & settings:** your usual take-home pay, how often you're paid, one recent payday, and an optional
monthly savings goal. On the Month tab, tap **Edit** on any payday to put in what you actually got.

## Install on TrueNAS

1. **Apps → Discover Apps →** ⋮ **→ Install via YAML**. Name it `paydays` and paste [`compose.yaml`](compose.yaml).
2. Save. It runs at `http://<nas-ip>:8450` (or `http://100.85.127.42:8450` over Tailscale).
3. To use it at `https://paydays.nas-server.co.uk`, add a proxy host for it in Nginx Proxy Manager (forward to
   the NAS on port 8450) and put it behind Authelia like your other apps, because this is your financial information.
   If it's only ever used over Tailscale, you can set `APP_PASSWORD` instead.

Your data lives in the app's `paydays-data` volume (one small SQLite file). To keep it in a dataset you
back up, change the volume line in the YAML to a path such as `/mnt/<pool>/apps/paydays:/data`.

`compose.yaml` is generated: edit `server.py`, then run `python3 build_compose.py`.
