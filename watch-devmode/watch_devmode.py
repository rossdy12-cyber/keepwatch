"""Turns on the Developer Mode switch on an Apple Watch from Windows, through its paired iPhone.

What it does:
  1. Connects to the iPhone over USB and finds the paired Watch.
  2. Asks the iPhone to relay connections to the Watch (its "companion proxy", the same thing older Xcode used).
  3. Pairs this PC with the Watch (if the Watch or iPhone asks you to Trust this computer, tap Trust).
  4. Asks the Watch to show its Developer Mode switch (Settings -> Privacy & Security -> Developer Mode).
     You then turn it on yourself on the Watch; it restarts and asks you to confirm.

Run with the iPhone plugged in and unlocked, the Watch unlocked, on your wrist or charger, Bluetooth on:
    python watch_devmode.py
"""
import asyncio

from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.companion import CompanionProxyService

WATCH_LOCKDOWN_PORT = 62078


async def relay(phone, watch_port: int, keep: list) -> int:
    """Asks the iPhone to forward one of the Watch's ports; returns the iPhone-side port to connect to.
    The control connection is kept open (in `keep`): closing it would stop the relay."""
    control = await phone.start_lockdown_service(CompanionProxyService.SERVICE_NAME)
    reply = await control.send_recv_plist({
        "Command": "StartForwardingServicePort",
        "GizmoRemotePortNumber": watch_port,
        "IsServiceLowPriority": False,
        "PreferWifi": True,
    })
    keep.append(control)
    port = reply.get("CompanionProxyServicePort")
    if not port:
        raise RuntimeError(f"The iPhone wouldn't relay Watch port {watch_port}: {reply}")
    return port


class WatchLockdownClient(LockdownClient):
    """pymobiledevice3's lockdown client, with every connection relayed through the iPhone."""

    def __init__(self, *args, phone=None, relays=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.phone = phone
        self.relays = relays

    async def create_service_connection(self, port, ssl_context=None, strip_ssl=False):
        local_port = await relay(self.phone, port, self.relays)
        return await ServiceConnection.create_using_usbmux(
            self.phone.udid, local_port, ssl_context=ssl_context, strip_ssl=strip_ssl)


async def main() -> None:
    phone = await create_using_usbmux()
    print(f"iPhone {phone.udid} (iOS {phone.product_version})")
    watches = await CompanionProxyService(phone).list()
    if not watches:
        print("No paired Watch found.")
        return
    watch_udid = watches[0] if isinstance(watches[0], str) else watches[0].get("UDID")
    print(f"Watch {watch_udid}")

    relays: list = []
    first = await ServiceConnection.create_using_usbmux(phone.udid, await relay(phone, WATCH_LOCKDOWN_PORT, relays))

    print("\nPairing with the Watch. If the Watch or iPhone asks whether to Trust this computer, tap Trust.")
    print("(Waiting up to 2 minutes...)")
    try:
        watch = await WatchLockdownClient.create(
            first, identifier=watch_udid, autopair=True, pair_timeout=120,
            port=WATCH_LOCKDOWN_PORT, phone=phone, relays=relays)
    except Exception as error:
        print(f"\nPairing didn't work: {type(error).__name__}: {error}")
        return
    print(f"Paired: {watch.all_values.get('DeviceName')} (watchOS {watch.product_version})")

    print("\nAsking the Watch to show its Developer Mode switch...")
    try:
        await AmfiService(watch).reveal_developer_mode_option_in_ui()
    except Exception as error:
        print(f"The Watch refused: {type(error).__name__}: {error}")
        return
    print("Done. On the Watch: Settings -> Privacy & Security -> Developer Mode -> turn it on.")
    print("It restarts; after it starts up, confirm Turn On (and enter the Watch passcode).")

    for control in relays:
        try:
            await control.close()
        except Exception:
            pass


asyncio.run(main())
