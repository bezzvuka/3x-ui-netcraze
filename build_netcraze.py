import os
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

cache = Path("/src/.build-cache")
cache.mkdir(parents=True, exist_ok=True)
tmp = Path("/tmp/netcraze-build")
tmp.mkdir(parents=True, exist_ok=True)


def download(url: str, destination: Path) -> None:
    for attempt in range(20):
        offset = destination.stat().st_size if destination.exists() else 0
        request = urllib.request.Request(url, headers={"Range": f"bytes={offset}-"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                append = offset > 0 and response.status == 206
                mode = "ab" if append else "wb"
                expected = int(response.headers.get("Content-Length", "0")) + (offset if append else 0)
                print(f"Downloading {url} from byte {offset if append else 0}", flush=True)
                with destination.open(mode) as output:
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                if expected and destination.stat().st_size != expected:
                    raise IOError(f"incomplete download: {destination.stat().st_size}/{expected}")
            return
        except urllib.error.HTTPError as error:
            if error.code == 416 and destination.exists():
                return
            if attempt == 19:
                raise
            print(f"Download interrupted: {error}; retrying", flush=True)
            time.sleep(min(attempt + 1, 10))
        except Exception as error:
            if attempt == 19:
                raise
            print(f"Download interrupted: {error}; retrying", flush=True)
            time.sleep(min(attempt + 1, 10))


go_archive = cache / "go1.26.5.linux-amd64.tar.gz"
download("https://go.dev/dl/go1.26.5.linux-amd64.tar.gz", go_archive)
with tarfile.open(go_archive) as archive:
    archive.extractall(tmp, filter="data")

base_url = "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs"
toolchain_name = "aarch64--musl--stable-2025.08-1.tar.xz"
toolchain_archive = cache / toolchain_name
download(f"{base_url}/{toolchain_name}", toolchain_archive)
with tarfile.open(toolchain_archive) as archive:
    archive.extractall(tmp, filter="data")

toolchain = next(tmp.glob("aarch64--musl--stable-*"))
cc = next((toolchain / "bin").glob("*-gcc.br_real"))
env = os.environ.copy()
env.update({"CGO_ENABLED": "1", "GOOS": "linux", "GOARCH": "arm64", "CC": str(cc)})

subprocess.run(
    [
        str(tmp / "go" / "bin" / "go"),
        "build",
        "-ldflags",
        "-w -s -linkmode external -extldflags '-static'",
        "-o",
        "x-ui-netcraze",
        "main.go",
    ],
    check=True,
    env=env,
)
