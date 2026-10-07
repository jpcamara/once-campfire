# Campfire, optimized (fork)

This fork of [once-campfire](https://github.com/basecamp/once-campfire) makes the Rails app faster
without changing its behavior. That's checked with the Playwright parity harness from DHH's
[once-campfire-rust](https://github.com/basecamp/once-campfire-rust). The only differences from
stock are the ones the Rust port documents in its README under "Known differences". The work is on
the `perf` branch.

It's one of three Ruby implementations benchmarked together. The benchmark notes, harness changes,
per-change measurements and raw results are on the
[`benchmarks` branch](https://github.com/jpcamara/once-campfire-sinatra/tree/benchmarks) of the
Sinatra repo.

| Implementation | Code |
|---|---|
| Rails, optimized | this fork, branch `perf` |
| Sinatra + Falcon | [jpcamara/once-campfire-sinatra](https://github.com/jpcamara/once-campfire-sinatra) |
| Rage + Sequel | [jpcamara/once-campfire-rage](https://github.com/jpcamara/once-campfire-rage) |

## Performance

Requests/sec with 16 clients, four hardware threads per app, on a Hetzner Ryzen 7 PRO 8700GE.
The harness is DHH's `bench/run`, with YJIT and jemalloc on. These are the latest A/B numbers; a
final run of all three apps together will replace them.

| HTTP workload (requests/sec) | Rails (stock) | Rails (optimized) |
|---|---:|---:|
| Room page | 223 | 523 |
| Messages page | 371 | 2,017 |
| Sidebar | 475 | 3,615 |
| Search | 377 | 859 |
| Post a message | 199 | 270 |

**Where the gains come from.** Each change was measured with an A/B against the commit before it.

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
