# Gmail rules as code. Gmail is made to match this file.
#   ./gmail-rules plan           diff vs live Gmail (read-only)
#   ./gmail-rules apply          dry run: print what apply would do
#   ./gmail-rules apply --yes    make the changes (filters, then retention)
#
# filter  CRITERIA, ACTIONS
#   criteria: from: to: subject: query: negated_query: has_attachment:
#   actions:  label: skip_inbox: mark_read: never_spam: never_important:
#             trash: star: important:
# retain  "Label", older_than: "90d", action: :trash | :read
#   Counts come from the local index; writes go through Query#expect with
#   the planned count +-10%.
#
# Put your real rules in rules.local.rb (gitignored); it is loaded below.
# Bootstrap it from live Gmail:
#   ./gmr 'filters.map { rule_source(_1) }' > rules.local.rb
#
# Examples (uncomment to use):
# filter from: "notifications@github.com", label: "Dev/GitHub", skip_inbox: true
# filter subject: "nightly-build", label: "Dev/CI", skip_inbox: true, mark_read: true
# retain "Dev/CI", older_than: "90d", action: :trash

local "rules.local.rb"
