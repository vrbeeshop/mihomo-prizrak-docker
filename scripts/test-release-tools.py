#!/usr/bin/env python3
"""Offline tests for release resolution and published-image release notes."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resolver = load_script("resolve-core")
notes = load_script("release-notes")
CORE = "c" * 40
SOURCE = "d" * 40
DIGEST = "sha256:" + "e" * 64


class ReleaseToolsTests(unittest.TestCase):
    def test_stable_release_peels_annotated_tag(self):
        objects = {
            "/releases/latest": {"tag_name": "v1.2.3-r1", "prerelease": False},
            "/git/ref/tags/v1.2.3-r1": {"object": {"type": "tag", "sha": "a" * 40}},
            "/git/tags/" + "a" * 40: {"object": {"type": "commit", "sha": CORE}},
        }
        self.assertEqual(resolver.resolve_latest(objects.__getitem__),
                         {"prizrak_version": "v1.2.3-r1", "prizrak_commit": CORE})

    def test_invalid_upstream_releases_fail(self):
        for response in ({"tag_name": "v1.2.3\nextra=value"},
                         {"tag_name": "v1.2.3", "prerelease": True}):
            with self.subTest(response=response), self.assertRaises(ValueError):
                resolver.resolve_latest(lambda _: response)

    def test_cyclic_or_invalid_tag_objects_fail(self):
        for obj in ({"type": "blob", "sha": CORE}, {"type": "commit", "sha": "broken"},
                    {"type": "tag", "sha": CORE}):
            def fetch(path):
                return {"tag_name": "v1.2.3"} if path == "/releases/latest" else {"object": obj}
            with self.subTest(obj=obj), self.assertRaises(ValueError):
                resolver.resolve_latest(fetch)

    def metadata(self):
        return {"version": "v1.2.3-r1", "commit": CORE, "project_version": "0.1.0",
                "go_version": "go1.26.11", "builder_image": "golang:1.26-alpine",
                "runtime_image": "alpine:3.23", "runtime_os_name": "Alpine Linux",
                "runtime_os_version": "3.23.2", "platform": "linux/amd64",
                "with_gvisor": "0", "upx": "0"}

    def render(self, metadata):
        return notes.render(metadata, "0.1.0", "v1.2.3-r1", CORE,
                            "ghcr.io/example/prizrak", DIGEST, SOURCE)

    def test_notes_record_actual_published_versions(self):
        result = self.render(self.metadata())
        for expected in ("v1.2.3-r1", CORE, "go1.26.11", "Alpine Linux 3.23.2",
                         "ghcr.io/example/prizrak:0.1.0", "ghcr.io/example/prizrak:latest", DIGEST):
            self.assertIn(expected, result)

    def test_mismatched_published_build_is_rejected(self):
        for key, value in (("version", "v9.9.9"), ("commit", "a" * 40),
                           ("project_version", "0.2.0"), ("with_gvisor", "1"),
                           ("upx", "1"), ("platform", "linux/arm64")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.render(dict(self.metadata(), **{key: value}))

    def test_metadata_is_data_and_never_executed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build-info"
            metadata = self.metadata()
            metadata["go_version"] = "$(false)"
            path.write_text("\n".join(f"{key}={value}" for key, value in metadata.items()))
            self.assertEqual(notes.read_metadata(path)["go_version"], "$(false)")
            path.write_text(path.read_text() + "\nversion=duplicate\n")
            with self.assertRaises(ValueError):
                notes.read_metadata(path)


if __name__ == "__main__":
    unittest.main()
