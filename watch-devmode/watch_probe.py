"""Asks the iPhone (over USB) about its paired Apple Watch, then tries to reach the Watch's own
lockdown service through the iPhone's companion proxy. Read-only: it changes nothing on either device.

Run with the iPhone plugged in and unlocked, the Watch unlocked and nearby:
    python watch_probe.py
"""
import asyncio

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.companion import CompanionProxyService


async def main() -> None:
    phone = await create_using_usbmux()
    print("iPhone:", phone.udid, phone.product_version)
    companion = CompanionProxyService(phone)

    watches = await companion.list()
    print("Paired watches:", watches)
    if not watches:
        return
    watch = watches[0] if isinstance(watches[0], str) else watches[0].get("UDID", watches[0])

    for key in ("ProductVersion", "ProductType", "DeviceName", "BuildVersion"):
        try:
            print(f"  {key}: {await companion.get_value(watch, key)}")
        except Exception as error:
            print(f"  {key}: (not available: {error})")

    print("Asking the iPhone to relay to the Watch's lockdown service (port 62078)...")
    try:
        port = await companion.start_forwarding_service_port(62078, "com.apple.mobile.lockdown", {"PreferWifi": True})
    except Exception as error:
        print("  The iPhone refused to relay:", error)
        return
    print("  Relay open on iPhone port", port)
    try:
        conn = await ServiceConnection.create_using_usbmux(phone.udid, port)
        print("  QueryType:", await conn.send_recv_plist({"Request": "QueryType", "Label": "watch-probe"}))
        print("  GetValue:", await conn.send_recv_plist({"Request": "GetValue", "Label": "watch-probe"}))
    except Exception as error:
        print("  Couldn't talk to the Watch through the relay:", repr(error))


asyncio.run(main())
