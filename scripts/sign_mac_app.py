#!/usr/bin/env python3
"""Use an existing code-signing identity without changing the user's Keychain."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def choose_identity(output, selected=None):
    entries = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"\s*$', output, re.MULTILINE)
    identities = {fingerprint.upper(): name for fingerprint, name in entries}
    if selected:
        value = selected.upper()
        if value not in identities:
            raise ValueError("METZ_SIGNING_IDENTITY must identify an existing valid signing certificate")
        return value
    if len(identities) != 1:
        raise ValueError("Choose an existing certificate with METZ_SIGNING_IDENTITY; ad-hoc signing resets capture permissions")
    return next(iter(identities))


def main():
    if len(sys.argv) != 2:
        raise ValueError("Expected one application bundle")
    bundle = Path(sys.argv[1]).resolve()
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") not in {"com.metzrevive.manager", "com.metzrevive.display.mac"}:
        raise ValueError("Unexpected application identifier")
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            check=True, capture_output=True, text=True, timeout=15)
    identity = choose_identity(result.stdout, os.environ.get("METZ_SIGNING_IDENTITY"))
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(bundle)],
                   check=True, capture_output=True, timeout=45)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)],
                   check=True, capture_output=True, timeout=15)
    print("Signed and verified with an existing certificate; Keychain unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.SubprocessError) as error:
        # Do not print certificate owner names, signing output or credential details.
        sys.exit(str(error) if isinstance(error, ValueError) else "Code signing failed; no credential changes made")
