GODOT_CONTAINER := ./tools/godot-container
RULES_EDITOR_DIR := ./tools/rules_editor
RULES_DB ?= $(CURDIR)/assets/converted/rules.db
PERF_FRAMES ?= 300
PERF_WARMUP ?= 60
PERF_BUDGET_MS ?= 0
PERF_LABEL ?= $(shell git rev-parse --short HEAD)
# Mirror relay_main.gd's own defaults (see that file's doc comment and
# RelayServer's field doc comments for why these particular numbers) so
# `make relay` with no overrides behaves exactly like running relay_main.gd
# directly. Override per-invocation, e.g. `make relay RELAY_MAX_ROOMS=32`.
RELAY_PORT ?= 8910
RELAY_MAX_ROOM_SIZE ?= 4
RELAY_MAX_CONNECTIONS ?= 128
RELAY_MAX_ROOMS ?= 16

.PHONY: rules-editor rules-export voice-feedback voice-feedback-check unit-definitions unit-definitions-check lint install-hooks uninstall-hooks godot-image godot-check godot-test godot-perf godot-convert-map godot-convert-building godot-convert-all-buildings godot-convert-all-units godot-convert-projectiles godot-convert-placement godot-convert-cursors godot-convert-spice-mound godot-convert-audio godot-export-web godot-watch-export godot-shell godot-version relay

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

# Frame-time smoke test. Deliberately outside godot-test: the numbers are
# machine-specific, so it reports rather than asserts unless PERF_BUDGET_MS is
# set. Compare runs of the same machine, not absolute values.
godot-perf:
	$(GODOT_CONTAINER) godot --headless --path /workspace --script res://tests/perf/demo_match_perf_run.gd -- \
		--frames=$(PERF_FRAMES) --warmup=$(PERF_WARMUP) --budget-ms=$(PERF_BUDGET_MS) --label="$(PERF_LABEL)"

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
