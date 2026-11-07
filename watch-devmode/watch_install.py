"""Installs a signed Watch app straight onto the Apple Watch, through the iPhone's companion relay,
using the Watch's streaming installer (the way Xcode installs Watch apps).

    python watch_install.py "signed\\JarvisWatch.app"        install (or update)
    python watch_install.py --uninstall <bundle-id>           remove it again

Sign the app first with watchsign.exe. iPhone plugged in and unlocked, Watch unlocked and nearby.
"""
import asyncio
import sys
from pathlib import Path

from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.streaming_zip_conduit import StreamingZipConduitService

from watch_relay import close_relays, connect_watch


async def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        return
    phone, watch, relays = await connect_watch()
    print(f"Watch: {watch.all_values.get('DeviceName')} (watchOS {watch.product_version})")
    try:
        if sys.argv[1] == "--uninstall":
            bundle_id = sys.argv[2]
            await InstallationProxyService(watch).uninstall(bundle_id)
            print(f"Removed {bundle_id}.")
            return
        app = Path(sys.argv[1])
        if not app.exists():
            print(f"Can't find {app}")
            return
        print(f"Sending {app.name} to the Watch (this goes over Bluetooth/Wi-Fi via the iPhone, so give it a minute)...")
        async with StreamingZipConduitService(watch) as conduit:
            await conduit.install(app, developer=True)
        print("Installed. Find it in the Watch's app list (press the Digital Crown).")
        print("If it won't open, trust the developer on the Watch: Settings -> General -> VPN & Device Management.")
    finally:
        await close_relays(relays)


asyncio.run(main())
