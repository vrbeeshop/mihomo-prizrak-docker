#!/usr/bin/env python3
"""Generate release notes from metadata inside the published Docker image."""

import argparse
from pathlib import Path
import re

CORE_REPO = "https://github.com/legiz-ru/Prizrak-Core"


def read_metadata(path):
    metadata = {}
    for line in Path(path).read_text().splitlines():
        if not line:
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or not value or key in metadata:
            raise ValueError("Invalid or duplicate image build metadata")
        metadata[key] = value
    required = {
        "version", "commit", "project_version", "go_version", "builder_image",
        "runtime_image", "runtime_os_name", "runtime_os_version", "platform",
        "with_gvisor", "upx",
    }
    if missing := required - metadata.keys():
        raise ValueError("Image build metadata is missing: " + ", ".join(sorted(missing)))
    return metadata


def render(metadata, version, core_version, core_commit, image, digest, source_commit):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Project version must be numeric SemVer")
    if metadata["project_version"] != version:
        raise ValueError("Published image has an unexpected project version")
    if metadata["version"] != core_version or metadata["commit"] != core_commit:
        raise ValueError("Published core differs from the tested core release")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", core_version):
        raise ValueError("Invalid core release tag")
    if not re.fullmatch(r"[0-9a-f]{40}", core_commit) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Invalid source commit")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Invalid published image digest")
    if not re.fullmatch(r"ghcr\.io/[a-z0-9._/-]+", image):
        raise ValueError("Invalid GHCR image name")
    if metadata["platform"] != "linux/amd64":
        raise ValueError("Release metadata must come from the published amd64 image")
    if metadata["with_gvisor"] != "0" or metadata["upx"] != "0":
        raise ValueError("Published image must use the Standard build variant")

    def cell(value):
        return value.replace("|", r"\|").replace("`", "")

    rows = [
        ("Проект", version),
        ("Prizrak-Core", f"[{core_version}]({CORE_REPO}/releases/tag/{core_version})"),
        ("Коммит Prizrak-Core", f"[{core_commit}]({CORE_REPO}/commit/{core_commit})"),
        ("Go", cell(metadata["go_version"])),
        ("Образ сборщика", cell(metadata["builder_image"])),
        ("Базовый образ amd64", cell(metadata["runtime_image"])),
        ("ОС внутри amd64", cell(metadata["runtime_os_name"] + " " + metadata["runtime_os_version"])),
        ("Вариант", "Standard (`WITH_GVISOR=0`, `UPX=0`)"),
    ]
    lines = [
        f"Prizrak-Core Docker {version}", "", "Состав опубликованного образа:", "",
        "| Компонент | Версия |", "| --- | --- |",
    ]
    lines += [f"| {name} | {value} |" for name, value in rows]
    lines += [
        "", "Одна версия и один коммит Prizrak-Core используются для всех архитектур:",
        "`linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/arm/v5`.", "",
        f"Образы: `{image}:{version}` и `{image}:latest`.",
        f"Неизменяемая ссылка: `{image}@{digest}`.",
        f"Коммит проекта: `{source_commit}`.", "",
        "Zashboard загружается при запуске контейнера и не входит в состав образа.", "",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("metadata", "version", "core-version", "core-commit", "image", "digest", "source-commit", "output"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        notes = render(read_metadata(args.metadata), args.version, args.core_version, args.core_commit,
                       args.image, args.digest, args.source_commit)
    except ValueError as error:
        parser.error(str(error))
    Path(args.output).write_text(notes)


if __name__ == "__main__":
    main()
