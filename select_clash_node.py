#!/usr/bin/env python3
"""Select the best Clash Verge/Mihomo node by multi-site scoring.

The script talks to Mihomo's external-controller API, tests every real node in
one selector group against several commonly accelerated sites, ranks nodes by
success rate and latency, and optionally switches the selector to the winner.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import re
import socket
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Iterable


DEFAULT_APIS = (
    "http://127.0.0.1:9097",
    "http://127.0.0.1:9090",
)

DEFAULT_SECRET = "set-your-secret"

DEFAULT_TARGETS = (
    ("google", "https://www.google.com/generate_204", 1.2),
    ("gstatic", "https://www.gstatic.com/generate_204", 0.8),
    ("github", "https://github.com/", 1.2),
    ("github_assets", "https://github.githubassets.com/favicons/favicon.svg", 1.4),
    ("github_avatar", "https://avatars.githubusercontent.com/u/9919?v=4", 1.3),
    ("github_api", "https://api.github.com/rate_limit", 1.0),
    ("github_raw", "https://raw.githubusercontent.com/github/gitignore/main/README.md", 1.1),
    ("openai_api", "https://api.openai.com/v1/models", 1.3),
    ("chatgpt", "https://chatgpt.com/", 1.3),
    ("youtube", "https://www.youtube.com/generate_204", 0.8),
    ("cloudflare", "https://www.cloudflare.com/cdn-cgi/trace", 0.5),
)

GROUP_PROXY_TYPES = {
    "Compatible",
    "Direct",
    "Fallback",
    "LoadBalance",
    "Reject",
    "Relay",
    "Selector",
    "URLTest",
}


class ClashApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class Target:
    name: str
    url: str
    weight: float


@dataclass
class CheckResult:
    node: str
    target: str
    ok: bool
    delay_ms: int | None = None
    error: str = ""


@dataclass
class NodeScore:
    node: str
    possible_weight: float
    total_checks: int
    success_weight: float = 0.0
    success_checks: int = 0
    delays_ms: list[int] = field(default_factory=list)
    target_successes: dict[str, int] = field(default_factory=dict)
    target_errors: dict[str, str] = field(default_factory=dict)

    @property
    def success_ratio(self) -> float:
        if self.total_checks <= 0:
            return 0.0
        return self.success_checks / self.total_checks

    @property
    def avg_delay(self) -> float:
        if not self.delays_ms:
            return math.inf
        return statistics.fmean(self.delays_ms)

    @property
    def max_delay(self) -> float:
        if not self.delays_ms:
            return math.inf
        return float(max(self.delays_ms))

    @property
    def stdev_delay(self) -> float:
        if len(self.delays_ms) < 2:
            return 0.0
        return statistics.pstdev(self.delays_ms)

    @property
    def score(self) -> float:
        return (
            self.success_weight * 100000.0
            - self.avg_delay
            - self.max_delay * 0.20
            - self.stdev_delay * 0.15
        )

    def fully_passed_targets(self, rounds: int) -> int:
        return sum(1 for count in self.target_successes.values() if count >= rounds)


def parse_target(value: str) -> Target:
    parts = [part.strip() for part in value.split(",", 2)]
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError("target format must be name,url[,weight]")

    name, url = parts[0], parts[1]
    weight = 1.0

    if not name or not url:
        raise argparse.ArgumentTypeError("target name and URL cannot be empty")
    if len(parts) == 3:
        try:
            weight = float(parts[2])
        except ValueError as exc:
            raise argparse.ArgumentTypeError("target weight must be numeric") from exc
    if weight <= 0:
        raise argparse.ArgumentTypeError("target weight must be positive")

    return Target(name=name, url=url, weight=weight)


def default_targets() -> list[Target]:
    return [Target(name, url, weight) for name, url, weight in DEFAULT_TARGETS]


def build_auth_header(secret: str) -> dict[str, str]:
    headers = {"Accept": "application/json"}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    return headers


def request_json(
    api_base: str,
    secret: str,
    method: str,
    path: str,
    body: object | None = None,
    timeout: float = 10.0,
) -> object | None:
    data = None
    headers = build_auth_header(secret)

    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"

    url = api_base.rstrip("/") + path
    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:240]
        raise ClashApiError(f"{method} {url} returned HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
        raise ClashApiError(f"{method} {url} failed: {exc}") from exc


def probe_api(api_base: str, secret: str, timeout: float) -> bool:
    try:
        payload = request_json(api_base, secret, "GET", "/version", timeout=timeout)
    except ClashApiError:
        return False
    return isinstance(payload, dict)


def discover_api(candidates: Iterable[str], secret: str, timeout: float) -> str:
    tried = []
    for api_base in candidates:
        api_base = api_base.rstrip("/")
        if not api_base:
            continue
        tried.append(api_base)
        if probe_api(api_base, secret, timeout):
            return api_base

    joined = ", ".join(tried) or "<none>"
    raise ClashApiError(
        "cannot reach Mihomo external-controller. Tried: "
        f"{joined}. Enable Clash Verge external controller, or pass --api."
    )


def get_proxy_catalog(api_base: str, secret: str, group_name: str) -> tuple[dict, dict]:
    payload = request_json(api_base, secret, "GET", "/proxies")
    if not isinstance(payload, dict) or not isinstance(payload.get("proxies"), dict):
        raise ClashApiError("/proxies returned an unexpected payload")

    proxies = payload["proxies"]
    group = proxies.get(group_name)
    if not isinstance(group, dict):
        raise ClashApiError(f"selector group not found: {group_name!r}")

    return group, proxies


def is_real_node(name: str, proxies: dict) -> bool:
    detail = proxies.get(name)
    if not isinstance(detail, dict):
        return False
    proxy_type = str(detail.get("type") or "")
    return proxy_type not in GROUP_PROXY_TYPES


def collect_candidates(
    group: dict,
    proxies: dict,
    include_regex: str,
    exclude_regex: str,
    limit: int,
) -> list[str]:
    names = group.get("all") or group.get("proxies") or []
    include_re = re.compile(include_regex, re.I) if include_regex else None
    exclude_re = re.compile(exclude_regex, re.I) if exclude_regex else None
    candidates = []
    seen = set()

    for name in names:
        if not isinstance(name, str) or not name or name in seen:
            continue
        if not is_real_node(name, proxies):
            continue
        if include_re and not include_re.search(name):
            continue
        if exclude_re and exclude_re.search(name):
            continue

        seen.add(name)
        candidates.append(name)
        if limit > 0 and len(candidates) >= limit:
            break

    return candidates


def measure_node_target(
    api_base: str,
    secret: str,
    node: str,
    target: Target,
    timeout_ms: int,
) -> CheckResult:
    encoded_node = urllib.parse.quote(node, safe="")
    encoded_url = urllib.parse.quote(target.url, safe="")
    path = f"/proxies/{encoded_node}/delay?timeout={timeout_ms}&url={encoded_url}"
    timeout = max(2.0, timeout_ms / 1000.0 + 2.0)

    try:
        payload = request_json(api_base, secret, "GET", path, timeout=timeout)
        if not isinstance(payload, dict) or "delay" not in payload:
            return CheckResult(node=node, target=target.name, ok=False, error="missing delay")
        return CheckResult(
            node=node,
            target=target.name,
            ok=True,
            delay_ms=int(payload["delay"]),
        )
    except Exception as exc:  # noqa: BLE001 - keep testing remaining nodes.
        return CheckResult(node=node, target=target.name, ok=False, error=str(exc))


def score_nodes(
    api_base: str,
    secret: str,
    candidates: list[str],
    targets: list[Target],
    rounds: int,
    timeout_ms: int,
    jobs: int,
) -> list[NodeScore]:
    possible_weight = sum(target.weight for target in targets) * rounds
    total_checks = len(targets) * rounds
    scores = {
        node: NodeScore(
            node=node,
            possible_weight=possible_weight,
            total_checks=total_checks,
            target_successes={target.name: 0 for target in targets},
        )
        for node in candidates
    }
    target_map = {target.name: target for target in targets}

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        future_map = {}
        for node in candidates:
            for _ in range(rounds):
                for target in targets:
                    future = executor.submit(
                        measure_node_target,
                        api_base,
                        secret,
                        node,
                        target,
                        timeout_ms,
                    )
                    future_map[future] = (node, target)

        for future in concurrent.futures.as_completed(future_map):
            node, target = future_map[future]
            result = future.result()
            score = scores[node]

            if result.ok and result.delay_ms is not None:
                score.success_checks += 1
                score.success_weight += target.weight
                score.delays_ms.append(result.delay_ms)
                score.target_successes[target.name] += 1
            else:
                score.target_errors.setdefault(target.name, result.error)

    return sorted(
        scores.values(),
        key=lambda item: (
            -item.success_ratio,
            -item.success_weight,
            -item.fully_passed_targets(rounds),
            item.avg_delay,
            item.max_delay,
            item.stdev_delay,
            item.node,
        ),
    )


def select_node(api_base: str, secret: str, group_name: str, node: str) -> None:
    encoded_group = urllib.parse.quote(group_name, safe="")
    request_json(
        api_base,
        secret,
        "PUT",
        f"/proxies/{encoded_group}",
        body={"name": node},
        timeout=10.0,
    )


def close_connections(api_base: str, secret: str) -> None:
    request_json(api_base, secret, "DELETE", "/connections", timeout=10.0)


def fmt_delay(value: float) -> str:
    if math.isinf(value):
        return "-"
    return f"{round(value):d}ms"


def print_ranking(results: list[NodeScore], targets: list[Target], rounds: int, top: int) -> None:
    target_count = len(targets)
    print(f"{'rank':>4}  {'ok':>7}  {'avg':>7}  {'max':>7}  node")
    for index, item in enumerate(results[:top], 1):
        ok_targets = item.fully_passed_targets(rounds)
        print(
            f"{index:>4}  {ok_targets}/{target_count}"
            f" {item.success_checks}/{item.total_checks:<2}"
            f"  {fmt_delay(item.avg_delay):>7}"
            f"  {fmt_delay(item.max_delay):>7}  {item.node}"
        )

        failed = [
            target.name
            for target in targets
            if item.target_successes.get(target.name, 0) < rounds
        ]
        if failed:
            print("      failed: " + ", ".join(failed))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Score all Clash/Mihomo nodes against GitHub, Google, and other sites, then switch to the best one.",
    )
    parser.add_argument(
        "--api",
        action="append",
        default=[],
        help="Mihomo external-controller URL. Can repeat. Default tries 127.0.0.1:9097 and 127.0.0.1:9090.",
    )
    parser.add_argument(
        "--secret",
        default=os.environ.get("MIHOMO_SECRET")
        or os.environ.get("CLASH_SECRET")
        or DEFAULT_SECRET,
        help="Mihomo external-controller secret. Default: set-your-secret or MIHOMO_SECRET/CLASH_SECRET.",
    )
    parser.add_argument("--group", default="Proxy", help="Selector group to switch. Default: Proxy.")
    parser.add_argument("--rounds", type=int, default=1, help="Checks per node per target. Default: 1.")
    parser.add_argument("--jobs", type=int, default=8, help="Parallel checks. Default: 8.")
    parser.add_argument("--timeout-ms", type=int, default=5000, help="Per check timeout. Default: 5000.")
    parser.add_argument("--top", type=int, default=12, help="Rows to print. Default: 12.")
    parser.add_argument("--limit", type=int, default=0, help="Only test first N candidate nodes. Default: all.")
    parser.add_argument(
        "--target",
        action="append",
        type=parse_target,
        help="Target as name,url[,weight]. When supplied, replaces the default target list. Can repeat.",
    )
    parser.add_argument("--include-regex", default="", help="Only test node names matching this regex.")
    parser.add_argument("--exclude-regex", default="", help="Skip node names matching this regex.")
    parser.add_argument(
        "--min-success-ratio",
        type=float,
        default=1.0,
        help="Minimum successful checks ratio required before switching. Default: 1.0.",
    )
    parser.add_argument(
        "--keep-connections",
        action="store_true",
        help="Do not close existing Clash connections after switching.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print ranking but do not switch.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.rounds < 1:
        raise SystemExit("--rounds must be >= 1")
    if args.jobs < 1:
        raise SystemExit("--jobs must be >= 1")
    if args.timeout_ms < 1000:
        raise SystemExit("--timeout-ms must be >= 1000")
    if not 0 < args.min_success_ratio <= 1:
        raise SystemExit("--min-success-ratio must be in (0, 1]")

    targets = args.target or default_targets()
    api_candidates = args.api or list(DEFAULT_APIS)
    api_base = discover_api(api_candidates, args.secret, timeout=2.0)
    group, proxies = get_proxy_catalog(api_base, args.secret, args.group)
    candidates = collect_candidates(
        group=group,
        proxies=proxies,
        include_regex=args.include_regex,
        exclude_regex=args.exclude_regex,
        limit=args.limit,
    )

    if not candidates:
        raise SystemExit(f"No real proxy nodes found in group {args.group!r}.")

    current = group.get("now") or "-"
    print(f"Controller: {api_base}")
    print(f"Group: {args.group}  current: {current}")
    print(f"Candidates: {len(candidates)}")
    print("Targets: " + ", ".join(target.name for target in targets))

    started = time.monotonic()
    results = score_nodes(
        api_base=api_base,
        secret=args.secret,
        candidates=candidates,
        targets=targets,
        rounds=args.rounds,
        timeout_ms=args.timeout_ms,
        jobs=args.jobs,
    )
    elapsed = time.monotonic() - started

    print_ranking(results, targets, rounds=args.rounds, top=args.top)
    print(f"Finished in {elapsed:.1f}s")

    best = results[0]
    if best.success_ratio < args.min_success_ratio:
        print(
            "Best node did not meet min success ratio "
            f"({best.success_ratio:.0%} < {args.min_success_ratio:.0%}); not switching.",
            file=sys.stderr,
        )
        return 2

    if args.dry_run:
        print(f"Dry run: best node would be {best.node}")
        return 0

    select_node(api_base, args.secret, args.group, best.node)
    print(f"Selected {args.group} -> {best.node}")
    if not args.keep_connections:
        close_connections(api_base, args.secret)
        print("Closed existing connections so browsers use the new node.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ClashApiError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
