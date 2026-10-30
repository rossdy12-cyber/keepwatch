# Keepwatch

Keepwatch is an iPhone dashboard for your TrueNAS server and the media apps running on it.

| Tab | What it shows |
|---|---|
| **Overview** | Live CPU, memory, network and temperatures; storage pools (space used, health, scrubs); every disk with its temperature and SMART result; active TrueNAS alerts; and each app, whether it's running and which port it uses. |
| **Files** | Browse your datasets under `/mnt` with sizes and dates. Tap a file to see its details and download a copy to preview or share. **Read-only:** Keepwatch can't delete, move or change anything on the NAS. |
| **Downloads** | The NZBGet queue and speed, pause/resume (everything or one item), and recent history. |
| **Media** | **Upcoming:** the next 14 days from Sonarr, Radarr and Lidarr, with artwork. **Missing:** wanted episodes, movies and albums. **Library:** counts, disk space, and recently added items. |
| **Settings** | The address and key for each service, with a **Test connection** button for each. |

Pull down on any screen to refresh. Keepwatch only talks to your own servers over Tailscale. It has no accounts or tracking of its own, and it keeps your keys in the iPhone Keychain.

You don't need a Mac or a paid Apple developer account. GitHub builds the app in the cloud, and **Sideloadly** installs it on your iPhone with your normal (free) Apple ID.

---

## What you need

- A Windows PC.
- Your iPhone (iOS 16 or newer) and its USB cable.
- Your normal Apple ID (the free one you use for the App Store).
- Tailscale switched on, on both the iPhone and the NAS.
- A free GitHub account.

---

## Step 1: Get the code onto GitHub

GitHub builds the app on one of its Macs from the code in a "repository" (a folder on GitHub).

**If this was set up for you**, the repository already exists (for example `github.com/<your-username>/keepwatch`) and you can skip to Step 2.

**To do it yourself:**

1. Sign up at <https://github.com/signup> if you don't have an account.
2. Click the **+** at the top right of GitHub, then **New repository**.
3. **Repository name:** `keepwatch`. Choose **Public** (public repos get unlimited free builds; the code holds no passwords, keys or addresses, because you type those into the app on your phone). Click **Create repository**.
   *(Private also works, but the free plan only gives about 200 Mac build minutes a month, roughly 20 builds.)*
4. On the next page, click **uploading an existing file**.
5. Open this project folder in File Explorer, select **everything inside it** (including the `.github` folder), and drag it onto the GitHub page. Check that `.github` was included: it holds the build instructions.
6. Click **Commit changes**.

> **Using Git?** From this folder: `git remote add origin https://github.com/<you>/keepwatch.git` and then `git push -u origin main`. The result is the same.

---

## Step 2: Build the app on GitHub

1. In your repository, click the **Actions** tab.
2. If GitHub asks, click **I understand my workflows, go ahead and enable them**.
3. On the left, click **Build unsigned IPA**.
4. Click **Run workflow**, then the green **Run workflow** button. (Uploading new code to `main` also starts a build by itself.)
5. Wait about 5–15 minutes. A green tick means the build worked. A red cross means it failed; click it to see why.

---

## Step 3: Download the app file (.ipa)

1. Click the finished (green) run.
2. Scroll down to **Artifacts** and click **Keepwatch-ipa**. A `.zip` file downloads.
3. Right-click the zip, choose **Extract All…**, and extract it. Inside is **`Keepwatch.ipa`**: that file is the app.

---

## Step 4: Install Sideloadly and Apple's helper apps

1. Install **iTunes** and **iCloud** using the **downloads from Apple's website**, not the Microsoft Store versions. Sideloadly needs Apple's versions:
   - iTunes: <https://www.apple.com/itunes/> (choose the Windows download, not the Microsoft Store link)
   - iCloud: Sideloadly's site links to the correct installer.
2. Download Sideloadly for Windows from <https://sideloadly.io> and install it.

---

## Step 5: Put Keepwatch on your iPhone

1. Connect the iPhone to the PC with the cable. Unlock it and tap **Trust** if it asks.
2. Open **Sideloadly**.
3. Drag **`Keepwatch.ipa`** onto the Sideloadly window (or click the IPA icon and choose it).
4. Check that your iPhone shows in the **iDevice** box.
5. Type your **Apple ID email** in the **Apple account** box and click **Start**.
6. Enter your Apple ID password when Sideloadly asks, and the 6-digit code if your phone shows one. Sideloadly only sends these to Apple, to create a free 7-day signing certificate.
7. Wait until it says **Done**.

**First time only, on the iPhone:**

1. Open **Settings → General → VPN & Device Management**, tap your Apple ID under **Developer App**, then **Trust**.
2. If iOS asks for **Developer Mode**: **Settings → Privacy & Security → Developer Mode → On**. The iPhone restarts; confirm **Turn On** afterwards.

Free Apple IDs allow at most **3 sideloaded apps** on a phone at once (Keepwatch and Hearth count as two).

---

## Step 6: Create your API keys

Keepwatch needs a key for each service. Create them yourself, and paste them only into the Keepwatch app on your phone. Don't put them in GitHub, email or chat.

### TrueNAS API key

1. Open the TrueNAS web page and sign in.
2. Go to **Credentials → API Keys** (on some versions it's under your user menu at the top right → **API Keys**).
3. Click **Add**, give it a name like `keepwatch`, and save.
4. **Copy the key now:** TrueNAS only shows it once. You can always delete it and make a new one.

> **Important:** use **`https://`** for TrueNAS in Keepwatch (for example `https://100.x.x.x`). TrueNAS automatically switches off an API key if it is ever sent over plain `http://`. Keepwatch refuses to send it over http for that reason. TrueNAS uses its own "self-signed" certificate, so leave **Accept self-signed certificate** on.

### Sonarr, Radarr and Lidarr API keys

In each app's web page: **Settings → General → Security → API Key**. Click the copy button next to the key.

### NZBGet username and password

In NZBGet's web page: **Settings → Security → ControlUsername** and **ControlPassword**. (On a fresh install, the username is `nzbget`.)

### Finding each app's address

Each address is your NAS's **Tailscale IP** plus the app's **port**, for example `http://100.x.x.x:30027`.

- In TrueNAS, go to **Apps**, click the app, and look for its port under **Workloads** / **Ports**.
- Or, once TrueNAS is connected, Keepwatch's **Overview** tab lists every app with its port.
- To check an address, open it in Safari on the iPhone (with Tailscale on). You should see the app's web page.

---

## Step 7: Set up Keepwatch

1. Make sure **Tailscale is on** on the iPhone.
2. Open **Keepwatch**. The **Settings** tab opens the first time.
3. For each service, fill in the **Address** and paste the **API key** (or NZBGet's username and password), then tap **Test connection**. A green tick means it works; a red cross shows what went wrong.
4. Go to **Overview**. Your server's health appears within a few seconds, and CPU, memory and network update live.

You can leave out any service you don't use; its tab will just ask you to set it up.

---

## Every 7 days: re-sign the app

Free Apple IDs sign apps for **7 days only**. After that Keepwatch won't open (it shows "unavailable" or closes straight away). Nothing is lost; you just sign it again:

1. Plug the iPhone into the PC and open Sideloadly.
2. Choose the same `Keepwatch.ipa`, the same Apple ID, and click **Start**.

Your addresses and keys stay, because the app's ID doesn't change.

**Tip:** Sideloadly can do this over Wi-Fi without the cable. Turn on **Wi-Fi sync** for the phone in Sideloadly (or in iTunes, tick "Sync with this iPhone over Wi-Fi") and turn on **Automatic refresh** in Sideloadly's options. The PC needs to be on, with Sideloadly running, at least once a week.

---

## Updating Keepwatch

When the code changes, upload the new files to GitHub (Step 1). That starts a new build. Download the new `Keepwatch.ipa` (Step 3) and install it with Sideloadly over the old one (Step 5). Your settings are kept.

---

## Troubleshooting

| Problem | What to try |
|---|---|
| "Couldn't reach the server" | Check that Tailscale is on, on the iPhone. Open the same address in Safari on the phone: if Safari can't open it either, the address or port is wrong. |
| "Use https:// for TrueNAS" | Change the TrueNAS address to start with `https://`. |
| "The server's certificate isn't trusted" | Turn on **Accept self-signed certificate** under TrueNAS in Settings. |
| TrueNAS key "refused" | The key may have been revoked (for example, if it was ever used over http). Create a new one (Step 6). |
| "That address is Radarr, not Sonarr" | The ports are swapped. Check each app's port in TrueNAS → Apps. |
| Temperatures or SMART show "—" | Some TrueNAS versions or virtual disks don't report them. A NAS running as a virtual machine often can't see its disks' temperatures. |
| Keepwatch won't open after a week | Re-sign it with Sideloadly ("Every 7 days" above). |
| Sideloadly can't see the iPhone | Reinstall the Apple (not Microsoft Store) versions of iTunes and iCloud, unlock the phone, and tap Trust. |
| GitHub build has a red cross | Click the failed run and open the red step to see the error. |

---

## For the curious: how it's built

- `project.yml`: an [XcodeGen](https://github.com/yonaskolb/XcodeGen) description of the Xcode project, which is generated on the build machine.
- `.github/workflows/build-ipa.yml`: on a GitHub macOS machine, installs XcodeGen, builds for iPhone with code signing turned off, puts `Keepwatch.app` into `Payload/` and zips it as `Keepwatch.ipa`. Sideloadly signs it later.
- `Keepwatch/` is the SwiftUI app (iOS 16+):
  - `TrueNAS/`: the TrueNAS SCALE JSON-RPC 2.0 WebSocket API at `/api/current` (`auth.login_with_api_key`, `system.info`, `pool.query`, `disk.query`, `disk.temperatures`, `alert.list`, `app.query`, `filesystem.listdir`, `filesystem.stat`, `core.download`), plus the `reporting.realtime` subscription for live stats. Older TrueNAS versions without that endpoint fall back to the REST API at `/api/v2.0`.
  - `Services/`: NZBGet JSON-RPC (`status`, `listgroups`, `history`, `pausedownload`, `resumedownload`, `editqueue`), Sonarr and Radarr API v3, and Lidarr API v1 (`calendar`, `wanted/missing`, `series`, `movie`, `artist`).
  - `Core/`: Keychain storage, networking, and self-signed certificate handling (only for the TrueNAS address you entered).
  - `Info.plist` (generated from `project.yml`) allows plain-http connections, because Tailscale addresses use http.
