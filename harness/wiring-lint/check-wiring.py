#!/usr/bin/env python3
"""Stage 3 wiring/config lint + live endpoint + CORS probe.

Validates that each frontend's *actual* wiring matches the tech-design v2.8
port map (port-map.json):

  1. STATIC  - vite.config.ts `server.proxy['/api']` target port
  2. STATIC  - runtime base URL (VITE_*_API_BASE in .env.local) port
  3. RUNTIME - reachability + (optional) non-empty data for each endpoint
  4. CORS    - cross-origin GET must return Access-Control-Allow-Origin,
               otherwise the browser blocks it -> "Failed to fetch"

CONFIG mismatches (1&2) are code defects -> exit 1 (CI blocking).
CORS gaps (4) are very likely the "Failed to fetch" root cause -> WARN with a
fix hint (add CORS headers on the backend / dev proxy).
Unreachable services / empty data (3) are environment/seed issues -> WARN.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PORTMAP = json.loads((HERE / "port-map.json").read_text())
ORIGIN = "http://localhost:5173"  # any cross-origin dev URL exercises CORS

PASS = "PASS"
WARN = "WARN"
FAIL = "FAIL"
CONFIG_FAILS = 0
ENV_WARNS = 0


def find_proxy_port(repo: str):
    cfg = ROOT / repo / "vite.config.ts"
    if not cfg.exists():
        return None, "no vite.config.ts in " + repo
    txt = cfg.read_text()
    m = re.search(r"proxy\s*:\s*\{[^}]*['\"]/api['\"]\s*:\s*['\"]http://localhost:(\d+)", txt)
    if not m:
        return None, "could not parse proxy target"
    return int(m.group(1)), None


def find_runtime_port(repo: str, env_var: str):
    env = ROOT / repo / ".env.local"
    if not env.exists():
        return None, "no .env.local (runtime base defaults to proxy)"
    for line in env.read_text().splitlines():
        if line.strip().startswith(env_var):
            m = re.search(r"localhost:(\d+)", line)
            if m:
                return int(m.group(1)), None
    return None, env_var + " not set in .env.local"


def probe_get(base: str, path: str, expect_data: bool):
    url = base + path
    try:
        req = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=4) as r:
            body = r.read().decode("utf-8", "replace")
            code = r.status
    except Exception as e:  # noqa: BLE001
        return None, None, "UNREACHABLE (" + type(e).__name__ + ")"
    if code >= 400:
        return code, body, "HTTP " + str(code)
    if expect_data:
        stripped = body.strip()
        if stripped in ("", "null", "[]", '{"data":null}', '{"data": null}') or '"data":null' in body or '"data": null' in body:
            return code, body, "HTTP " + str(code) + " but body looks empty (" + stripped[:40] + ")"
    return code, body, "HTTP " + str(code)


def cors_probe(base: str, path: str):
    url = base + path
    try:
        req = urllib.request.Request(
            url, method="GET", headers={"Origin": ORIGIN, "Accept": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=4) as r:
            acao = r.headers.get("Access-Control-Allow-Origin")
            code = r.status
    except urllib.error.HTTPError as e:
        acao = e.headers.get("Access-Control-Allow-Origin")
        code = e.code
    except Exception as e:  # noqa: BLE001
        return None, "UNREACHABLE (" + type(e).__name__ + ")"
    if not acao:
        return code, "NO ACAO header (browser cross-origin GET blocked -> 'Failed to fetch')"
    return code, "CORS ok (ACAO=" + acao + ")"


def check_frontend(name: str, spec: dict):
    global CONFIG_FAILS, ENV_WARNS
    repo = spec["repo"]
    print("\n=== " + name + " (" + repo + ") ===")
    exp_proxy = spec["expectedProxyPort"]
    exp_runtime = spec["expectedRuntimeBasePort"]

    proxy_port, err = find_proxy_port(repo)
    if err:
        print("  [proxy] " + WARN + ": " + err)
        ENV_WARNS += 1
    elif proxy_port != exp_proxy:
        print("  [proxy] " + FAIL + ": vite proxy -> :" + str(proxy_port) + " (expected :" + str(exp_proxy) + ")")
        CONFIG_FAILS += 1
    else:
        print("  [proxy] " + PASS + ": vite proxy -> :" + str(proxy_port))

    rt_port, err = find_runtime_port(repo, spec["proxyEnvVar"])
    if rt_port is None:
        print("  [runtime] " + WARN + ": " + err)
    elif rt_port != exp_runtime:
        print("  [runtime] " + FAIL + ": VITE base -> :" + str(rt_port) + " (expected :" + str(exp_runtime) + ")")
        CONFIG_FAILS += 1
    else:
        print("  [runtime] " + PASS + ": VITE base -> :" + str(rt_port))

    for ep in spec.get("endpoints", []):
        if ep["method"] != "GET":
            print("  [probe] " + ep["method"] + " " + ep["path"] + " : skipped (non-GET)")
            continue
        code, body, msg = probe_get(spec["probeBase"], ep["path"], ep.get("expectNonEmptyData", False))
        if code is None:
            print("  [probe] " + WARN + ": " + ep["method"] + " " + ep["path"] + " -> " + msg)
            ENV_WARNS += 1
        elif "empty" in msg:
            print("  [probe] " + WARN + ": " + ep["method"] + " " + ep["path"] + " -> " + msg)
            ENV_WARNS += 1
        else:
            snippet = ""
            if ep.get("expectNonEmptyData", False) and body is not None:
                snippet = "  body=" + body.strip()[:80].replace("\n", " ")
            print("  [probe] " + PASS + ": " + ep["method"] + " " + ep["path"] + " -> " + msg + snippet)
        ccode, cmsg = cors_probe(spec["probeBase"], ep["path"])
        if ccode is None:
            print("  [cors ] " + WARN + ": " + ep["path"] + " -> " + cmsg)
            ENV_WARNS += 1
        elif "NO ACAO" in cmsg:
            print("  [cors ] " + WARN + ": " + ep["path"] + " -> " + cmsg)
            ENV_WARNS += 1
        else:
            print("  [cors ] " + PASS + ": " + ep["path"] + " -> " + cmsg)


def main():
    for name, spec in PORTMAP.items():
        check_frontend(name, spec)
    print("\n" + "=" * 64)
    print("CONFIG mismatches (code defects): " + str(CONFIG_FAILS))
    print("ENV/WARN (start stack, seed, or add CORS): " + str(ENV_WARNS))
    if CONFIG_FAILS:
        print("RESULT: FAIL - fix the frontend wiring/config before merge.")
        sys.exit(1)
    print("RESULT: OK (config matches port map; address WARNs: start stack / seed / CORS).")
    sys.exit(0)


if __name__ == "__main__":
    main()
