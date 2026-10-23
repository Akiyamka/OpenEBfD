class_name SimRng
extends RefCounted

const ALGORITHM_VERSION := 1
const MAX_U32 := 0xffffffff
const U32_SPAN := 0x100000000
const MAX_SEED_DECIMAL := "9223372036854775807"
const PURPOSE_TURRET_SCAN := 1
const PURPOSE_FIRE_VARIANT := 2
const PURPOSE_SURVIVOR_SCATTER := 3
const PURPOSE_SPICE_MATURITY := 4

var seed: int
var draw_count := 0
var draw_signature := 0


func _init(match_seed: int) -> void:
	seed = match_seed


static func valid_match_seed(value: int) -> bool:
	return value > 0


## Parses unsigned decimal without relying on String.to_int() saturation.
static func parse_decimal(text_value: String, allow_zero := false) -> Dictionary:
	if text_value.is_empty() or text_value.length() > MAX_SEED_DECIMAL.length():
		return {"valid": false, "value": 0}
	var value := 0
	for index in text_value.length():
		var digit := text_value.unicode_at(index) - 48
		if digit < 0 or digit > 9:
			return {"valid": false, "value": 0}
		if value > (9223372036854775807 - digit) / 10:
			return {"valid": false, "value": 0}
		value = value * 10 + digit
	return {"valid": value > 0 or allow_zero, "value": value}


static func _sample(match_seed: int, purpose_id: int, key_a: int, key_b: int, tick_or_cycle: int, draw_index: int) -> int:
	var h := 2166136261
	for byte_index in 4:
		h = ((h ^ ((ALGORITHM_VERSION >> (byte_index * 8)) & 255)) * 16777619) & MAX_U32
	for field in [match_seed, purpose_id, key_a, key_b, tick_or_cycle, draw_index]:
		for byte_index in 8:
			h = ((h ^ ((field >> (byte_index * 8)) & 255)) * 16777619) & MAX_U32
	h ^= h >> 16
	h = (h * 0x045d9f3b) & MAX_U32
	h ^= h >> 16
	h = (h * 0x045d9f3b) & MAX_U32
	h ^= h >> 16
	return h


func draw(purpose_id: int, key_a: int, key_b: int, tick_or_cycle: int, draw_index: int) -> int:
	var sample := _sample(seed, purpose_id, key_a, key_b, tick_or_cycle, draw_index)
	draw_count += 1
	draw_signature = (draw_signature + sample) & MAX_U32
	return sample


func unit_fraction(purpose_id: int, key_a: int, key_b: int, tick_or_cycle: int, draw_index: int) -> float:
	return float(draw(purpose_id, key_a, key_b, tick_or_cycle, draw_index) & 0xffffff) / 16777216.0


func bounded(purpose_id: int, key_a: int, key_b: int, tick_or_cycle: int, draw_index: int, span: int) -> Dictionary:
	if span <= 0 or span > U32_SPAN:
		return {"ok": false, "value": 0, "next_index": draw_index}
	var limit := (U32_SPAN / span) * span
	var next_index := draw_index
	while true:
		var sample := draw(purpose_id, key_a, key_b, tick_or_cycle, next_index)
		next_index += 1
		if sample < limit:
			return {"ok": true, "value": sample % span, "next_index": next_index}
	return {"ok": false, "value": 0, "next_index": next_index}


func capture_audit() -> Dictionary:
	return {"draw_count": draw_count, "draw_signature": draw_signature}


func restore_audit(count: int, signature: int) -> bool:
	if count < 0 or signature < 0 or signature > MAX_U32:
		return false
	draw_count = count
	draw_signature = signature
	return true
