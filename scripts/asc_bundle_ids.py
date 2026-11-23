#!/usr/bin/env python3
"""Prints the capabilities of the App IDs used by an app (diagnostics for
testflight.yml): helps spot an App Group / iCloud container that is not
enabled on developer.apple.com.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.  Args: bundle identifiers.
"""
import sys
import urllib.parse

from asc_revoke_certs import call


def main(ids):
    for ident in ids:
        q = urllib.parse.urlencode({"filter[identifier]": ident, "include": "bundleIdCapabilities", "limit": 20})
        r = call("GET", f"/bundleIds?{q}")
        match = [b for b in r.get("data", []) if b["attributes"]["identifier"] == ident]
        if not match:
            print(f"::warning::App ID {ident} non registrato (lo crea la firma automatica)")
            continue
        caps = sorted(i["attributes"]["capabilityType"] for i in r.get("included", []) if i["type"] == "bundleIdCapabilities")
        print(f"{ident}: {', '.join(caps) or 'nessuna capability'}")


if __name__ == "__main__":
    main(sys.argv[1:])
