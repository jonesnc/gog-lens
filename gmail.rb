#!/usr/bin/env -S mise exec -- ruby
# frozen_string_literal: true

# Gmail lens over gog: primitives + helpers only; tasks are one-off scripts.
#   ./gmr 'q("in:inbox is:unread").top'          (gmr -> gmail.rb)
#   require_relative "gmail"; include Gmail      (from another script)
# Perf (measured): wall time = Gmail API quota (~51 msg/s); Ruby is noise.
# So: read from the local index (idx), cache searches, batch writes.

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"

module Gmail
  ACCOUNT = ENV.fetch("GOG_ACCOUNT") { abort "set GOG_ACCOUNT=<your gmail address>" }
  ORG = ACCOUNT.split("@").last # own domain: masked harder
  ROOT = __dir__
  LOGS = File.join(ROOT, "logs")
  CACHE = File.join(LOGS, "cache")
  DB = File.join(ROOT, "index.sqlite3")
  TTL = 600 # seconds a search result is reused
  Error = Class.new(RuntimeError)
  @@log = nil # current job log (shared by Gmail.say and included `say`)

  module_function

  # --- transport -------------------------------------------------------------

  # Run `gog gmail ARGS`, parse JSON, back off on quota errors.
  def gog(*args, json: true, cmd: "gmail")
    cmd = ["gog", cmd, "--account", ACCOUNT, "--no-input",
           *("--json" if json), *args.compact.map(&:to_s)]
    tries = 6
    begin
      out, err, st = Open3.capture3(*cmd)
      raise Error, "gog #{args.first(2).join(' ')}: #{err.strip}" unless st.success?

      json ? JSON.parse(out) : out
    rescue Error => e
      raise unless e.message.match?(/rateLimitExceeded|429/) && (tries -= 1).positive?

      warn "rate limited; waiting 30s"
      sleep 30
      retry
    end
  end

  # flags(to: "a", archive: true, cc: nil) => ["--to", "a", "--archive"]
  def flags(**kw)
    kw.flat_map do |k, v|
      f = "--#{k.to_s.tr('_', '-')}"
      if v == true then [f]
      elsif v.nil? || v == false || v == [] then []
      else [f, Array(v).join(",")]
      end
    end
  end

  # --- jobs + progress -------------------------------------------------------

  # Lines like "modify: 3000/8328 (36%) eta 42s 51/s". Newline-separated so
  # `tail -f` works; throttled to one line per `every` seconds.
  class Progress
    attr_reader :done

    def initialize(label, total = nil, every: 2)
      @label, @total, @every, @done = label, total, every, 0
      @t0 = @last = Time.now
    end

    def step(n = 1)
      @done += n
      return self if Time.now - @last < @every

      @last = Time.now
      Gmail.say(line)
      self
    end

    def finish = Gmail.say("#{line} done")

    def line
      rate = @done / [Time.now - @t0, 0.001].max
      return format("%s: %d %d/s", @label, @done, rate) unless @total

      eta = (@total - @done) / [rate, 0.001].max
      format("%s: %d/%d (%d%%) eta %dh%02dm, done ~%s %d/s",
             @label, @done, @total, @done * 100 / [@total, 1].max, eta / 3600, eta % 3600 / 60,
             (Time.now + eta).strftime("%-l:%M %p"), rate)
    end
  end

  # Timestamped line to stderr and to the current job log (if any).
  def say(msg)
    line = "#{Time.now.strftime('%H:%M:%S')} #{msg}"
    warn line
    @@log&.then { _1.puts(line) || _1.flush }
  end

  # job("sync") { ... }: log to logs/sync-<stamp>.log; prints the tail -f hint.
  def job(name)
    FileUtils.mkdir_p(LOGS)
    path = File.join(LOGS, "#{name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.log")
    @@log = File.open(path, "a")
    warn "watch: tail -f #{path}"
    yield
  ensure
    @@log&.close
    @@log = nil
  end

  # --- redaction (optional, for output that gets shared) ---------------------

  ROLE = /\A(no-?reply|do-?not-?reply|notifications?|alerts?|news(letter)?|info|
           marketing|updates?|support|mailer(-daemon)?|bounce|digest|team|hello)\b/x

  # Role boxes in full; people as "ab***@domain" (own domain: 1 char).
  def mask(addr)
    local, domain = addr.to_s.split("@", 2)
    return "[unparsed]" unless domain
    return addr if local.match?(ROLE)

    "#{local[0, domain.end_with?(ORG) ? 1 : 2]}***@#{domain}"
  end

  # Keep words that repeat across >= min_share of subjects (template text);
  # mask the rest. IDs, emails and T-numbers are always masked.
  def redact(subjects, min_share: 0.3)
    toks = subjects.map { _1.to_s.split }
    floor = [2, (subjects.size * min_share).ceil].max
    freq = toks.flat_map { |t| t.map(&:downcase).uniq }.tally
    secret = lambda do |w|
      w.match?(/@|\d{3,}|\AT\d/i) ||
        (freq[w.downcase] < floor && !w.match?(/\A[[:punct:]]+\z/))
    end
    toks.map { |t| t.map { secret.(_1) ? "***" : _1 }.join(" ").gsub(/(\*\*\* ?)+/, "*** ").strip }
  end

  # --- messages --------------------------------------------------------------

  Msg = Data.define(:id, :thread_id, :from, :subject, :date, :labels) do
    def self.from_h(h)
      new(h["id"], h["threadId"], h["from"].to_s, h["subject"].to_s,
          h["date"].to_s, h["labels"].to_a)
    end

    def sender = (from[/<([^>]+)>/, 1] || from).strip.downcase
    def name = from[/\A"?([^"<]+?)"?\s*</, 1]
    def domain = sender.split("@").last
    def masked = Gmail.mask(sender)
    def unread? = labels.include?("UNREAD")
    def inbox? = labels.include?("INBOX")
    def mine? = sender == Gmail::ACCOUNT
    def day = date[0, 10]
    def url = "https://mail.google.com/mail/u/0/#all/#{thread_id}"

    # Header values only: m.headers("To", "Cc")
    def headers(*names)
      Gmail.gog("get", id, "--format", "metadata", "--headers", names.join(","))
           .dig("message", "payload", "headers").to_a.to_h { [_1["name"], _1["value"]] }
    end

    # Full message, including body.
    def body!
      Gmail.gog("get", id, "--format", "full")
    end
  end

  def q(query) = Query.new(query)

  # Msg from a `get --format metadata` / thread message payload.
  def msg_from_payload(m, names = label_names)
    h = m.dig("payload", "headers").to_a.to_h { [_1["name"], _1["value"]] }
    Msg.new(m["id"], m["threadId"], h["From"].to_s, h["Subject"].to_s,
            Time.at(m["internalDate"].to_i / 1000).strftime("%Y-%m-%d %H:%M"),
            m["labelIds"].to_a.map { names.fetch(_1, _1) })
  end

  # Thread's messages as Msg (gog returns bodies too; dropped here).
  def thread(id)
    gog("thread", "get", id).dig("thread", "messages").to_a.map { msg_from_payload(_1) }
  end

  # Thread id from a Gmail URL, a message id, or a thread id.
  def thread_id(ref) = ref.to_s[%r{[#/]([0-9a-f]{16})\z}, 1] || ref.to_s

  # Lazy, cached search. Enumerable of Msg; writes need .expect(n).
  class Query
    include Enumerable

    def initialize(query, filters = [], expected = nil)
      @query, @filters, @expected = query, filters, expected
    end

    def where(&blk) = Query.new(@query, @filters + [blk], @expected)
    def expect(n) = Query.new(@query, @filters, n) # Integer or Range
    def fresh = tap { FileUtils.rm_f(cache_path) && (@to_a = nil) }
    def inspect = "#<Query #{@query.inspect} where=#{@filters.size} expect=#{@expected.inspect}>"

    def to_a = @to_a ||= fetch.select { |m| @filters.all? { _1.call(m) } }
    def each(&) = to_a.each(&)
    def size = to_a.size
    def ids = to_a.map(&:id)
    def thread_ids = to_a.map(&:thread_id).uniq

    # Both units, always: Gmail's UI counts threads, the API counts messages.
    def summary
      "#{thread_ids.size} threads / #{size} msgs, #{count(&:unread?)} unread, " \
        "#{to_a.map(&:day).minmax.join('..')}"
    end

    # [[key, count], ...] biggest first; senders come back masked.
    def top(key = :sender, n = 15)
      to_a.group_by(&key).transform_values(&:size).max_by(n) { _2 }
          .map { |k, c| [key == :sender ? Gmail.mask(k) : k, c] }
    end

    def trash! = modify!(add: "TRASH", remove: "INBOX")
    def archive!(read: false) = modify!(remove: ["INBOX", *("UNREAD" if read)])
    def read! = modify!(remove: "UNREAD")
    def unread! = modify!(add: "UNREAD")
    def inbox! = modify!(add: "INBOX")
    def unlabel!(name) = modify!(remove: name)

    def label!(name, archive: true)
      modify!(add: Gmail.ensure_label(name), remove: ("INBOX" if archive))
    end

    # Guarded batch modify: 1000 ids/call, 4 threads, progress lines.
    # dry_run: true prints what would change and touches nothing.
    def modify!(add: nil, remove: nil, dry_run: false)
      raise Error, "set .expect(n) before writing" unless @expected
      unless @expected === size
        raise Error, "count #{size} != expected #{@expected}; nothing changed"
      end

      args = Gmail.flags(add:, remove:)
      if dry_run
        Gmail.say("dry-run: would modify #{size} msgs #{args.join(' ')} (#{@query})")
        return size
      end

      jobs = Queue.new.tap { |jq| ids.each_slice(1000) { jq << _1 } }.tap(&:close)
      prog, lock = Progress.new("modify", size), Mutex.new
      Array.new(4) do
        Thread.new do
          while (batch = jobs.pop)
            Gmail.gog("batch", "modify", *batch, *args)
            lock.synchronize { prog.step(batch.size) }
          end
        end
      end.each(&:join)
      prog.finish
      FileUtils.rm_f(cache_path)
      size
    end

    private

    def cache_path = File.join(CACHE, "#{Digest::SHA1.hexdigest(@query)}.json")

    def fetch
      if File.exist?(cache_path) && Time.now - File.mtime(cache_path) < TTL
        return JSON.parse(File.read(cache_path)).map { Msg.from_h(_1) }
      end

      rows = []
      Gmail.search_pages(@query) { rows.concat(_1) }
      Gmail.prune_cache
      File.write(cache_path, JSON.generate(rows))
      rows.map { Msg.from_h(_1) }
    end
  end

  # Yield each 500-row page of `messages search` (metadata rows, no bodies).
  def search_pages(query, page: "", prog: nil)
    prog ||= Progress.new("search")
    loop do
      res = gog("messages", "search", "--max", 500,
                *(["--page", page] unless page.empty?), "--", query)
      rows = res["messages"].to_a
      page = res["nextPageToken"].to_s
      yield rows, page
      prog.step(rows.size)
      break if page.empty?
    end
    prog.finish if prog.done > 500
  end

  # Drop cached searches older than a day.
  def prune_cache
    FileUtils.mkdir_p(CACHE)
    Dir[File.join(CACHE, "*.json")].each { File.delete(_1) if Time.now - File.mtime(_1) > 86_400 }
  end

  # --- local index (SQLite; `./gmail-sync` keeps it current) -----------------

  # idx("SELECT ...", args) => rows as hashes. Labels column is "|A|B|".
  def idx(sql = nil, *args)
    @db ||= begin
      require "sqlite3"
      SQLite3::Database.new(DB, results_as_hash: true).tap do |db|
        db.execute_batch(<<~SQL)
          PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS msgs(id TEXT PRIMARY KEY, thread_id TEXT,
            sender TEXT, from_raw TEXT, subject TEXT, ts INTEGER, labels TEXT);
          CREATE INDEX IF NOT EXISTS msgs_sender ON msgs(sender);
          CREATE INDEX IF NOT EXISTS msgs_ts ON msgs(ts);
          CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        SQL
      end
    end
    sql ? @db.execute(sql, args) : @db
  end

  def meta(k) = idx("SELECT v FROM meta WHERE k=?", k).first&.fetch("v")
  def meta!(k, v) = idx("INSERT OR REPLACE INTO meta VALUES(?,?)", k, v.to_s)

  def upsert(msgs)
    idx.transaction do
      msgs.each do |m|
        ts = Time.parse(m.date).to_i rescue 0
        idx("INSERT OR REPLACE INTO msgs VALUES(?,?,?,?,?,?,?)", m.id, m.thread_id,
            m.sender, m.from, m.subject, ts, "|#{m.labels.join('|')}|")
      end
    end
  end

  # SQL fragment for "has label NAME" against the |A|B| column.
  def has_label(name) = "labels LIKE '%|#{name.gsub("'", "''")}|%'"

  # Indexed messages as Msg: ix("sender LIKE '%@vendor.com'", limit: 50)
  def ix(where = "1", *args, limit: nil)
    sql = "SELECT * FROM msgs WHERE #{where} ORDER BY ts DESC#{" LIMIT #{limit.to_i}" if limit}"
    idx(sql, *args).map do |r|
      Msg.new(r["id"], r["thread_id"], r["from_raw"], r["subject"],
              Time.at(r["ts"]).strftime("%Y-%m-%d %H:%M"), r["labels"].split("|").reject(&:empty?))
    end
  end

  # Newest history id in the mailbox (start point for incremental sync).
  def history_now
    res = gog("messages", "search", "--max", 1, "--", "in:anywhere")
    id = res["messages"].to_a.first&.dig("id")
    gog("get", id, "--format", "metadata", "--headers", "Subject").dig("message", "historyId")
  end

  # --- labels ----------------------------------------------------------------

  def label_list = @label_list ||= gog("labels", "list", "--results-only")
  def label_names = label_list.to_h { [_1["id"], _1["name"]] }
  def label_id(name) = label_list.find { _1["name"] == name }&.dig("id")

  def ensure_label(name)
    label_id(name) || (gog("labels", "create", name) && (@label_list = nil))
    name
  end

  def delete_label!(name) = gog("labels", "delete", name, "--force")

  # {name => [total, unread]} via labels.get: cheap, no search.
  def labels(user_only: true)
    label_list.select { !user_only || _1["type"] == "user" || _1["id"] == "INBOX" }.to_h do |l|
      j = gog("labels", "get", l["id"]).then { _1["label"] || _1 }
      [l["name"], [j["messagesTotal"].to_i, j["messagesUnread"].to_i]]
    end
  end

  # --- filters ---------------------------------------------------------------

  # criteria: {from:, to:, subject:, query:, negated_query:, has_attachment:}
  # add/remove: sorted label NAMES (system ones like INBOX, TRASH as-is).
  Filter = Data.define(:id, :criteria, :add, :remove) do
    def key = [criteria.sort.to_h, add.sort, remove.sort]
    def to_s = "#{criteria.map { "#{_1}=#{_2}" }.join(' ')} +#{add.join(',')} -#{remove.join(',')}"
  end

  def filters
    names = label_names
    snake = ->(k) { k.gsub(/([A-Z])/) { "_#{_1.downcase}" }.to_sym }
    gog("settings", "filters", "list")["filters"].to_a.map do |f|
      a = f["action"].to_h
      Filter.new(f["id"], f["criteria"].to_h.to_h { [snake.(_1), _2] },
                 a["addLabelIds"].to_a.map { names.fetch(_1, _1) }.sort,
                 a["removeLabelIds"].to_a.map { names.fetch(_1, _1) }.sort)
    end
  end

  # filter!(from: "x@y.com", label: "Dev/X", archive: true, mark_read: true)
  def filter!(label: nil, **kw)
    gog("settings", "filters", "create", *flags(add_label: label && ensure_label(label), **kw))
  end

  def delete_filter!(id) = gog("settings", "filters", "delete", id, "--force")

  # --- rules as code (rules.rb is the spec; ./gmail-rules plans/applies) -----

  # Readable action keys <-> raw add/remove label lists.
  FLAG_REMOVE = { skip_inbox: "INBOX", never_spam: "SPAM", mark_read: "UNREAD",
                  never_important: "IMPORTANT" }.freeze
  FLAG_ADD = { trash: "TRASH", star: "STARRED", important: "IMPORTANT" }.freeze
  CRITERIA = %i[from to subject query negated_query has_attachment].freeze

  # Filter from DSL keywords: rule(from: "x", label: "Dev/X", skip_inbox: true)
  def rule(label: nil, **kw)
    bad = kw.keys - CRITERIA - FLAG_REMOVE.keys - FLAG_ADD.keys
    raise Error, "unknown filter keys: #{bad.join(', ')}" if bad.any?

    add = Array(label) + FLAG_ADD.filter_map { |k, v| v if kw[k] }
    remove = FLAG_REMOVE.filter_map { |k, v| v if kw[k] }
    Filter.new(nil, kw.slice(*CRITERIA), add.sort, remove.sort)
  end

  # Inverse of rule: Filter -> 'filter from: "x", label: "Dev/X", skip_inbox: true'
  def rule_source(f)
    adds = f.add - FLAG_ADD.values
    kw = f.criteria.map { "#{_1}: #{_2.inspect}" }
    kw << "label: #{(adds.size == 1 ? adds.first : adds).inspect}" if adds.any?
    kw += FLAG_ADD.filter_map { |k, v| "#{k}: true" if f.add.include?(v) }
    kw += FLAG_REMOVE.filter_map { |k, v| "#{k}: true" if f.remove.include?(v) }
    "filter #{kw.join(', ')}"
  end

  # {create: [...], delete: [...], keep: [...]} by canonical key.
  def diff(desired, actual)
    have = actual.group_by(&:key)
    want = desired.map(&:key)
    { create: desired.reject { have.key?(_1.key) },
      delete: actual.reject { want.include?(_1.key) } +
        have.values.flat_map { _1.drop(1) }, # exact duplicates
      keep: actual.select { want.include?(_1.key) }.uniq(&:key) }
  end

  # Pairs [a, b] with the same action where a's from-addresses are a subset
  # of b's (b already covers a). Flags redundant filters.
  def overlaps(fs)
    froms = lambda do |f|
      f.criteria[:from].to_s.downcase.split(/\s+OR\s+|[\s(){},|]+/).reject(&:empty?)
    end
    fs.combination(2).flat_map { |a, b| [[a, b], [b, a]] }.select do |a, b|
      a.criteria.except(:from) == b.criteria.except(:from) && a.add == b.add &&
        a.remove == b.remove && froms.(a).any? && (froms.(a) - froms.(b)).empty? &&
        froms.(a) != froms.(b)
    end
  end

  # --- compose (outward-facing: confirm with the user before send!) -------

  def draft!(**kw) = gog("drafts", "create", *flags(**kw))
  def send!(**kw) = gog("send", *flags(**kw))
end

# --- runner: ./gmr '<ruby>' evals with Gmail in scope and prints the result ---
if $PROGRAM_NAME == __FILE__ || File.basename($PROGRAM_NAME) == "gmr"
  include Gmail
  at_exit { $!.is_a?(Gmail::Error) && (warn "error: #{$!.message}"; exit! 1) }
  case (res = eval(ARGV.join(" "), binding, "gmr")) # rubocop:disable Security/Eval
  when Gmail::Query then puts res.summary
  when Hash then res.each { |k, v| puts [k, *Array(v)].join("  ") }
  when Array, Enumerator then res.each { puts Array(_1).join("  ") }
  when nil then nil
  else puts res
  end
end
