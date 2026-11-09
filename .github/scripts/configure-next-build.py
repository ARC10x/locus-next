#!/usr/bin/env python3
"""Generate an isolated, external-LocalDevVPN-only test app. Standard library only."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]


def configure():
    source = (ROOT / "project.yml").read_text(encoding="utf-8")
    # Keep the application and logic tests. No embedded VPN or widget extension:
    # the free-account test install consumes one app slot and no VPN entitlement.
    pieces = re.split(r"(?=^  [A-Za-z]+:\s*$)", source, flags=re.M)
    result = "".join(p for p in pieces if not p.startswith(("  LocusTunnel:", "  LocusWidgets:")))
    result, count = re.subn(r"    dependencies:\n(?:      .*\n)+", "", result)
    assert count == 1, "Unexpected app dependencies; review configuration"
    result = result.replace("com.chrismack.locus", "com.chrismack.locusnext.dev")
    result = result.replace("INFOPLIST_FILE: Locus/Resources/Info.plist", "INFOPLIST_FILE: build/next/Info.plist")
    result = result.replace("CODE_SIGN_ENTITLEMENTS: Locus/Resources/Locus.entitlements", "CODE_SIGN_ENTITLEMENTS: build/next/LocusNext.entitlements")
    result = result.replace('MARKETING_VERSION: "1.3.0"', 'MARKETING_VERSION: "1.3.1"')
    assert "target: LocusTunnel" not in result and "target: LocusWidgets" not in result
    (ROOT / "project.next.yml").write_text(result, encoding="utf-8", newline="\n")

    info = plistlib.loads((ROOT / "Locus/Resources/Info.plist").read_bytes())
    info["CFBundleDisplayName"] = "Locus Next Test"
    info["LocusNextExternalTunnel"] = True
    info["CFBundleURLTypes"] = [{"CFBundleURLName": "com.chrismack.locusnext.dev", "CFBundleURLSchemes": ["locusnext"]}]
    info["UIBackgroundModes"] = ["location"]
    info["NSLocationWhenInUseUsageDescription"] = "Locus Next lit la position reçue par iOS pour vérifier la simulation et afficher la carte."
    info["NSLocationAlwaysAndWhenInUseUsageDescription"] = "Locus Next vérifie la simulation pendant un trajet, lorsque iOS autorise son exécution en arrière-plan."
    target = ROOT / "build/next"
    target.mkdir(parents=True, exist_ok=True)
    (target / "Info.plist").write_bytes(plistlib.dumps(info))
    (target / "LocusNext.entitlements").write_bytes(plistlib.dumps({}))
    print("Prepared Locus Next Test: com.chrismack.locusnext.dev, external LocalDevVPN")


if __name__ == "__main__":
    configure()
