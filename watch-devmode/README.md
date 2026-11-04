# Apple Watch Developer Mode from Windows (no Mac)

Two small scripts that turn on the **Developer Mode** switch on an Apple Watch from a Windows PC. They work
through the Watch's paired iPhone, using the free [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
tool. They were made for an iPhone 16 Pro Max on iOS 27.3 with a Watch on watchOS 27.3, where the Intel Mac VM
couldn't help (Xcode 27 is Apple-Silicon-only). Tested on 4 November 2026.

## How it works

The iPhone has a **companion proxy** service (`com.apple.companion_proxy`) that relays connections to its paired
Watch. Older versions of Xcode used it to reach Watches. Through that relay the scripts reach the Watch's own
`lockdownd` (port 62078), pair this PC with the Watch, and send AMFI's "reveal Developer Mode" action, the same
one that works on iPhones. You then turn Developer Mode on yourself, on the Watch.

## Use

1. On Windows, install **Apple Devices** from the Microsoft Store (it provides the iPhone USB driver) and Python
   3.11 or newer. Then run `python -m pip install -U pymobiledevice3`.
2. Plug in the iPhone and unlock it. Keep the iPhone's Bluetooth on, and keep the Watch unlocked and nearby.
3. Optionally run `python watch_probe.py` first. It's read-only, and shows the paired Watch and whether it answers
   through the relay (`QueryType: com.apple.mobile.lockdown`).
4. Run `python watch_devmode.py`. If the Watch or iPhone asks you to **Trust** this computer, tap Trust.
5. On the Watch, go to **Settings → Privacy & Security → Developer Mode**, turn it on, then confirm after it
   restarts.

Run it again after resetting or replacing the Watch. The pairing record is kept in pymobiledevice3's usual
pairing folder, under the Watch's UDID.

## Installing your own Watch app (free Apple ID, no Mac)

No sideloading tool (SideStore, Sideloadly, AltStore) installs Watch apps, because they only register the
iPhone. Instead:

1. **Sign:** `watchsign.exe <spare-apple-id> JarvisWatch.ipa 00008310-…` (use your Watch's UDID).
   `watchsign` is in `../watchsign` and is built on [isideload](https://github.com/nab138/isideload). It signs in
   like Xcode (asking for the password and 2FA code), registers the Watch as a watchOS development device, and
   gets a development certificate (its key is kept in Windows Credential Manager). It then registers the app IDs,
   downloads watchOS provisioning profiles and signs the app into `signed\`.
   Use a spare Apple ID, not SideStore's, so SideStore's certificate isn't touched.
2. **Install:** `python watch_install.py "signed\JarvisWatch.app"`. This streams the app to the Watch's installer
   through the relay. `--uninstall <bundle-id>` removes it.
3. Free-account signing lasts **7 days**. After that, run both steps again.

The *Build Jarvis Watch app and watchsign* GitHub workflow produces `JarvisWatch.ipa` (the watch-only build of
J.A.R.V.I.S. Wrist OS from `../jarvis-watch`) and a `watch-tools-windows` folder containing `watchsign.exe` and
these scripts.
