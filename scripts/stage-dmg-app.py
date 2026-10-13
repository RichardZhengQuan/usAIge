#!/usr/bin/env python3
"""Copy a built app into an installer without losing executable permissions."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat


def application_executable(application: Path) -> Path:
    if application.is_symlink() or not application.is_dir() or application.suffix != ".app":
        raise ValueError("Expected a regular .app directory: {}".format(application))
    with (application / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    if not isinstance(metadata, dict):
        raise ValueError("The app has an invalid Info.plist")
    executable = metadata.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or len(executable) > 128 or any(
        character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        for character in executable
    ) or executable in (".", ".."):
        raise ValueError("The app has an invalid executable name")
    path = application / "Contents/MacOS" / executable
    information = path.lstat()
    if not stat.S_ISREG(information.st_mode) or not information.st_mode & 0o111 or not os.access(path, os.X_OK):
        raise ValueError("App executable has no usable execute permission: {}".format(path))
    return path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def copy_application(source: Path, destination: Path) -> None:
    source = source.absolute()
    destination = destination.absolute()
    executable = application_executable(source)
    if destination.suffix != ".app" or destination.is_symlink():
        raise ValueError("Expected a nonsymlink .app destination")
    source_real, destination_real = source.resolve(), destination.resolve()
    if source_real == destination_real or source_real in destination_real.parents or destination_real in source_real.parents:
        raise ValueError("Source and destination app directories must be separate")
    if destination.exists() and not destination.is_dir():
        raise ValueError("The app destination is not a directory")

    # Replace the whole old bundle. Merging can retain stale signed resources.
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # copyfile preserves bytes but drops the execute bit. copy2 preserves the
    # app's file modes and timestamps; symlinks retain their original targets.
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
    staged = application_executable(destination)
    if stat.S_IMODE(staged.stat().st_mode) != stat.S_IMODE(executable.stat().st_mode):
        raise ValueError("Staged executable permissions do not match the built app")
    if digest(staged) != digest(executable):
        raise ValueError("Staged executable bytes do not match the built app")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    try:
        copy_application(arguments.source, arguments.destination)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, "Cannot stage installer app: {}\n".format(error))


if __name__ == "__main__":
    main()
