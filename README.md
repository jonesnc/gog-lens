# gog-lens

A small Ruby 4 lens over [gogcli](https://github.com/openclaw/gogcli) for
Gmail and Google Chat. Composable primitives instead of big workflows, a
local SQLite index so questions are instant and cost no API quota, Gmail
filters and retention kept as code, and cron watchers that tell you when
someone replies.

## Why

- **Ask questions at the speed of SQL.** Gmail's per-user quota caps reads
  at ~40-50 msg/s. One full scan builds `index-<account>.sqlite3` (headers only:
  sender, subject, date, labels — no bodies); after that, `gmail-sync` pulls
  only changes through the Gmail history API in seconds.
- **Safe bulk writes.** Every write must declare how many messages it
  expects (`.expect(n)`). A count mismatch changes nothing.
- **Filters as code.** `rules.rb` holds your filters and retention rules;
  `gmail-rules plan` diffs them against live Gmail, Terraform style.
- **Reply alerts.** `gmail-watch` and `chat-watch` poll from cron and append
  one line per new reply to an alert log, with optional 15-minute nags until
  you answer.

## Requirements

- Ruby 4 (e.g. `mise use -g ruby@4`; YJIT recommended: `RUBY_YJIT_ENABLE=1`)
- [gogcli](https://github.com/openclaw/gogcli) authorized with the `gmail`
  scope (and `chat` for Google Chat; enable the Chat API in your Cloud project)
- `gem install sqlite3`

## Setup

```sh
git clone https://github.com/jonesnc/gog-lens && cd gog-lens
export GOG_ACCOUNT=you@example.com   # required, no default
export CHAT_ME="Your Name"           # only for chat.rb / chat-watch
./test.rb                            # offline tests
./gmail-sync                         # first run: full scan, resumable
```

More than one account: set `GOG_ACCOUNT` for each run. The index, rules
and watch state are kept per account. Old single-account files still load.

## Use

```sh
# one-off scripts: all of Gmail is in scope, the result is printed
./gmr 'q("in:inbox is:unread").top(:sender, 10)'
./gmr 'ix("sender LIKE ?", "%@vendor.com").size'           # local index
./gmr 'q("in:inbox subject:\"Out of Office\"").expect(27).trash!'

# rules as code
./gmr 'filters.map { rule_source(_1) }' > rules.local.$GOG_ACCOUNT.rb   # bootstrap
./gmail-rules plan          # diff vs live Gmail (read-only)
./gmail-rules apply         # dry run
./gmail-rules apply --yes   # write

# reply alerts
./gmail-watch add <gmail-url> "Vendor kickoff" --nag
./gmail-watch add-query "Direct from vendor" -- 'from:@vendor.com to:me'
./chat-watch add <chat-url> "Project chat"
```

Watchers write to `~/.claude/alerts.log`; point anything at that file
(a `tail -F` over ssh into a desktop notifier works well). See `CLAUDE.md`
for the full primitive list, perf notes and suggested crontab.

## Files

| File | Job |
|---|---|
| `gmail.rb` / `gmr` | primitives + one-off script runner |
| `chat.rb` | Google Chat primitives |
| `gmail-sync` | keeps the local index current |
| `rules.rb` | filters + retention; loads gitignored `rules.local.<account>.rb` |
| `gmail-rules` | plan / apply for `rules.rb` |
| `gmail-watch`, `chat-watch` | cron reply watchers |
| `test.rb` | offline tests with fake data |

## License

MIT
