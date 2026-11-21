"""Train the honest reference, replay held-out listings, and render the demo plot."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

import matplotlib
import numpy as np

from monitor import (
    CALIBRATION_QUANTILE,
    DEFAULT_MODEL,
    MIN_REFERENCE,
    HonestSpace,
    Monitor,
    SIGNAL_DESCRIPTIONS,
    features,
    log_ratio,
    protocol_verdict,
)

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))
from nanda_harness.builtins import rules_decide

matplotlib.use("Agg")
import matplotlib.pyplot as plt

TRAIN = range(1, 19)
CALIBRATE = range(19, 27)
TEST = range(27, 37)
SELECT = range(37, 45)
STRESS = range(45, 55)


def load_batches(path):
    batches = []
    seen = set()
    with path.open() as source:
        for line in source:
            batch = json.loads(line)
            tick = batch["tick"]
            cases = []
            for case in tick["cases"]:
                key = (batch["seed"], case["id"])
                if key not in seen:
                    cases.append(case)
                    seen.add(key)
            if cases:
                batches.append({**batch, "tick": {**tick, "cases": cases}})
    if {batch["seed"] for batch in batches} != set(range(TRAIN.start, STRESS.stop)):
        raise ValueError(f"expected captures for seeds {TRAIN.start}–{STRESS.stop - 1}")
    return batches


def cases_from(batches, seeds):
    for batch in batches:
        if batch["seed"] in seeds:
            signatures = batch["tick"]["lever"]["signatures"]
            for case in batch["tick"]["cases"]:
                yield batch["seed"], case, batch["truth"][case["id"]], signatures


def honest_examples(rows):
    for _, case, truth, signatures in rows:
        if truth == "honest" and protocol_verdict(case, signatures) is None:
            yield case


def fit(training, calibration, signal_names=(), fallback_spaces=None):
    reference = defaultdict(list)
    for case in honest_examples(training):
        if profile := features(case, signal_names):
            reference[profile[0]].append(profile[1])
    spaces = {}
    for cohort, examples in reference.items():
        if space := HonestSpace.fit(examples):
            spaces[cohort] = space

    distances = defaultdict(list)
    prices = []
    for case in honest_examples(calibration):
        if (ratio := log_ratio(case)) is not None:
            prices.append(-ratio)
        if (profile := features(case, signal_names)) and (space := spaces.get(profile[0])) is not None:
            distances[profile[0]].append(space.measure(profile[1])[1])
    spaces = {name: space for name, space in spaces.items() if len(distances[name]) >= MIN_REFERENCE}
    if not spaces or len(prices) < MIN_REFERENCE:
        raise ValueError("too few honest cases to calibrate a monitor")
    for name, space in spaces.items():
        space.cutoff = float(np.quantile(distances[name], CALIBRATION_QUANTILE, method="higher"))
    price_cutoff = float(np.quantile(prices, CALIBRATION_QUANTILE, method="higher"))
    return Monitor(spaces, price_cutoff, signal_names, fallback_spaces), dict(distances)


def validation_counts(monitor, rows):
    counts = Counter()
    for _, case, truth, signatures in rows:
        verdict, _ = monitor.judge(case, signatures)
        counts[truth == "honest", verdict] += 1
    return {"fraud_auto_allowed": counts[False, "allow"], "honest_reviews": counts[True, "escalate"]}


def select_features(training, calibration, validation, baseline, distances):
    monitor = baseline
    best = validation_counts(baseline, validation)
    history = [{"candidate": "original supervisor", **best, "selected": True}]
    while True:
        trials = []
        for name in SIGNAL_DESCRIPTIONS:
            if name in monitor.signal_names:
                continue
            candidate, calibration_distances = fit(
                training, calibration, (*monitor.signal_names, name), baseline.spaces,
            )
            result = validation_counts(candidate, validation)
            entry = {"signals": list(candidate.signal_names), **result, "selected": False}
            history.append(entry)
            if result["fraud_auto_allowed"] < best["fraud_auto_allowed"]:
                trials.append((candidate, calibration_distances, result, entry))
        if not trials:
            return monitor, distances, history
        monitor, distances, best, entry = min(
            trials, key=lambda trial: (trial[2]["fraud_auto_allowed"], trial[2]["honest_reviews"]),
        )
        entry["selected"] = True


def compare(batches, seeds, baseline, monitor):
    policies = {
        "rules": rules_decide,
        "price-only": lambda tick: monitor.decide(tick, price_only=True),
        "original-supervisor": baseline.decide,
        "supervisor": monitor.decide,
    }
    results = {name: defaultdict(Counter) for name in policies}
    for batch in batches:
        if batch["seed"] not in seeds:
            continue
        for name, decide in policies.items():
            for result in decide(batch["tick"])["verdicts"]:
                truth = batch["truth"][result["case"]]
                results[name][truth][result["verdict"]] += 1

    report = {}
    for name, by_truth in results.items():
        report[name] = {
            "honest_blocked": by_truth["honest"]["block"],
            "fraud_auto_allowed": sum(count["allow"] for truth, count in by_truth.items() if truth != "honest"),
            "fraud_auto_blocked": sum(count["block"] for truth, count in by_truth.items() if truth != "honest"),
            "sent_to_review": sum(count["escalate"] for count in by_truth.values()),
            "by_truth": {
                truth: {verdict: count[verdict] for verdict in ("allow", "block", "escalate")}
                for truth, count in by_truth.items()
            },
        }
    return report


def projected_test(rows, monitor):
    space = monitor.spaces["unrated"]
    for seed, case, truth, signatures in rows:
        profile = features(case, monitor.signal_names)
        if profile is None or profile[0] != "unrated" or protocol_verdict(case, signatures) is not None:
            continue
        point, distance = space.measure(profile[1])
        verdict, reason, code = monitor.assess(case, signatures)
        yield {
            "seed": seed,
            "case": case["id"],
            "good": case["good"],
            "truth": truth,
            "price_ratio": case["price"] / case["market"],
            "distance": distance,
            "verdict": verdict,
            "reason": reason,
            "reason_code": code,
            "point": point.tolist(),
        }


def demo_examples(projected):
    requests = [
        ("Routine stall", "honest", "allow", 1.0),
        ("Honest bargain", "honest", "allow", 0.55),
        ("Counterfeit sent to review", "counterfeit", "escalate", 0.92),
    ]
    examples = {}
    for label, truth, verdict, ratio in requests:
        options = [row for row in projected if row["truth"] == truth and row["verdict"] == verdict]
        if options:
            examples[label] = min(options, key=lambda row: abs(row["price_ratio"] - ratio))
    return examples


def plot(path, space, projected, examples):
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
    fig, ax = plt.subplots(figsize=(10.4, 4.9), layout="constrained")
    rank = len(space.components)
    rng = np.random.default_rng(20)
    ref = space.reference
    ref_y = rng.uniform(-0.10, 0.10, len(ref)) if rank == 1 else ref[:, 1]
    ax.scatter(ref[:, 0], ref_y, s=8, color="#62788f", alpha=0.18, label="Honest training references", linewidths=0)

    for truth, color, lane in [("honest", "#007d76", 1), ("fraud", "#b6482b", 2)]:
        for verdict, marker in [("allow", "o"), ("escalate", "x")]:
            rows = [p for p in projected if (p["truth"] == "honest") == (truth == "honest") and p["verdict"] == verdict]
            if not rows:
                continue
            coordinates = np.array([row["point"] for row in rows])
            y = lane + rng.uniform(-0.10, 0.10, len(rows)) if rank == 1 else coordinates[:, 1]
            ax.scatter(coordinates[:, 0], y, s=15, alpha=0.46, c=color, marker=marker, label=f"{truth.title()} · {verdict}")
    offsets = {"Routine stall": (-14, 18), "Honest bargain": (-22, 18), "Counterfeit sent to review": (-14, 20)}
    for name, row in examples.items():
        y = (1 if row["truth"] == "honest" else 2) if rank == 1 else row["point"][1]
        xy = (row["point"][0], y)
        ax.scatter(*xy, s=50, facecolors="none", edgecolors="#19293b", linewidths=1.1, zorder=5)
        offset = offsets[name]
        ax.annotate(
            f"{name} · {row['price_ratio']:.0%} of market",
            xy,
            xytext=offset,
            textcoords="offset points",
            ha="right" if offset[0] < 0 else "left",
            color="#19293b",
            fontsize=9,
            arrowprops={"arrowstyle": "-", "color": "#62788f", "lw": 0.8},
        )
    ax.set_title("Where new stalls fall in the honest reference space", loc="left", fontsize=16, weight="bold", pad=10)
    ax.set_xlabel("Principal component 1 (larger values correspond to higher prices)" if rank == 1 else "Principal component 1")
    if rank == 1:
        ax.set_yticks([0, 1, 2], ["Honest reference", "Honest test cases", "Fraud test cases"])
        ax.set_ylim(-0.35, 2.65)
        ax.grid(axis="y", color="#e4eaf0")
    else:
        ax.set_ylabel("Principal component 2")
    ax.set_axisbelow(True)
    ax.margins(x=0.12)
    ax.legend(loc="upper right", fontsize=8, frameon=False, ncols=2)
    fig.savefig(path, dpi=175, facecolor="white")
    plt.close(fig)


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lune", default="lune", help="path to the Lune executable")
    parser.add_argument("--output", type=Path, default=DEFAULT_MODEL.parent)
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    capture = output / "cases.jsonl"
    with capture.open("w") as stream:
        subprocess.run([args.lune, "run", str(HERE / "market.luau"), "collect", str(STRESS.stop - 1)], stdout=stream, check=True)
    batches = load_batches(capture)
    training, calibration, test = [list(cases_from(batches, seeds)) for seeds in (TRAIN, CALIBRATE, TEST)]
    baseline, distances = fit(training, calibration)
    validation = list(cases_from(batches, SELECT))
    monitor, distances, selection = select_features(training, calibration, validation, baseline, distances)
    write_json(output / "model.json", monitor.to_json())
    projected = list(projected_test(test, monitor))
    examples = demo_examples(projected)
    metrics = {
        "train_seeds": list(TRAIN),
        "calibration_seeds": list(CALIBRATE),
        "feature_selection_seeds": list(SELECT),
        "feature_selection": selection,
        "selected_signals": list(monitor.signal_names),
        "test_seeds": list(TEST),
        "test_cases": dict(Counter(row[2] for row in test)),
        "honest_calibration_quantile": CALIBRATION_QUANTILE,
        "price_only_review_below_ratio": float(np.exp(-monitor.price_cutoff)),
        "supervisor_spaces": {
            name: {"rank": len(space.components), "training_cases": len(space.reference), "calibration_cases": len(distances[name]), "cutoff": space.cutoff}
            for name, space in monitor.spaces.items()
        },
        "policies": compare(batches, TEST, baseline, monitor),
        "stress_test": {
            "seeds": list(STRESS),
            "cases": dict(Counter(row[2] for row in cases_from(batches, STRESS))),
            "policies": compare(batches, STRESS, baseline, monitor),
        },
        "examples": examples,
    }
    write_json(output / "replay.json", metrics)
    plot(output / "latent-space.png", monitor.spaces["unrated"], projected, examples)
    print(f"Held-out replay: {len(test)} cases")
    print("Selected watcher signals: " + (", ".join(monitor.signal_names) or "none"))
    for label, policies in [("Scripted market", metrics["policies"]), ("Market with RedBot", metrics["stress_test"]["policies"])]:
        print(label)
        print(f"{'Policy':<20} {'Honest blocked':>15} {'Fraud allowed':>14} {'Fraud blocked':>14} {'Sent to review':>15}")
        for name, row in policies.items():
            print(f"{name:<20} {row['honest_blocked']:>15} {row['fraud_auto_allowed']:>14} {row['fraud_auto_blocked']:>14} {row['sent_to_review']:>15}")
    print(f"Results in {output.resolve()}")


if __name__ == "__main__":
    main()
