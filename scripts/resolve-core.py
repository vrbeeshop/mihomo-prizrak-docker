#!/usr/bin/env python3
"""Resolve one stable Prizrak-Core release for every build in a CI run."""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com/repos/legiz-ru/Prizrak-Core"
TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
SHA = re.compile(r"[0-9a-f]{40}")


def fetch_json(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "prizrak-docker-ci"}
    if token := os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(API + path, headers=headers)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code < 500:
                raise
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def resolve_latest(fetch=fetch_json):
    release = fetch("/releases/latest")
    tag = release.get("tag_name", "")
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        raise ValueError("GitHub returned an invalid Prizrak-Core release tag")
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("Prizrak-Core release must be stable and published")

    reference = fetch("/git/ref/tags/" + urllib.parse.quote(tag, safe=""))
    obj = reference.get("object", {})
    seen = set()
    for _ in range(10):
        sha = obj.get("sha", "")
        if not isinstance(sha, str) or not SHA.fullmatch(sha) or sha in seen:
            raise ValueError("GitHub returned an invalid or cyclic tag reference")
        if obj.get("type") == "commit":
            return {"prizrak_version": tag, "prizrak_commit": sha}
        if obj.get("type") != "tag":
            raise ValueError("Prizrak-Core release tag does not point to a commit")
        seen.add(sha)
        obj = fetch("/git/tags/" + sha).get("object", {})
    raise ValueError("Too many nested Prizrak-Core tag references")


def main():
    try:
        for key, value in resolve_latest().items():
            print(f"{key}={value}")
    except (ValueError, KeyError, TypeError, urllib.error.URLError, TimeoutError) as error:
        print(f"Unable to resolve Prizrak-Core: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
