# gog-lens (gog + Ruby)

`gmail.rb` holds small **primitives** over gog's Gmail commands. Write each
task as a short script on the fly: `./gmr '<ruby>'`. All of `Gmail` is in
scope, and the result is printed. Add a primitive only when several scripts
need it. Never add task-specific features.

| File | Job |
|---|---|
| `gmail.rb` (`gmr`) | library + `gmr` runner |
| `gmail-sync` | keeps `index.sqlite3` current (full scan once, then history) |
| `rules.rb` | filters + retention as code; loads gitignored `rules.local.rb` |
| `gmail-rules` | `plan` / `apply` (dry run) / `apply --yes` against `rules.rb` |
| `gmail-watch` | thread/query watches → `~/.claude/alerts.log` (Mac speaks it) |
| `test.rb` | offline tests, fake data: `./test.rb` |

## Primitives

```ruby
# local index: instant, no quota. Prefer it for any read/count question.
ix("sender LIKE ?", "%@vendor.com", limit: 20)   # => [Msg], newest first
idx("SELECT sender, COUNT(*) n FROM msgs WHERE #{has_label('Dev/Sentry')} GROUP BY 1")
meta("synced")                                   # last incremental sync time

# live API
q("gmail query")            # lazy, cached 10 min, Enumerable of Msg
  .where { ... }            # exact client-side filter
  .expect(n | a..b)         # required before any write
  .trash! .archive!(read:) .read! .unread! .inbox! .label!(n, archive:) .unlabel!(n)
  .modify!(add:, remove:, dry_run: true)
q(...).summary              # "N threads / M msgs, ..." (always both units)
q(...).top(:sender|:day|:domain, n) .ids .thread_ids .fresh
thread(id) thread_id(url|id)
Msg: id thread_id from name subject date labels sender domain masked
     unread? inbox? mine? day url headers("To","Cc",...) body!
labels  label_list  label_names  label_id(n)  ensure_label(n)  delete_label!(n)
filters  filter!(...)  delete_filter!(id)
rule(**dsl) rule_source(f) diff(want, have) overlaps(fs)   # rules-as-code helpers
draft!(...)  send!(...)                                    # outward: confirm first
gog(*args)  flags(**kw)  job(name) { }  say(msg)  Progress.new(label, total)
mask(addr)  redact(subjects)
```

## Setup

Env only, no defaults: `GOG_ACCOUNT` (gmail address) for everything,
`CHAT_ME` (your Chat display name) for `chat.rb`. Scripts abort if unset.

## Rules

- **Privacy:** read names, subjects and bodies (`body!`) only when the task
  needs them, and only what it needs.
  `mask`/`redact` are optional helpers for output that gets shared.
- Writes stop without `.expect`, and a count mismatch changes nothing.
  Confirm the count with the user before any trash. Use `draft!` before `send!`.
- `gmail-rules apply --yes` writes to Gmail. Run `plan` and show the user
  the diff first, every time.
- Long jobs: wrap in `job("name") { }` and run in the background. It writes
  `logs/<name>-<stamp>.log` with `X/Y (P%) eta` lines and prints the
  `tail -f` path. Check the current state before re-running anything.
- Report counts in both units: Gmail's UI counts threads, the API messages.

## Perf (measured 2026-10-07 with vernier, time and strace)

- 99.9% of wall time is spent waiting on gog. Ruby CPU is too small to matter.
- The Gmail per-user quota is the limit: bursts of ~95 msg/s, then 429s;
  ~40-50 msg/s sustained. Parallel API reads only cause more 429s.
- So: read from the index; use `labels` for counts; 1000-ID batch writes.
- Full index scan of ~250k msgs ≈ 1.5 h (one time). Incremental sync costs
  one `history` call plus one metadata `get` per changed message.
- To profile: `mise exec -- vernier run -- ./gmr '...'`, then `vernier view`.

## gmail-watch

```
./gmail-watch add <gmail-url|thread-id> <name> [--nag]
./gmail-watch add-query <name> -- '<gmail query>' [--nag]
./gmail-watch rm <name> | snooze <name> <min> | list | summary
```
Poll (no args) appends `Gmail thread <name>: email from <sender name>
waiting for you.` to `~/.claude/alerts.log`. `--nag` repeats every 15 min
until you reply (thread) or reads it (query); no nags 18:00-07:30.
State: `~/.claude/gmail-watch.json`. Errors: `~/.claude/gmail-watch.err`.
Test without alerting the Mac: set `GMAIL_WATCH_STATE` and
`GMAIL_WATCH_ALERTS` to scratch files.

## Cron

Installed: `*/5` polls for `gmail-watch` and `chat-watch`, each prefixed with
`GOG_ACCOUNT=... CHAT_ME="..."` (see `crontab -l`).

Proposed (not installed):
```
M=/home/you/.local/bin/mise
D=/home/you/Projects/gog-lens
GOG_ACCOUNT=you@example.edu
CHAT_ME="Your Name"
*/10 * * * * flock -n $D/logs/sync.lock $M exec -C $D -- ruby $D/gmail-sync >> $D/logs/sync.log 2>&1
0 8 * * 1-5  $M exec -C $D -- ruby $D/gmail-watch summary >> ~/.claude/gmail-watch.err 2>&1
30 2 * * *   $M exec -C $D -- ruby $D/gmail-rules apply --yes >> $D/logs/rules.log 2>&1
```
Cron puts these in the environment (it does not expand `$HOME` there), and `sh` expands `$M`/`$D`. Run `gmail-rules apply --yes` by hand once before cron.
