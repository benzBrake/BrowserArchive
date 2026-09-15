#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${PROXY:-}" ]]; then export https_proxy="$PROXY" http_proxy="$PROXY"; fi
PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"

$PY - <<'EOF'
import datetime, json, os, re, urllib.parse, urllib.request

API = "https://autoupdate.geo.opera.com/api/verify"
FTP = "https://get.opera.com/ftp/pub/"
# Product names are deliberately centralized: Opera may add/remove GX channels.
PRODUCTS = {
    "opera": {"name": "Opera", "channels": {
        "stable": ("Opera", "opera"),
        "developer": ("Opera Developer", "opera-developer")}},
    "opera_gx": {"name": "Opera GX", "channels": {
        "stable": ("Opera GX", "opera_gx")}},
}

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "BrowserArchive/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r: return r.read().decode("utf-8", "replace")

def version(product):
    raw = get(API + "?" + urllib.parse.urlencode({"product": product, "version": "0.0.0.0"}))
    try:
        obj = json.loads(raw)
        text = json.dumps(obj)
    except Exception: text = raw
    versions = re.findall(r"\b\d+(?:\.\d+){2,3}\b", text)
    if not versions: raise RuntimeError(f"unable to parse version for {product}: {raw[:200]}")
    return max(versions, key=lambda v: tuple(map(int, v.split('.'))))

def files(directory, ver):
    # FTP uses both flat listings (opera/desktop) and version subdirectories
    # (opera/desktop/<version>, opera-developer/<version>); inspect three levels.
    root = FTP + directory.strip('/') + '/'
    queue, candidates = [(root, 0, False)], []
    seen = set()
    while queue:
        url, depth, in_version = queue.pop(0)
        if url in seen or depth > 3: continue
        seen.add(url)
        html = get(url)
        for h in re.findall(r'href=["\']([^"\']+)["\']', html, re.I):
            name = urllib.parse.unquote(h)
            if name in ('../', './') or h.startswith('?'): continue
            if (in_version or ver in name) and not h.endswith('/'):
                candidates.append((urllib.parse.urljoin(url, h), name))
            elif h.endswith('/') and depth < 3 and (ver in name or directory == 'opera'):
                queue.append((urllib.parse.urljoin(url, h), depth + 1, in_version or ver in name))
    out = {}
    for arch, suffix in {"x64": "_x64", "arm64": "_arm64", "x86": None}.items():
        hits = [(u, n) for u, n in candidates
                if n.lower().endswith((".exe", ".msi")) and
                ((suffix and suffix in n.lower()) or (suffix is None and n.lower().endswith("_setup.exe")))]
        # Opera's default Windows installer (without an arch suffix) is x86.
        if hits:
            url, name = hits[0]
            out[arch] = {"filename": name, "url": url}
    if not out: raise RuntimeError(f"no Windows installers for {directory} {ver}")
    return out

result = {"schema_version": 2, "name": "Opera", "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"), "source": API, "products": {}}
for key, spec in PRODUCTS.items():
    chans = {}
    for channel, (product, directory) in spec["channels"].items():
        try:
            ver = version(product); chans[channel] = {"version": ver, "files": files(directory, ver), "source": API + "?product=" + urllib.parse.quote(product) + "&version=0.0.0.0"}
            print(f"{product}: {ver}")
        except Exception as e:
            if key == "opera" or channel == "stable": raise
            print(f"warn: skipping {product}: {e}")
    if chans: result["products"][key] = {"name": spec["name"], "version": chans["stable"]["version"], "channels": chans}
result["version"] = result["products"]["opera"]["version"]
path = os.path.join(os.environ["REPO_DIR"], "data", "opera.json")
with open(path, "w", encoding="utf-8") as f: json.dump(result, f, indent=2, ensure_ascii=False); f.write("\n")
EOF
