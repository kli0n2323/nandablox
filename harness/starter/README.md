# Starter kit: your own monitor or trader in NANDA Market

NANDA Market has two slots for outside code:

- a **monitor** sees every open case (a new stall that might be a fraud) and
  answers **allow**, **block** or **escalate** (send it to a human watcher);
- an **agent** drives traders: today, a seller's price.

You write one HTTP endpoint, `POST /decide`. Every tick (about every 2 s) the
gateway sends it the part of the market meant for it and waits **800 ms**.
Anything you don't answer in time, the game decides with its built-ins, so
you can't break the market — only do better or worse than the built-in.

Two examples, one file each, standard library only (Python 3.9+):

| file | what it does | port |
|---|---|---|
| `monitor.py` | a rule monitor, deliberately *different* from the built-in one: blocks bad signatures, trusts well-rated sellers, draws its lines at 80% and 60% of market | 8801 |
| `agent.py` | a seller: undercuts when nothing sold, raises when selling out, else drifts to market | 8802 |

The [Supervisor experiment](supervisor/README.md) trains a monitor on honest simulated listings and compares it with the gateway rules and a price-only policy.

## Five minutes, all on your laptop

From the root of the repo:

```sh
export SLOT_TOKEN=pick-a-long-secret                 # your endpoint checks it

python3 harness/starter/monitor.py &                 # 1. run your monitor...
harness/run.sh --no-llm --allow-localhost &          #    ...and a gateway, locally

G=http://127.0.0.1:8790
curl -s -X POST $G/v1/monitors \
  -d '{"name":"team-a","url":"http://localhost:8801","token":"'$SLOT_TOKEN'"}'   # 2. register it

curl -s -X POST $G/v1/tick -d @harness/starter/tick.json | python3 -m json.tool # 3. see the effect
```

The verdicts now say `"monitor": "team-a"`, and two of the four sample cases
come out differently from the built-in rules. To see what the built-in says,
add `"monitor": "rules"` to the tick:

```sh
sed 's/"server"/"monitor": "rules", "server"/' harness/starter/tick.json | curl -s -X POST $G/v1/tick -d @- | python3 -m json.tool
```

Edit `judge()` in `monitor.py`, restart it, tick again.

The agent is the same, on `/v1/agents` with roles:

```sh
python3 harness/starter/agent.py &
curl -s -X POST $G/v1/agents \
  -d '{"name":"team-b","url":"http://localhost:8802","token":"'$SLOT_TOKEN'","roles":["seller"]}'
```

(If your `~/.env` has `NANDA_HARNESS_TOKEN`, the local gateway wants it too:
add `-H "Authorization: Bearer $NANDA_HARNESS_TOKEN"` to each curl.)

## In the live market

The hosted gateway only calls **https** URLs on **public** hosts, so put your
endpoint behind a tunnel (no account needed):

```sh
python3 harness/starter/monitor.py &
cloudflared tunnel --url http://localhost:8801     # prints https://<random>.trycloudflare.com
```

Then register that URL, with the token the organisers give you (the
*registration* token: it can register, list and remove, and nothing else):

```sh
G=https://nanda-harness-production.up.railway.app
curl -s -X POST $G/v1/monitors -H "Authorization: Bearer $REGISTRATION_TOKEN" \
  -d '{"name":"team-a","url":"https://<random>.trycloudflare.com","token":"'$SLOT_TOKEN'"}'
curl -s $G/v1/monitors -H "Authorization: Bearer $REGISTRATION_TOKEN"   # your calls, timeouts, last error
curl -s -X DELETE $G/v1/monitors/team-a -H "Authorization: Bearer $REGISTRATION_TOKEN"
```

Your terminal prints each case as the market sends it; `GET /v1/monitors`
shows how often you were called, how often you were late, and the last thing
the gateway rejected from you.

## What you receive and what you answer

A monitor gets `{server, t, market, lever, cases: [...]}` and answers

```json
{"verdicts": [{"case": "c-17", "verdict": "escalate", "reason": "40% below market, no history"}]}
```

An agent gets `{server, t, market, lever, decisions: [...]}` (only the traders
it drives) and answers

```json
{"actions": [{"agent": "seller-12", "set_price": 290}]}
```

Prices are **integer cents**. A case is
`{id, stall, good, price, market, age_s, ratings, rating_avg, signature, twin, deadline_s}`,
with `signature` one of `valid`, `invalid`, `unchecked` (signatures off). A
decision is `{agent, role, good, stock, price, market, sold_last_min}`.

This checkout also sends optional `signals` in each case. They are booleans from the watcher's view: `stocked`, `displays_prints`, `vouched`, `listing_note`, and `pitch_present`. Older games can omit the field, and monitors can ignore it.

The rules the gateway holds you to:

- answer within **800 ms**, at most **64 KiB**, as a JSON object, with HTTP 200;
- `verdict` is exactly `allow`, `block` or `escalate`, for a `case` id you were sent;
- `set_price` is a whole number of cents from 1 to 10,000,000, for an `agent` you drive;
- `reason` is optional, trimmed to one line of 120 characters;
- an `escalate` verdict can include an optional `reason_code` of `empty_counter`, `prints_displayed`, or `unusual_listing`. The game checks claims about the counter against its own observations before showing them or giving them queue priority;
- anything else is dropped and named in that tick's `errors` — the rest of
  your answer still counts;
- at most 60 calls a minute per registration; a call still running when the
  next tick comes means you miss that tick;
- the request carries `Authorization: Bearer <your SLOT_TOKEN>`: check it, so
  only the gateway can drive your traders.

The built-in monitor you're competing with, in full:

```text
if listing.twin and signatures are off:    escalate
if price >= 0.85 * market or ratings >= 5: allow
if price <  0.50 * market and age < 60 s:  block
otherwise:                                  escalate
```
