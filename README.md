# Campfire, optimized (fork)

This fork of [once-campfire](https://github.com/basecamp/once-campfire) makes the Rails app faster
without changing its behavior. That's checked with the Playwright parity harness from DHH's
[once-campfire-rust](https://github.com/basecamp/once-campfire-rust). The only differences from
stock are the ones the Rust port documents in its README under "Known differences". The work is on
the `perf` branch.

It's one of four Ruby implementations benchmarked together. The benchmark notes, harness changes,
per-change measurements and raw results are on the
[`benchmarks` branch](https://github.com/jpcamara/once-campfire-sinatra/tree/benchmarks) of the
Sinatra repo.

| Implementation | Code |
|---|---|
| Rails, optimized | this fork, branch `perf` |
| Sinatra + Falcon | [jpcamara/once-campfire-sinatra](https://github.com/jpcamara/once-campfire-sinatra) |
| Rage + Sequel | [jpcamara/once-campfire-rage](https://github.com/jpcamara/once-campfire-rage) |
| Roda + Sequel (Falcon) | [jpcamara/once-campfire-roda](https://github.com/jpcamara/once-campfire-roda) |

## Performance

Final run, Oct 8 2026, after the precedent audit: DHH's `bench/run` on a Hetzner Ryzen 7 PRO
8700GE. Each app gets four hardware threads and the load generator four others. YJIT and jemalloc
are on. The numbers are medians of 3 runs in rotating order (HTTP and Action Cable), measured
alongside the other implementations, stock Rails and the Rust port, with 0 errors. Upload and
cold-start times are from the Oct 7 run; the audit's reverts don't touch those paths.

| Workload | Rails (stock) | Rails (optimized) |
|---|---:|---:|
| Room page (req/s, 16 clients) | 221 | 529 |
| Messages page | 370 | 1,985 |
| Sidebar | 482 | 3,557 |
| Search | 381 | 862 |
| Post a message | 195 | 259 |
| Avatar | 61,938 | 62,671 |
| Action Cable, 1,000 clients: p50 delivery | 44.1 ms | 41.1 ms |
| Action Cable, 1,000 clients: saturated | 12 msg/s | 12 msg/s |
| Idle memory (anon) | 283 MB | 613 MB |
| Upload + thumbnail (505 KB), Oct 7 run | 67 ms | 66 ms |
| Cold start, Oct 7 run | 3.6 s | 5.9 s |

Idle memory is higher because this runs 4 Falcon processes against stock's 3 Puma workers, plus per-process caches.

The precedent audit (Oct 8) reverted one push-job change with no Rust counterpart. The numbers didn't
move.

**Room-page reads while posts arrive** (reads/sec at 16 clients, the median of 3 reps, each on a
fresh seed). The read routes above never see a write, so this shows what the caches do under real
traffic:

| Posts/sec in the background | 0 | 20 | 100 |
|---|---:|---:|---:|
| Rails (stock), Oct 7 run | 228 | 214 | 194 |
| Rails (optimized) | 534 | 441 | 205 |

The per-change table below comes from the A/B run for each step. Each step was measured against
the commit just before it, so the percentages don't multiply exactly into the totals.

## Compared with Rust on the same box

DHH's [Rust port](https://github.com/basecamp/once-campfire-rust) (`ccece30`) was built and run on the
same Hetzner box, in the same Oct 8 session as stock Rails and the three Ruby apps. Settings: 16 clients,
four hardware threads per app, median of 3 runs in rotating order. Each app ran with its default caching.

| HTTP workload (requests/sec) | Rails | Rails (optimized) | Sinatra | Rage | Rust |
|---|---:|---:|---:|---:|---:|
| Room page | 221 | 529 | 11,349 | 10,094 | 21,155 |
| Messages page | 370 | 1,985 | 16,256 | 24,763 | 23,515 |
| Sidebar | 482 | 3,557 | 22,613 | 33,951 | 20,769 |
| Search | 381 | 862 | 14,523 | 16,900 | 21,361 |
| Post a message | 195 | 259 | 1,799 | 1,643 | 4,109 |
| Avatar | 61,938 | 62,671 | 72,664 | 178,292 | 196,428 |
| Cable p50, 1,000 clients | 44.1 ms | 41.1 ms | 8.2 ms | 5.0 ms | 4.4 ms |
| Idle memory | 283 MB | 613 MB | 200 MB | 170 MB | 13 MB |

With only the caching Rust does (`CAMPFIRE_CACHING=rust`), the Ruby apps read at roughly a quarter to
two-fifths of Rust's rate, and post at about 40–45% of it. The extra caches all come from Elixir's port,
and they're what let Ruby match Rust on the messages page and sidebar.

**Hardware.** This box is slower than DHH's. On it, Rust runs at about 60% of his published numbers
(room 21,155 vs 36,260). Stock Rails runs at 73–93% of his. So comparing these numbers with his table
overstates the gap between Ruby and Rust by about 1.7×.

## Caching

The rule here: only cache what the Rust or Elixir ports cache, checked against their source.

**What the Rust port caches** (from its source):

| Cache | What it holds | Rust source |
|---|---|---|
| Message fragments | Rails' own `cache message do` fragments, in memory, bounded by bytes | `views/src/fragment_cache.rs` |
| Compressed pieces | Each fragment's deflate block, the text between fragments, and a whole body's gzip by digest | `kit/src/deflater/splice.rs` |
| Public responses | `Cache-Control: public` responses such as avatars and assets | `kit/src/front/cache.rs` |
| Prepared statements | 256 per connection | `db` crate |

Rust caches no query results and no pages, sidebars or page shells. It renders every page on every
request.

**What this app caches**, with each cache's precedent and its effect in a per-step A/B:

| Cache | Precedent | Measured effect |
|---|---|---|
| Rails' fragment cache, plus a per-process copy | Rust (fragments in memory) | room +13%, messages +20% |
| Gzip kept by body digest | Rust | messages +20%, room and sidebar +7% |
| Public responses | Rust, Thruster | Thruster, as in stock |
| Prepared statements | Rust | Rails default |
| Read cache (`PRAGMA data_version`) | Elixir only | messages +10%, sidebar +16%, search +14% |
| Finished sidebar until its data changes | Elixir only | sidebar 3.3× |
| Messages page per ETag | Elixir only | messages 1.9× |

**Rust-level caching only.** `CAMPFIRE_CACHING=rust` turns off every cache that only the Elixir port
has, and keeps the rest. It ran on Oct 8 with the same harness, box, CPUs and images as the full
run: 3 runs in rotating order, HTTP suite, 0 errors. Rails (stock) is from the full run.

| Workload (req/s, 16 clients) | Rails (stock) | Full caching | Rust-level caching only | Full ÷ Rust-level |
|---|---:|---:|---:|---:|
| Room page | 221 | 529 | 516 | 1.0× |
| Messages page | 370 | 1,985 | 902 | 2.2× |
| Sidebar | 482 | 3,557 | 843 | 4.2× |
| Search | 381 | 862 | 762 | 1.1× |
| Post a message | 195 | 259 | 273 | 0.9× |

The same mixed read/write run (3 reps, fresh seed each):

| Room reads/sec while posts arrive at | 0/s | 20/s | 100/s |
|---|---:|---:|---:|
| Rails (stock), Oct 7 run | 228 | 214 | 194 |
| Rails (optimized), full caching | 534 | 441 | 205 |
| Rails (optimized), Rust-level caching only | 508 | 419 | 205 |

## Where the gains come from

Each change was measured with an A/B against the commit before it. Every change is a fix of a
misconfiguration, something the Rust port does, or a cache the Elixir port has, as listed in
[the precedent audit](https://github.com/jpcamara/once-campfire-sinatra/blob/benchmarks/notes/precedent-audit.md).

| Change | Source | Room | Messages | Sidebar | Search | Post |
|---|---|---:|---:|---:|---:|---:|
| No double compression (Thruster already gzips), Redis `compress: false`, no `Rack::ETag`, 4 workers | Config fix | +56% | +52% | +19% | +31% | +19% |
| Puma → Falcon (`isolation_level = :fiber`) | Config | +1% | +3% | +10% | +12% | +1% |
| Public files from an index, not disk probes; stylesheet tags once per process; account loaded once per page | Rust (`assets/src/serve.rs`, b93306d, `Layout::load`) | +10% | — | +14% | +14% | — |
| Fragment cache in process; cache versions computed from the row | Rust (`views/src/fragment_cache.rs`) | +13% | +20% | +6% | +8% | — |
| Quick boost forms as literal HTML | Rust (`templates/messages/_actions.html`) | — | +2% | — | — | +8% |
| `Sec-Fetch-Site` instead of CSRF tokens | Rust (b567772) | +14% | +16% | — | +9% | — |
| Keep each page's gzip by digest | Rust (2f755bf), Elixir | +7% | +20% | +7% | — | — |
| Read cache cleared on `PRAGMA data_version` | Elixir (`db.ex`) | — | +10% | +16% | +14% | — |
| Keep the finished sidebar until its data changes | Elixir (`sidebar.ex`) | | | +227% | | |
| Cookies only when they change | Rust (2947c64) | +17–23% on every read route | | | | |
| Messages page kept per ETag | Elixir (`messages.ex`) | | +86% | | | |
| Push job: no user query per subscription, no mentions query without mentions | Rust (`push_subscription.rs`) | | | | | +1% |
| Restore `Rack::Deflater` (needed for parity) | — | −1–3% | | | | |

**Reverted for lack of precedent:**

- Keeping finished room and search pages whole (room 2,944, search 3,697). Neither port does that.
- Counting each user's push badge once per push. Rust counts it per subscription.

Tried and dropped:

- PostgreSQL. It was slower when it shared the same 4 CPUs.
- One transaction per post.
- In-process jobs. Posting was 16% slower: single-threaded Falcon processes block on SQLite, and
  Resque was using the idle cores.

## Status

- **Parity:** all 874 default-seed Playwright cells passed before the precedent audit. After its
  one revert, the groups it touches passed again (realtime and composer, 150 of 150), and server HTML
  is still identical to stock on 58 responses.
- **Audit:** the independent audit found three undisclosed differences from Rails, all now fixed.
  `POST /searches` runs the query again, sign-out rotates the session cookie, and direct uploads
  work again.

---

# Campfire

Campfire is a web-based chat application. It supports many of the features you'd
expect, including:

- Multiple rooms, with access controls
- Direct messages
- File attachments with previews
- Search
- Notifications (via Web Push)
- @mentions
- API, with support for bot integrations

## Running your own Campfire instance

Campfire's Docker image contains everything needed for a fully-functional,
single-machine deployment. This includes the web app, background jobs, caching,
file serving, and SSL. You can use our pre-built image at
`ghcr.io/basecamp/once-campfire:latest`, or build your own from this repo.

### Deploying with ONCE

The easiest way to self-host Campfire is with [ONCE](https://github.com/basecamp/once).
It will guide you through the initial set up and then keep your instance up to date automatically.

If you don't already have `once` installed, run this on the machine you want to run Campfire on:

```sh
curl https://get.once.com | sh
```

`once` will launch as soon as the install is finished. 

Choose Campfire from the list of applications, follow the instructions, and ONCE will take care of the rest.

If you prefer the command line to the dashboard, you can deploy directly:

```sh
once deploy ghcr.io/basecamp/once-campfire --host chat.example.com
```

### Deploying with Docker

If you'd rather run the Docker image yourself, you can read more about that in the [self-hosting guide](docs/self-hosting.md).

> [!TIP]
> When you start Campfire for the first time, you'll be guided through a wizard to create an admin account.
> The email address that you enter for the admin account will be visible on the sign-in page, it's there so
> that people have someone to contact if they need help with their account. If that bothers you, put in any
> email address you want and create yourself a new admin account.

## Other implementations

Campfire also has implementations in Django, Laravel, Express, Elixir, Go and Rust:

| HTTP workload (requests/sec) | Rails | [Django](https://github.com/basecamp/once-campfire-django) | [Laravel](https://github.com/basecamp/once-campfire-laravel) | [Express](https://github.com/basecamp/once-campfire-express) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Room page | 241 | 170 | 164 | 559 | 722 | 3,860 | 36,260 |
| Messages page | 413 | 196 | 175 | 777 | 1,053 | 5,573 | 40,872 |
| Sidebar | 552 | 615 | 715 | 4,125 | 1,275 | 19,753 | 34,672 |
| Search | 435 | 315 | 305 | 1,294 | 1,156 | 7,053 | 33,299 |
| Post a message | 273 | 154 | 137 | 256 | 801 | 4,767 | 6,896 |

Measured with 16 concurrent clients on an AMD Ryzen AI MAX+ 395,
with four hardware threads allocated to each app.

## Development

You are welcome - and encouraged - to modify Campfire to your liking.
Please see our [development guide](docs/development.md) for how to get Campfire set up for local development.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability and a description of our trust model.
