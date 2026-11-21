"""Run paired headless matches through the real loopback NANDA gateway."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@contextmanager
def service(command, env, log, cwd=HERE):
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def wait_for(url, process, acceptable=(200,)):
    for _ in range(70):
        if process.poll() is not None:
            break
        try:
            with urlopen(url, timeout=0.25) as response:
                status = response.status
        except URLError as exc:
            status = getattr(exc, "code", None)
        if status in acceptable:
            return
        time.sleep(0.1)
    raise RuntimeError(f"Service did not start at {url}; see the logs in the output directory")


def gateway_request(url, token, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = Request(url, data, {"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    with urlopen(request, timeout=3) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lune", default="lune")
    parser.add_argument("--output", type=Path, default=HERE / "output")
    args = parser.parse_args()
    output = args.output.resolve()
    model = output / "model.json"
    if not model.is_file():
        parser.error(f"Train the model with experiment.py first. Missing {model}")

    slot_token, harness_token = secrets.token_hex(24), secrets.token_hex(24)
    common_env = os.environ | {"SLOT_TOKEN": slot_token, "NANDA_HARNESS_TOKEN": harness_token}
    monitor_port = free_port()
    monitor = [sys.executable, str(HERE / "monitor.py"), "--model", str(model), "--port", str(monitor_port)]
    with service(monitor, common_env, output / "monitor.log") as monitor_process:
        monitor_url = f"http://localhost:{monitor_port}"
        wait_for(f"{monitor_url}/decide", monitor_process, acceptable=(501,))
        gateway_port = free_port()
        gateway_url = f"http://127.0.0.1:{gateway_port}"
        gateway = [
            sys.executable, "-u", "-m", "nanda_harness", "--host", "127.0.0.1", "--port", str(gateway_port),
            "--no-llm", "--allow-localhost", "--env-file", os.devnull, "--registry", "", "--log", "-",
            "--call-ms", "800", "--tick-ms", "900", "--max-bytes", "65536",
            "--per-server-per-minute", "200", "--per-ip-per-minute", "4000", "--global-per-minute", "4000",
            "--per-reg-per-minute", "2000",
        ]
        gateway_env = common_env | {"NANDA_REGISTRATION_TOKEN": "", "NANDA_GATEWAY": "1"}
        with service(gateway, gateway_env, output / "gateway.log", cwd=HERE.parent.parent) as gateway_process:
            wait_for(f"{gateway_url}/healthz", gateway_process)
            url = f"{gateway_url}/v1/monitors"
            for name, suffix in [("supervisor", ""), ("price-only", "/price-only")]:
                gateway_request(url, harness_token, {"name": name, "url": monitor_url + suffix, "token": slot_token})
            results = []
            for seed in (27, 28, 45, 46):
                scenarios = [(policy, "deadline", "normal") for policy in ("rules", "price-only", "supervisor")]
                scenarios.append(("supervisor", "priority", "normal"))
                if seed >= 45:
                    scenarios.extend(("supervisor", "priority", condition) for condition in ("missing", "empty-honest"))
                for policy, order, condition in scenarios:
                    command = [
                        args.lune, "run", str(HERE / "market.luau"), "play", str(seed), policy, gateway_url,
                        "300", order, condition,
                    ]
                    result = subprocess.run(command, env=common_env, text=True, stdout=subprocess.PIPE, timeout=90)
                    print(result.stdout.strip(), flush=True)
                    result.check_returncode()
                    results.append(json.loads(result.stdout))
            registrations = gateway_request(url, harness_token)
    (output / "local-matches.json").write_text(json.dumps({"matches": results, "registrations": registrations}, indent=2) + "\n")
    print(f"Match results in {output / 'local-matches.json'}")


if __name__ == "__main__":
    main()
