#!/usr/bin/env python3
"""Validate app isolation before producing the Sideloadly artifact."""
from pathlib import Path
import plistlib
import zipfile

root = Path("build/LocusNext.xcarchive/Products/Applications/Locus.app")
info = plistlib.loads((root / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.chrismack.locusnext.dev"
assert info["CFBundleDisplayName"] == "Locus Next Test"
assert info["LocusNextExternalTunnel"] is True
assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["locusnext"]
assert not list(root.rglob("*.appex")), "Test app must not embed VPN/widgets"
assert (root / "Locus").is_file()
artifact = Path("build/Locus-Next-Test.ipa")
with zipfile.ZipFile(artifact, "w", zipfile.ZIP_DEFLATED) as archive:
    for file in root.rglob("*"):
        if file.is_file():
            archive.write(file, "Payload/Locus.app/" + file.relative_to(root).as_posix())
with zipfile.ZipFile(artifact) as archive:
    assert archive.testzip() is None
print(artifact)
