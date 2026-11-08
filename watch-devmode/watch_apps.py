"""Read-only check: can the Watch be reached for installing apps through the iPhone's relay?

It opens the Watch's app installer (installation_proxy), file transfer (AFC) and streaming installer
(streaming_zip_conduit) services through the relay, and lists the apps installed on the Watch.
Nothing is changed on the Watch or the iPhone.

    python watch_apps.py
"""
import asyncio

from pymobiledevice3.services.afc import AfcService
from pymobiledevice3.services.installation_proxy import InstallationProxyService

from watch_relay import close_relays, connect_watch


async def main() -> None:
    phone, watch, relays = await connect_watch()
    print(f"Watch: {watch.all_values.get('DeviceName')} (watchOS {watch.product_version})\n")

    print("1) App installer (installation_proxy):")
    try:
        apps = await InstallationProxyService(watch).get_apps(application_type="User")
        print(f"   Reachable. {len(apps)} third-party app(s) on the Watch:")
        for bundle_id, info in sorted(apps.items()):
            print(f"     - {info.get('CFBundleDisplayName') or info.get('CFBundleName')}  ({bundle_id})")
        system = await InstallationProxyService(watch).get_apps(application_type="System")
        print(f"   ({len(system)} Apple apps as well.)")
    except Exception as error:
        print(f"   Not reachable: {type(error).__name__}: {error}")

    print("\n2) File transfer (AFC):")
    try:
        async with AfcService(watch) as afc:
            entries = await afc.listdir("/")
            print(f"   Reachable. Top-level folders: {entries}")
            print("   PublicStaging (where installs are uploaded):", "present" if "PublicStaging" in entries else "not there yet (that's fine)")
    except Exception as error:
        print(f"   Not reachable: {type(error).__name__}: {error}")

    print("\n3) Streaming installer (streaming_zip_conduit, what Xcode uses):")
    try:
        conduit = await watch.start_lockdown_service("com.apple.streaming_zip_conduit")
        print("   Reachable. Apps can be streamed straight to the Watch's installer (nothing was sent).")
        await conduit.close()
    except Exception as error:
        print(f"   Not reachable: {type(error).__name__}: {error}")

    await close_relays(relays)


asyncio.run(main())
