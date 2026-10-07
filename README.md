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

Final run, Oct 7 2026: DHH's `bench/run` on a Hetzner Ryzen 7 PRO 8700GE. Each app gets four
hardware threads and the load generator four others. YJIT and jemalloc are on. The numbers are
medians of 3 runs in rotating order, measured alongside the other implementations and stock
Rails, with 0 errors.

| Workload | Rails (stock) | Rails (optimized) |
|---|---:|---:|
| Room page (req/s, 16 clients) | 225 | 538 |
| Messages page | 364 | 2,003 |
| Sidebar | 482 | 3,578 |
| Search | 378 | 872 |
| Post a message | 198 | 258 |
| Avatar | 62,491 | 62,420 |
| Action Cable, 1,000 clients: p50 delivery | 42.8 ms | 40.1 ms |
| Action Cable, 1,000 clients: saturated | 13 msg/s | 12 msg/s |
| Upload + thumbnail (505 KB) | 67 ms | 66 ms |
| Idle memory (anon) | 284 MB | 613 MB |
| Cold start | 3.6 s | 5.9 s |

Idle memory is higher because this runs 4 Falcon processes against stock's 3 Puma workers, plus per-process caches.

**Room-page reads while posts arrive** (reads/sec at 16 clients, the median of 3 reps, each on a
fresh seed). The read routes above never see a write, so this shows what the caches do under real
traffic:

| Posts/sec in the background | 0 | 20 | 100 |
|---|---:|---:|---:|
| Rails (stock) | 228 | 214 | 194 |
| Rails (optimized) | 537 | 430 | 208 |

The per-change table below comes from the A/B run for each step. Each step was measured against
the commit just before it, so the percentages don't multiply exactly into the totals.

## Compared with Rust on the same box

DHH's [Rust port](https://github.com/basecamp/once-campfire-rust) (`ccece30`) was built and run on the
same Hetzner box, in the same session as stock Rails and the three Ruby apps. Settings: 16 clients, four
hardware threads per app, median of 3 alternating reps. Each app ran with its default caching.

| HTTP workload (requests/sec) | Rails | Rails (optimized) | Sinatra | Rage | Rust |
|---|---:|---:|---:|---:|---:|
| Room page | 225 | 551 | 12,861 | 10,127 | 21,229 |
| Messages page | 360 | 1,984 | 19,729 | 24,638 | 23,565 |
| Sidebar | 480 | 3,562 | 22,936 | 32,975 | 20,828 |
| Search | 382 | 863 | 15,700 | 16,910 | 21,276 |
| Post a message | 198 | 261 | 3,195 | 1,833 | 4,153 |
| Avatar | 61,687 | 62,178 | 72,081 | 181,576 | 196,297 |
| Cable p50, 1,000 clients | 44.6 ms | 40.9 ms | 9.0 ms | 5.0 ms | 4.3 ms |
| Idle memory | 282 MB | 617 MB | 201 MB | 170 MB | 13 MB |

With only the caching Rust does (`CAMPFIRE_CACHING=rust`), the Ruby apps read at roughly a quarter to a
third of Rust's rate. Sinatra posts at three-quarters of Rust's rate. The extra caches all come from
Elixir's port, and they're what let Ruby match Rust on the messages page and sidebar.

**Hardware.** This box is slower than DHH's. On it, Rust runs at about 60% of his published numbers
(room 21,229 vs 36,260). Stock Rails runs at 73–93% of his. So comparing these numbers with his table
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
(or this app) has, and keeps the rest. The run used the same harness, box and CPUs as the full
run, on images built from the commit that adds the switch: 3 reps, 0 errors. Rails (stock) is from the full run; in this run it measured 221 / 365 / 467 /
368 / 196.

| Workload (req/s, 16 clients) | Rails (stock) | Full caching | Rust-level caching only | Full ÷ Rust-level |
|---|---:|---:|---:|---:|
| Room page | 225 | 538 | 498 | 1.1× |
| Messages page | 364 | 2,003 | 902 | 2.2× |
| Sidebar | 482 | 3,578 | 824 | 4.3× |
| Search | 378 | 872 | 767 | 1.1× |
| Post a message | 198 | 258 | 268 | 1.0× |

The same mixed read/write run (3 reps, fresh seed each):

| Room reads/sec while posts arrive at | 0/s | 20/s | 100/s |
|---|---:|---:|---:|
| Rails (stock) | 228 | 214 | 194 |
| Rails (optimized), full caching | 537 | 430 | 208 |
| Rails (optimized), Rust-level caching only | 504 | 416 | 208 |

## Where the gains come from

Each change was measured with an A/B against the commit before it.

| Change | Source | Room | Messages | Sidebar | Search | Post |
|---|---|---:|---:|---:|---:|---:|
| No `Rack::Deflater` (Thruster gzips), Redis `compress: false`, no `Rack::ETag`, 4 workers | Config | +56% | +52% | +19% | +31% | +19% |
| Puma → Falcon (`isolation_level = :fiber`) | Config | +1% | +3% | +10% | +12% | +1% |
| Skip static-file disk checks; tags once per process; `Current.account` once | Ours | +10% | — | +14% | +14% | — |
| Per-process copy of versioned fragments; cache versions without a DB checkout | Ours | +13% | +20% | +6% | +8% | — |
| Boost forms built as strings | Ours | — | +2% | — | — | +8% |
| `Sec-Fetch-Site` instead of CSRF tokens | Rust | +14% | +16% | — | +9% | — |
| Keep each page's gzip by digest | Rust, Elixir | +7% | +20% | +7% | — | — |
| Read cache cleared on `PRAGMA data_version` | Elixir | — | +10% | +16% | +14% | — |
| Keep the finished sidebar until its data changes | Elixir | | | +227% | | |
| Cookies only when they change | Rust | +17–23% on every read route | | | | |
| Messages page kept per ETag | Elixir | | +86% | | | |
| Push job query fixes | Ours | | | | | +1% |
| Restore `Rack::Deflater` (needed for parity) | — | −1–3% | | | | |

An earlier version kept finished room and search pages whole: room 2,944, search 3,697. Neither
the Rust nor the Elixir port does that, so it was removed.

Tried and dropped:

- PostgreSQL. It was slower when it shared the same 4 CPUs.
- One transaction per post.
- In-process jobs. Posting was 16% slower: single-threaded Falcon processes block on SQLite, and
  Resque was using the idle cores.

## Status

- **Parity:** all 874 default-seed Playwright cells pass, and server HTML is identical to stock on
  58 responses.
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
