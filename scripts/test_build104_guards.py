"""Source guards for Build 104 (IPTV playback route, Sports Live Now readiness).

They check structure the host XCTests cannot reach (the app's Info.plist, LiveTVService, the
detail page). They guard against regressions; they do not prove playback or timing on a device.

Run: python3 scripts/test_build104_guards.py
"""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "iosApp" / "iosApp"


def source(path: str) -> str:
    return (APP / path).read_text()


def function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    open_brace = text.index("{", start)
    depth = 0
    for index in range(open_brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[index], 0)
        if depth == 0:
            return text[open_brace:index + 1]
    raise AssertionError(signature)


class Build104Guards(unittest.TestCase):
    def test_app_transport_security_is_not_relaxed(self):
        with open(APP / "Info.plist", "rb") as handle:
            ats = plistlib.load(handle)["NSAppTransportSecurity"]
        self.assertEqual(ats, {"NSAllowsLocalNetworking": True},
                         "IPTV HTTP hops go through the loopback relay, not an app-wide exception")

    def test_detail_page_routes_playback_through_the_route_check(self):
        play = function_body(source("Kyro/IPTVVOD/KyroIPTVVODDetailView.swift"), "private func play(")
        self.assertIn("XtreamVODStreamRoute.resolve(streamURL)", play)
        self.assertIn("XtreamVODCleartextRelay.shared.url(for: streamURL)", play)
        self.assertIn("XtreamVODCleartextRelay.shared.release(playURL)", play)
        self.assertIn("KyroIPTVPlaybackPlan.request(", play)
        self.assertIn("XtreamVODStreamProbe.probe(playURL)", play, "diagnostics probe what the player reads")

    def test_relay_logs_no_url_host_or_credential(self):
        relay = source("Kyro/IPTVVOD/XtreamVODCleartextRelay.swift")
        for line in re.findall(r"logger\.\w+\((.*)\)", relay):
            for forbidden in ("url", "host", "origin", "path", "target", "token", "request"):
                self.assertNotIn(f"\\({forbidden}", line.lower(), line)
        listener = function_body(relay, "private func start()")
        self.assertIn("requiredInterfaceType = .loopback", listener)
        self.assertIn("acceptLocalOnly = true", listener)

    def test_sports_matches_the_restored_sqlite_generation(self):
        service = source("LiveTV/LiveTVService.swift")
        gate = function_body(service, "private func hasSportsMatchableCatalog(")
        self.assertIn("liveCatalogs.contains(providerID)", gate)
        self.assertIn("channelStoreFreshProviderIDs.contains(providerID)", gate)
        self.assertNotIn("channelCatalogs", gate, "the JSON snapshot strips credentials; its rows stay unplayable")
        availability = function_body(service, "var liveNowAvailability: KyroSportsLiveNowAvailability")
        self.assertIn("hasSportsMatchableCatalog(providerID)", availability)
        self.assertNotIn("liveCatalogs.contains", availability)
        index = function_body(service, "private func sportsChannelIndex(")
        self.assertIn("hasSportsMatchableCatalog(providerID)", index)
        wait = function_body(service, "private func awaitPlayableCatalog(")
        self.assertNotIn("liveCatalogs.contains", wait)


if __name__ == "__main__":
    unittest.main()
