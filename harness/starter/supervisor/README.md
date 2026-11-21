# NANDA Market Supervisor

The Supervisor fills the external monitor slot. It learns a reference from known honest listings, allows cases near that reference, and sends unusual cases to a watcher. An invalid checked signature is a direct block. Duplicate identities and cases without enough comparable history go to review. The model stays fixed during a run.

## Run the milestone locally

Use Python 3.10+ and the repository's pinned Lune 0.11.0. From the repository root, with `lune` on your `PATH`:

```sh
python3 -m venv harness/starter/supervisor/.venv
source harness/starter/supervisor/.venv/bin/activate
python -m pip install -r harness/starter/supervisor/requirements.txt
python harness/starter/supervisor/experiment.py
python harness/starter/supervisor/local_demo.py
```

Pass `--lune /path/to/lune` to either script if you use a Rokit shim or a standalone executable outside your `PATH`. `local_demo.py` starts the monitor and the real harness on loopback. It runs rules, price-only, and the Supervisor in deadline order, then repeats the Supervisor matches in evidence priority order. All four five-minute seeds use one simulated watcher. Two seeds run with RedBot active and get two additional priority runs each. One stress run hides either the stock or print cue on roughly one in five cases. The other shows roughly one in ten honest listings as empty during review while preserving their ability to deliver. The launcher raises the request limits on its temporary gateway so the market can run faster than real time. Both services stop when it exits.

Open `output/latent-space.png` for the demo. It shows an honest bargain the Supervisor allows and a near-market counterfeit it sends to review. `output/replay.json` records the feature candidates, held-out comparisons, counts by fraud type, and example case scores. Compare the `deadline` and `priority` rows in `output/local-matches.json` for fraud escapes, honest blocks, cases that expired in the inbox, and watcher workload. The plot's rows show ground-truth groups for the offline demo. When the data has one component, that component is horizontal. The score also takes changes in features outside the projection into account.

## Attach the monitor to a game

Run `python harness/starter/supervisor/monitor.py` with `SLOT_TOKEN` set to a secret you generate. The server listens on port 8803 on loopback by default. Register `supervisor` with the gateway following the [starter kit's registration instructions](../README.md) and use that same token. The primary endpoint is `POST /decide`. For an optional price-only registration, append `/price-only` to its base URL. The experiment's `output/model.json` loads at startup. Use `--model` to point to a different artifact. To use learned listing signals, run the market build from this checkout. Older game payloads use the original price and seller history model automatically.

For a local Studio build, enable HTTP requests in the experience, point `Config.GATEWAY_URL` in `roblox/src/market/shared/Market/Config.luau` at your local harness, and set `Config.GATEWAY_MONITOR` to `"supervisor"`. Build and start the market place using the [market demo guide](../../../roblox/MARKET_DEMO.md), then choose **yours** in the monitor controls. The inbox shows labels such as **Flagged · Empty counter** next to the watcher's Allow and Block buttons. The game puts corroborated counter clues up to one review slot (five seconds) earlier in the sort order. The listing keeps its real deadline. Longer score explanations are available in the endpoint response and the offline demo.

## How the comparison works

- `market.luau` uses the simulator's normal gateway request and records private truth outside the request. Each of the 54 seeds runs with 300 traders for five simulated minutes. Even seeds enable signatures. Counterfeits are chosen in 15% of scripted fraud draws. Seeds 37 onward also run the game's RedBot, which can buy vouchers, use sales pitches, and try stolen IDs. The simulator's rule policy drives data collection so each policy can replay the same cases offline.
- Seeds 1–18 train the honest reference. Seeds 19–26 set each learned policy's 95th-percentile threshold on honest cases. Selection examines seeds 37–44, adding a watcher signal only when it reduces the number of frauds auto-allowed. Ties favor fewer honest reviews. The two held-out sets are seeds 27–36 and 45–54. Private truth is used to pick clean training cases and measure results. The monitor receives the same watcher observations it trains on, with case IDs used to route verdicts.
- The model standardizes log price-to-market ratio, log age, log rating count, average rating where available, and the selected signals. It fits up to two PCA components in each supported rating cohort. The score combines mean distance to the five nearest honest examples in that space with reconstruction distance from omitted dimensions. A cohort requires at least 30 honest training and calibration cases to produce a score. The price-only policy uses a low-price threshold and shares the Supervisor's signature and duplicate-identity policy.
- An auto-allowed fraud in replay is a monitor decision. A fraud escape in a match requires a buyer to pay and depends on how the market evolves. The paired matches reuse starting seeds and settings, while each policy's decisions can change subsequent listings and deals.
