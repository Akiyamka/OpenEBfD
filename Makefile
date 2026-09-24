GODOT_CONTAINER := ./tools/godot-container
RULES_EDITOR_DIR := ./tools/rules_editor
WEB_REPLAY_DIR := ./tools/web_replay
RULES_DB ?= $(CURDIR)/assets/converted/rules.db
PERF_FRAMES ?= 300
PERF_WARMUP ?= 60
PERF_BUDGET_MS ?= 0
PERF_LABEL ?= $(shell git rev-parse --short HEAD)
HEADLESS_PERF_TICKS ?= 5000
HEADLESS_PERF_WARMUP_TICKS ?= 200
HEADLESS_PERF_BUDGET_TICKS_PER_SECOND ?= 0
HEADLESS_PERF_LABEL ?= $(shell git rev-parse --short HEAD)
# Mirror relay_main.gd's own defaults (see that file's doc comment and
# RelayServer's field doc comments for why these particular numbers) so
# `make relay` with no overrides behaves exactly like running relay_main.gd
# directly. Override per-invocation, e.g. `make relay RELAY_MAX_ROOMS=32`.
RELAY_PORT ?= 8910
RELAY_MAX_ROOM_SIZE ?= 4
RELAY_MAX_CONNECTIONS ?= 128
RELAY_MAX_ROOMS ?= 16

.PHONY: rules-editor rules-export voice-feedback voice-feedback-check unit-definitions unit-definitions-check lint install-hooks uninstall-hooks godot-image godot-check godot-test godot-perf godot-headless-perf godot-convert-map godot-convert-building godot-convert-all-buildings godot-convert-all-units godot-convert-projectiles godot-convert-placement godot-convert-cursors godot-convert-spice-mound godot-convert-audio godot-export-web godot-web-headless-check godot-web-replay-load-check godot-web-replay-load-failure-check godot-web-replay-ticks-check godot-watch-export godot-shell godot-version relay measure-nagle

rules-editor:
	cd $(RULES_EDITOR_DIR) && RULES_DB="$(RULES_DB)" npm start

rules-export:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/import_rules.gd -- --db res://assets/converted/rules.db --clean

voice-feedback:
	python3 tools/generate_voice_feedback.py

voice-feedback-check:
	python3 tools/generate_voice_feedback.py --check

unit-definitions: voice-feedback
	python3 tools/generate_unit_definitions.py --db "$(RULES_DB)"

unit-definitions-check: voice-feedback-check
	python3 tools/generate_unit_definitions.py --db "$(RULES_DB)" --check

godot-image:
	$(GODOT_CONTAINER) build

godot-check:
	$(GODOT_CONTAINER) check

lint:
	python3 tools/test_check_architecture.py
	python3 tools/check_architecture.py
	$(GODOT_CONTAINER) lint

# Per-clone, so it cannot be tracked in git — run this once after cloning.
# core.hooksPath replaces .git/hooks wholesale, so any hand-written hooks in
# there stop firing until `make uninstall-hooks`.
install-hooks:
	git config core.hooksPath tools/hooks
	@echo "core.hooksPath -> tools/hooks; pre-commit now checks the staged tree"

uninstall-hooks:
	git config --unset core.hooksPath
	@echo "core.hooksPath cleared; .git/hooks is in charge again"

godot-test:
	$(MAKE) unit-definitions-check
	$(MAKE) lint
	./tools/run_godot_tests.sh
	./tools/smoke_test_headless_match.sh

# Frame-time smoke test. Deliberately outside godot-test: the numbers are
# machine-specific, so it reports rather than asserts unless PERF_BUDGET_MS is
# set. Compare runs of the same machine, not absolute values.
godot-perf:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/perf/demo_match_perf_run.gd -- \
		--frames=$(PERF_FRAMES) --warmup=$(PERF_WARMUP) --budget-ms=$(PERF_BUDGET_MS) --label="$(PERF_LABEL)"

# Headless tick-throughput measurement. Deliberately outside godot-test: the
# numbers are machine-specific, so it reports rather than asserts unless a
# budget is set. Compare runs of the same machine, not absolute values.
godot-headless-perf:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/perf/headless_match_perf_run.gd -- \
		--ticks=$(HEADLESS_PERF_TICKS) --warmup-ticks=$(HEADLESS_PERF_WARMUP_TICKS) \
		--budget-ticks-per-second=$(HEADLESS_PERF_BUDGET_TICKS_PER_SECOND) --label="$(HEADLESS_PERF_LABEL)"

godot-convert-map:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_map.gd -- --source "$(MAP)"

godot-convert-building:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_building.gd -- --building "$(BUILDING)"

godot-convert-all-buildings:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_buildings.gd

godot-convert-all-units:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_units.gd

godot-convert-projectiles:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_all_projectiles.gd

godot-convert-placement:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_placement.gd

godot-convert-cursors:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_cursor_models.gd

godot-convert-spice-mound:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_model.gd -- --source res://assets/raw_original_content/3DDATA/spice/Spicemound.xbf --output res://assets/converted/models/Spicemound/Spicemound.scn

godot-convert-audio:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://converters/convert_audio_bag.gd

godot-export-web:
	$(GODOT_CONTAINER) export-web

# Export then boot the result in Playwright's headless Chromium. The Node
# script owns the local HTTP server and tears it down on success and failure.
godot-web-headless-check: godot-export-web
	cd $(WEB_REPLAY_DIR) && npm ci
	cd $(WEB_REPLAY_DIR) && node check_headless_boot.js

# The dedicated presets select their own main scenes through project feature
# tags, leaving the shipped Web preset and demo_match.tscn untouched.
godot-web-replay-load-check:
	mkdir -p exports/web_replay_check
	$(GODOT_CONTAINER) godot --headless --quiet --path /workspace --export-release "Web Replay Load Check" "/workspace/exports/web_replay_check/index.html"
	cd $(WEB_REPLAY_DIR) && npm ci
	cd $(WEB_REPLAY_DIR) && WEB_HEADLESS_CHECK_EXPORT_DIR=../../exports/web_replay_check WEB_HEADLESS_CHECK_EXPECTED_LINE="WEB_REPLAY_CHECK_RESULT ok=true" node check_headless_boot.js

godot-web-replay-load-failure-check:
	mkdir -p exports/web_replay_check_failure
	$(GODOT_CONTAINER) godot --headless --quiet --path /workspace --export-release "Web Replay Load Failure Check" "/workspace/exports/web_replay_check_failure/index.html"
	cd $(WEB_REPLAY_DIR) && npm ci
	cd $(WEB_REPLAY_DIR) && WEB_HEADLESS_CHECK_EXPORT_DIR=../../exports/web_replay_check_failure WEB_HEADLESS_CHECK_EXPECTED_LINE="WEB_REPLAY_CHECK_RESULT ok=false message=Replay snapshot_digest \"deliberately-wrong\" does not match the match's current snapshot digest <empty, no snapshot>" WEB_HEADLESS_CHECK_EXPECTED_FAILURE=1 node check_headless_boot.js

godot-web-replay-ticks-check:
	mkdir -p exports/web_replay_check_ticks
	$(GODOT_CONTAINER) godot --headless --quiet --path /workspace --export-release "Web Replay Ticks Check" "/workspace/exports/web_replay_check_ticks/index.html"
	cd $(WEB_REPLAY_DIR) && npm ci
	cd $(WEB_REPLAY_DIR) && WEB_HEADLESS_CHECK_EXPORT_DIR=../../exports/web_replay_check_ticks WEB_HEADLESS_CHECK_EXPECTED_LINE="WEB_REPLAY_CHECK_RESULT ok=true message=Read 2 record(s) from res://scenes/dev/web_replay_check_ticks.oebr exhausted=true ticks=192 chunks=3 process_frame_delta=6 moved=true clock_ticks=192 hash=" node check_headless_boot.js

godot-watch-export:
	$(GODOT_CONTAINER) watch-export

godot-shell:
	$(GODOT_CONTAINER) shell

godot-version:
	$(GODOT_CONTAINER) version

# Runs the relay server (scripts/net/relay/relay_main.gd) in the same Godot
# container every other godot-* target uses -- no separate image. Unlike
# those, this one needs its port reachable from outside the container, so it
# goes through tools/godot-container's own `relay` subcommand (not the
# generic `godot` passthrough the other targets use), which publishes
# RELAY_PORT to the host; see that script's doc comment for why the generic
# passthrough alone is not enough.
relay:
	GODOT_RELAY_PORT=$(RELAY_PORT) $(GODOT_CONTAINER) relay \
		--max-room-size $(RELAY_MAX_ROOM_SIZE) --max-connections $(RELAY_MAX_CONNECTIONS) --max-rooms $(RELAY_MAX_ROOMS)

# Answers "is TCP_NODELAY set on the two links the netcode runs over" by
# measuring both against deliberate positive and negative controls -- see
# tools/measure_nagle.py's module doc comment. Deliberately outside
# godot-test, like godot-perf: it needs real sockets and real wall-clock
# timing, so it reports rather than asserts. Runs entirely inside the
# container, the one place `godot` and `python3` share a loopback interface,
# which is also why it needs no published port.
measure-nagle:
	$(GODOT_CONTAINER) shell -lc "python3 tools/measure_nagle.py $(NAGLE_ARGS)"
