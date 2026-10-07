#!/usr/bin/env -S mise exec -- ruby
# frozen_string_literal: true

# Offline tests with fake data: ./test.rb (no Gmail calls).

require "minitest/autorun"
ENV["GOG_ACCOUNT"] = "me@example.edu"
require_relative "gmail"

class GmailTest < Minitest::Test
  include Gmail

  def test_mask
    assert_equal "noreply@canvas.edu", mask("noreply@canvas.edu")
    assert_equal "ja***@gmail.com", mask("jane.doe@gmail.com")
    assert_equal "b***@example.edu", mask("bob@example.edu")
    assert_equal "[unparsed]", mask("nobody")
  end

  def test_redact_keeps_template_text
    subs = ["Approval needed: Jane Smith T00123456 travel request",
            "Approval needed: Bo Li T00999999 travel request",
            "Approval needed: Al Roe T00111111 travel request"]
    assert_equal ["Approval needed: *** travel request"], redact(subs).uniq
  end

  def test_flags
    assert_equal %w[--to a --archive --add-label X,Y], flags(to: "a", archive: true, cc: nil,
                                                           add_label: %w[X Y], remove_label: [])
  end

  def test_rule_round_trip
    f = rule(from: "x@y.com", label: "Dev/X", skip_inbox: true, mark_read: true)
    assert_equal ["Dev/X"], f.add
    assert_equal %w[INBOX UNREAD], f.remove
    assert_equal 'filter from: "x@y.com", label: "Dev/X", skip_inbox: true, mark_read: true',
                 rule_source(f)
    assert_raises(Gmail::Error) { rule(form: "typo") }
  end

  def test_diff
    keep = rule(from: "a@x", label: "A", skip_inbox: true)
    live = [keep.with(id: "1"), keep.with(id: "2"), # exact duplicate on Gmail
            rule(from: "old@x", label: "Old").with(id: "3")]
    d = diff([keep, rule(from: "new@x", label: "New")], live)
    assert_equal ["new@x"], d[:create].map { _1.criteria[:from] }
    assert_equal %w[2 3], d[:delete].map(&:id).sort
    assert_equal ["1"], d[:keep].map(&:id)
  end

  def test_overlaps
    narrow = rule(from: "noreply@git.example.edu", label: "Dev/GitHub", skip_inbox: true)
    broad = rule(from: "noreply@git.example.edu|notifications@github.com", label: "Dev/GitHub",
                 skip_inbox: true)
    other = rule(from: "noreply@git.example.edu", label: "Other")
    assert_equal [[narrow, broad]], overlaps([narrow, broad, other])
  end

  def test_progress_line
    p = Gmail::Progress.new("x", 100, every: 999)
    p.step(25)
    assert_match %r{\Ax: 25/100 \(25%\) eta }, p.line
  end

  def test_count_uses_id_only_list
    real = Gmail.method(:list_ids)
    Gmail.define_singleton_method(:list_ids) { |_q| %w[a b c] }
    q = Gmail::Query.new("from:x")
    assert_equal 3, q.count
    assert_equal 3, q.expect(3).modify!(add: "TRASH", dry_run: true)
  ensure
    Gmail.define_singleton_method(:list_ids, real)
  end
end
