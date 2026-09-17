#!/usr/bin/env python3
"""Exercise Sparkle against a disposable app on the GitHub runner, never locally."""
import functools
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("The update installation test runs only on GitHub Actions.")
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    framework = root / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    source = root / ".build/checkouts/Sparkle/sparkle-cli"
    tools = root / ".build/artifacts/sparkle/Sparkle/bin"
    app = root / "build/UsageBar.app"
    with (app / "Contents/Info.plist").open("rb") as file:
        version = plistlib.load(file)["CFBundleVersion"]
    archive, = (root / "build/sparkle").glob("*.zip")
    secret = os.environ["SPARKLE_PRIVATE_KEY"].encode()

    with tempfile.TemporaryDirectory(prefix="usagebar-update-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        work = Path(temporary)
        cli = work / "sparkle-cli"
        # Build Sparkle's own command-line user driver against the pinned framework.
        run("clang", "-fobjc-arc", "-DSPU_OBJC_DIRECT=", "-DSPU_OBJC_DIRECT_MEMBERS=",
            "-F", framework, "-framework", "Foundation", "-framework", "AppKit", "-framework", "Sparkle",
            source / "main.m", source / "SPUCommandLineDriver.m", source / "SPUCommandLineUserDriver.m",
            f"-Wl,-rpath,{framework}", "-o", cli)
        host = work / "UsageBar.app"
        run("ditto", app, host)
        plist = host / "Contents/Info.plist"
        with plist.open("rb") as file:
            info = plistlib.load(file)
        info.update(CFBundleVersion="0.0.0", CFBundleShortVersionString="0.0.0")
        with plist.open("wb") as file:
            plistlib.dump(info, file)
        run("codesign", "--force", "--sign", "-", host)

        webroot = work / "feed"
        webroot.mkdir()
        served_archive = webroot / archive.name
        shutil.copyfile(archive, served_archive)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(webroot)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            prefix = f"http://127.0.0.1:{server.server_port}/"
            feed = webroot / "appcast.xml"
            feed.write_text((root / "build/sparkle/appcast.xml").read_text().replace(
                f"https://github.com/kubilayege/UsageBar/releases/download/v{version}/", prefix))
            run(tools / "sign_update", "--ed-key-file", "-", feed, input=secret)

            def check(feed_name="appcast.xml", probe=False, succeeds=True):
                result = subprocess.run([str(cli), str(host), "--feed-url", prefix + feed_name,
                    "--probe" if probe else "--check-immediately", "--verbose"],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
                print(result.stdout, flush=True)
                if succeeds and result.returncode != 0:
                    raise RuntimeError(f"Sparkle update failed ({result.returncode})")
                if not succeeds and result.returncode != 1:
                    raise RuntimeError(f"Expected Sparkle to reject the modified update ({result.returncode})")

            check(probe=True)
            # Signed feeds must reject even an innocuous edit to their contents.
            (webroot / "modified.xml").write_text(feed.read_text().replace("</channel>", "<!-- modified -->\n</channel>"))
            check("modified.xml", probe=True, succeeds=False)
            # Keep the byte count unchanged so only the archive signature can catch this.
            with served_archive.open("r+b") as file:
                first = file.read(1)
                file.seek(0)
                file.write(bytes([first[0] ^ 1]))
            check(succeeds=False)
            with plist.open("rb") as file:
                assert plistlib.load(file)["CFBundleVersion"] == "0.0.0", "Rejected update changed the host"
            shutil.copyfile(archive, served_archive)
            check()
            with plist.open("rb") as file:
                assert plistlib.load(file)["CFBundleVersion"] == version, "Sparkle did not replace the app"
            run("codesign", "--verify", "--deep", "--strict", host)
            result = subprocess.run([str(cli), str(host), "--feed-url", prefix + "appcast.xml", "--probe", "--verbose"], timeout=60)
            assert result.returncode == 4, "Installed version should report no update"
            print(f"Verified Sparkle installation 0.0.0 → {version}, no-update detection, and tamper rejection")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
