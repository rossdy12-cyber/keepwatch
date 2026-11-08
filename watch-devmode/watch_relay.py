"""Shared helper: a pymobiledevice3 lockdown client for the paired Apple Watch, with every connection relayed
through the iPhone's companion proxy (com.apple.companion_proxy). Used by watch_apps.py."""
from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
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


async def connect_watch(pair_timeout: float = 120):
    """Connects to the iPhone over USB, then to its paired Watch (pairing if this PC isn't trusted yet).
    Returns (phone, watch, relays); close the relays when finished."""
    phone = await create_using_usbmux()
    watches = await CompanionProxyService(phone).list()
    if not watches:
        raise RuntimeError("The iPhone has no paired Watch.")
    watch_udid = watches[0] if isinstance(watches[0], str) else watches[0].get("UDID")
    relays: list = []
    first = await ServiceConnection.create_using_usbmux(phone.udid, await relay(phone, WATCH_LOCKDOWN_PORT, relays))
    watch = await WatchLockdownClient.create(
        first, identifier=watch_udid, autopair=True, pair_timeout=pair_timeout,
        port=WATCH_LOCKDOWN_PORT, phone=phone, relays=relays)
    return phone, watch, relays


async def close_relays(relays: list) -> None:
    for control in relays:
        try:
            await control.close()
        except Exception:
            pass
