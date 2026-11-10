#!/usr/bin/env python3
"""Check the real installer payload without installing or restarting audio."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class MicrophonePackageTests(unittest.TestCase):
    def test_restrictive_source_permissions_do_not_restrict_installed_driver(self):
        output = ROOT / ".artifacts/microphone-investigation"
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="package-", dir=output) as temporary:
            work = Path(temporary)
            fixture = work / "source"
            for directory in ["Drivers/DuoMicrophone", "Sources/DuoMicrophoneBridge/include",
                              "Scripts/MicrophoneInstaller"]:
                shutil.copytree(ROOT / directory, fixture / directory, copy_function=shutil.copyfile)
            for name in ["build-environment.sh", "build-microphone-driver.sh"]:
                shutil.copyfile(ROOT / "Scripts" / name, fixture / "Scripts" / name)
            for path in fixture.rglob("*"):
                path.chmod(0o700 if path.is_dir() or path.suffix == ".sh" or path.name == "postinstall" else 0o600)

            environment = dict(os.environ, DUO_BUILD_ROOT=str(work / "build"))
            subprocess.run(["/bin/bash", str(fixture / "Scripts/build-microphone-driver.sh")],
                           env=environment, umask=0o077, check=True, capture_output=True)
            expanded = work / "expanded"
            subprocess.run(["/usr/sbin/pkgutil", "--expand-full",
                            str(work / "build/microphone/DuoMicrophone.pkg"), str(expanded)],
                           check=True, capture_output=True)
            payload = expanded / "Payload"
            driver = payload / "Library/Audio/Plug-Ins/HAL/DuoMicrophone.driver"
            for path in [payload, *payload.rglob("*")]:
                if path.is_dir():
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755, str(path))
            for name in ["Contents/Info.plist", "Contents/_CodeSignature/CodeResources"]:
                self.assertEqual(stat.S_IMODE((driver / name).stat().st_mode), 0o644, name)
            self.assertEqual(stat.S_IMODE((driver / "Contents/MacOS/DuoMicrophone").stat().st_mode), 0o755)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(driver)],
                           check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
