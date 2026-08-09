#!/usr/bin/env python3
"""
Rules.txt/ArtIni.txt -> SQLite importer (Emperor: Battle for Dune).

Usage:
    python3 parse_rules.py Rules.txt schema.sql rules.db [ArtIni.txt]

The logic follows the parse that was pinned down while the schema was being
designed:
  - list sections ([BuildingTypes], [UnitTypes], ...) declare which entities
    a category owns; the data itself lives in identically named sections
    further down the file;
  - composite/repeating fields (Terrain, Armour, ViewRange, Occupy,
    DeployTile/DeployAngle, VeterancyLevel, TurretAttach on units,
    ExplosionType, Resource, PrimaryBuilding/SecondaryBuilding) are not
    poured into ordinary columns but parsed by dedicated functions;
  - anything not covered by an explicit column ends up in custom_fields
    instead of being lost silently.
"""

import re
import sqlite3
import sys
from collections import defaultdict, OrderedDict

# =============================================================================
# 1. LOW-LEVEL PARSING: comments, sections
# =============================================================================

def strip_comment(line: str) -> str:
    """Comments in the file are mostly // up to the end of the line, but on
    4 lines (GPSFXLavasmoke and similar) there is a '\\\\' typo instead of
    '//' — cut on both markers and take whichever comes first."""
    idx = len(line)
    p1 = line.find('//')
    if p1 != -1:
        idx = min(idx, p1)
    p2 = line.find('\\\\')
    if p2 != -1:
        idx = min(idx, p2)
    return line[:idx].rstrip()


def strip_slash_comment(line: str) -> str:
    """ArtIni.txt uses Windows paths containing '\\\\', so strip_comment()
    from Rules.txt must not be applied to it: there '\\\\' is treated as a
    historical comment typo. Here we cut only ordinary //."""
    idx = line.find('//')
    if idx != -1:
        line = line[:idx]
    return line.rstrip()


SECTION_RE = re.compile(r'^\s*\[([^\]]+)\]')


def split_sections(path: str):
    """Returns a list of (name, start_line, body), body = [(line_no, text), ...]."""
    with open(path, encoding='latin1') as f:
        raw_lines = f.read().splitlines()

    sections = []
    cur_name = None
    cur_start = None
    cur_body = []
    for i, raw in enumerate(raw_lines):
        line = strip_comment(raw)
        m = SECTION_RE.match(line)
        if m:
            if cur_name is not None:
                sections.append((cur_name, cur_start, cur_body))
            cur_name = m.group(1).strip()
            cur_start = i + 1
            cur_body = []
        else:
            if cur_name is not None and line.strip():
                cur_body.append((i + 1, line.strip()))
    if cur_name is not None:
        sections.append((cur_name, cur_start, cur_body))
    return sections


def classify_sections(sections):
    """list_secs are the enumeration sections (no '='), data_secs the
    key=value ones. A section counts as data if any line contains '='."""
    list_secs = []
    data_secs = defaultdict(list)  # name -> [(start_line, body), ...] (duplicates possible)
    for name, start, body in sections:
        has_eq = any('=' in text for _, text in body)
        if has_eq:
            data_secs[name].append((start, body))
        else:
            list_secs.append((name, start, body))
    return list_secs, data_secs


def build_data_secs_lower(data_secs):
    """Reverse index: name(lower) -> the exact key name in data_secs.
    Needed because 14 entities in the file are declared in the [XxxTypes]
    list with one casing while the section body uses another (Cal50_B in the
    declaration but [cal50_B] as the section header; IMTANK vs [IMTank];
    ATPillbox vs [ATPillBox], and so on) — found while checking the imported
    data: those 14 entities silently stayed empty (id+name only) because the
    exact-match data_secs dict never found them."""
    result = {}
    for key in data_secs:
        result.setdefault(key.lower(), key)
    return result


def get_data_section(data_secs, data_secs_lower, name):
    """Exact lookup, with a case-insensitive fallback on a miss."""
    occs = data_secs.get(name)
    if occs:
        return occs
    exact_key = data_secs_lower.get(name.lower())
    if exact_key is not None:
        return data_secs.get(exact_key)
    return None


def get_all_data_sections_casefold(data_secs, name):
    """Return every occurrence of a logical section, including case variants."""
    result = []
    folded_name = name.lower()
    for section_name, occurrences in data_secs.items():
        if section_name.lower() == folded_name:
            result.extend(occurrences)
    return sorted(result, key=lambda occurrence: occurrence[0])


CATEGORY_LISTS = [
    'BuildingTypes', 'UnitTypes', 'TurretTypes', 'BulletTypes', 'ExplosionTypes',
    'WarheadTypes', 'ArmourTypes', 'SplatTypes', 'CrateTypes', 'SpiceMoundTypes',
    'DebrisTypes', 'HouseTypes', 'TerrainTypes', 'BuildingGroupTypes', 'UnitGroupTypes',
]

CATEGORY_PRIORITY = [
    'UnitTypes', 'BuildingTypes', 'TurretTypes', 'BulletTypes', 'WarheadTypes',
    'ExplosionTypes', 'DebrisTypes', 'CrateTypes', 'SplatTypes', 'SpiceMoundTypes',
    'HouseTypes',
]


def build_membership(list_secs):
    """membership: name(lower) -> set of categories where it is declared.
    order: category -> names in order of first appearance (deduped by lower).
    first_line: category -> {name(lower): line number of first appearance}."""
    membership = defaultdict(set)
    order = defaultdict(list)
    seen = defaultdict(set)
    first_line = defaultdict(dict)
    for name, start, body in list_secs:
        if name not in CATEGORY_LISTS:
            continue
        for line_no, item in body:
            item = item.strip()
            if not item:
                continue
            key = item.lower()
            membership[key].add(name)
            if key not in seen[name]:
                seen[name].add(key)
                order[name].append(item)
                first_line[name][key] = line_no
    return membership, order, first_line


def category_of(name, membership):
    cats = membership.get(name.lower(), set())
    if not cats:
        return None
    for pref in CATEGORY_PRIORITY:
        if pref in cats:
            return pref
    return next(iter(cats))


# =============================================================================
# 2. TYPE CONVERTERS
# =============================================================================

def to_bool(v):
    v = v.strip().lower()
    if v in ('true', '1'):
        return 1
    if v in ('false', '0'):
        return 0
    return None


def to_int(v):
    try:
        return int(float(v.strip()))
    except (ValueError, TypeError):
        return None


def to_float(v):
    try:
        return float(v.strip())
    except (ValueError, TypeError):
        return None


def to_text(v):
    v = v.strip()
    return v if v else None


CONVERTERS = {'bool': to_bool, 'int': to_int, 'float': to_float, 'text': to_text}

# =============================================================================
# 3. FIELDS HANDLED SPECIALLY (not through the ordinary column map)
# =============================================================================

SPECIAL_KEYS = {
    'terrain', 'armour', 'viewrange', 'primarybuilding',
    'secondarybuilding', 'resource', 'occupy', 'deploytile', 'deployangle',
    'veterancylevel', 'explosiontype',
    # 'turretattach' is deliberately NOT here: on units it is already
    # consumed explicitly (used.add) by separate code before apply_fields
    # because it can hold several values (see unit_turrets), while on
    # buildings (a single value) it must resolve normally through
    # BUILDING_RELATION inside apply_fields. 'turretattach' used to be in this
    # set, and apply_fields skipped it unconditionally for ANY entity before
    # checking relation_map — which silently lost TurretAttach on buildings
    # (HKFlameTurret and 8 more), not even reaching custom_fields. Found by
    # checking a live database.
}

VETERANCY_FIELD_MAP = {
    'extradamage': ('extra_damage_percent', 'float'),
    'extraarmour': ('extra_armour_percent', 'float'),
    'extrarange': ('extra_range_percent', 'float'),
    'speed': ('speed_override', 'float'),
    'health': ('health_override', 'int'),
    'canselfrepair': ('can_self_repair', 'bool'),
    'elite': ('elite', 'bool'),
    'stealthedwhenstill': ('stealthed_when_still', 'bool'),
}

# Building roles (Factory/Wall/Refinery/Barracks/Hanger/Dockable/Outpost/
# Starport/PopupTurret) are a classification axis independent of
# building_group_id (see building_roles in schema.sql).
ROLE_CANONICAL = {
    'wall': 'Wall',
    'barracks': 'Barracks',
    'outpost': 'Outpost',
    'refinery': 'Refinery',
    'dockable': 'Dockable',
    'factory': 'Factory',
    'hanger': 'Hanger',
    'helipad': 'Helipad',
    'starport': 'Starport',
    'popupturret': 'PopupTurret',
}

# =============================================================================
# 4. PER-CATEGORY COLUMN MAPS
#    lower(key_in_Rules.txt) -> (table_column, type)
#    Scalar fields only. Relational ones (which need a name -> id resolve)
#    live in the separate RELATION_MAPs.
# =============================================================================

UNIT_SCALAR = {
    'cost': ('cost', 'int'),
    'buildtime': ('build_time', 'int'),
    'size': ('size', 'int'),
    'speed': ('speed', 'float'),
    'turnrate': ('turn_rate', 'float'),
    'health': ('health', 'int'),
    'techlevel': ('tech_level', 'int'),
    'stormdamage': ('storm_damage', 'int'),
    'tastytoworms': ('tasty_to_worms', 'bool'),
    'wormattraction': ('worm_attraction', 'int'),
    'aithreat': ('ai_threat', 'int'),
    'score': ('score', 'int'),
    'reinforcementvalue': ('reinforcement_value', 'int'),
    'canmoveanydirection': ('can_move_any_direction', 'bool'),
    'canbedeviated': ('can_be_deviated', 'bool'),
    'canselfrepair': ('can_self_repair', 'bool'),
    'canberepaired': ('can_be_repaired', 'bool'),
    'infantry': ('infantry', 'bool'),
    'crushable': ('crushable', 'bool'),
    'crushes': ('crushes', 'bool'),
    'starportable': ('starportable', 'bool'),
    'aispecial': ('ai_special', 'bool'),
    'aitank': ('ai_tank', 'bool'),
    'aifoot': ('ai_foot', 'bool'),
    'aiair': ('ai_air', 'bool'),
    'aiuncontrolled': ('ai_uncontrolled', 'bool'),
    'aicritical': ('ai_critical', 'bool'),
    'getsheightadvantage': ('gets_height_advantage', 'bool'),
    'upgradedprimaryrequired': ('upgraded_primary_required', 'bool'),
    'crategift': ('crate_gift', 'bool'),
    'heightoffset': ('height_offset', 'float'),
    'excludefromskirmishlose': ('exclude_from_skirmish_lose', 'bool'),
    'canbeengineered': ('can_be_engineered', 'bool'),
    'canbesuppressed': ('can_be_suppressed', 'bool'),
    'canfly': ('can_fly', 'bool'),
    'candie': ('can_die', 'bool'),
    'cantbeleeched': ('cant_be_leeched', 'bool'),
    'advancedcarryall': ('advanced_carryall', 'bool'),
    'ornithoptor': ('ornithoptor', 'bool'),
    'carryall': ('carryall', 'bool'),
    'projectable': ('projectable', 'bool'),
    'circles': ('circles', 'bool'),
    'selectable': ('selectable', 'bool'),
    'hitslowdownamount': ('hit_slow_down_amount', 'int'),
    'hitslowdownduration': ('hit_slow_down_duration', 'int'),
    'stealthedwhenstill': ('stealthed_when_still', 'bool'),
    'roofheight': ('roof_height', 'int'),
    'missiletrail': ('missile_trail', 'int'),
    'missiletrailsize': ('missile_trail_size', 'int'),
    'missiletrailwigglefreq': ('missile_trail_wiggle_freq', 'int'),
    'missiletrailwigglescale': ('missile_trail_wiggle_scale', 'int'),
    'missiletraillength': ('missile_trail_length', 'int'),
    'missiletraildelta': ('missile_trail_delta', 'float'),
    'shieldhealth': ('shield_health', 'float'),
}

# relation fields: key -> (column, lookup table used to resolve it)
UNIT_RELATION = {
    'house': ('house_id', 'houses'),
    'unitgroup': ('unit_group_id', 'unit_groups'),
    'debris': ('debris_id', 'debris_types'),
    'chaoseffect': ('chaos_effect_id', 'explosion_types'),
    'hawkeffect': ('hawk_effect_id', 'explosion_types'),
    'damageeffect': ('damage_effect_id', 'explosion_types'),
    'specialground': ('special_ground_terrain_id', 'terrain_types'),
}

BUILDING_SCALAR = {
    'cost': ('cost', 'int'),
    'buildtime': ('build_time', 'int'),
    'health': ('health', 'int'),
    'techlevel': ('tech_level', 'int'),
    'powerused': ('power_used', 'int'),
    'powergenerated': ('power_generated', 'int'),
    'stormdamage': ('storm_damage', 'int'),
    'roofheight': ('roof_height', 'int'),
    'score': ('score', 'int'),
    'numinfantrywhengone': ('num_infantry_when_gone', 'int'),
    'canbeengineered': ('can_be_engineered', 'bool'),
    'canbeprimary': ('can_be_primary', 'bool'),
    'conyard': ('is_con_yard', 'bool'),
    'aiexit': ('ai_exit', 'bool'),
    'upgradetechlevel': ('upgrade_tech_level', 'int'),
    'upgradecost': ('upgrade_cost', 'int'),
    'aimanufacturing': ('ai_manufacturing', 'bool'),
    'selectable': ('selectable', 'bool'),
    'aidefence': ('ai_defence', 'bool'),
    'aicritical': ('ai_critical', 'bool'),
    'aicore': ('ai_core', 'bool'),
    'airesource': ('ai_resource', 'bool'),
    'aithreat': ('ai_threat', 'int'),
    'unstealthrange': ('unstealth_range', 'float'),
    'excludefromskirmishlose': ('exclude_from_skirmish_lose', 'bool'),
    'excludefromcampaignlose': ('exclude_from_campaign_lose', 'bool'),
    'countsforstats': ('counts_for_stats', 'bool'),
    'getsheightadvantage': ('gets_height_advantage', 'bool'),
    'objecttypewhengone': ('object_type_when_gone', 'text'),  # polymorphic, not resolved
    'upgradedprimaryrequired': ('upgraded_primary_required', 'bool'),
    'disablewithlowpower': ('disable_with_low_power', 'bool'),
    'disableifnospiceonmap': ('disable_if_no_spice_on_map', 'bool'),
    'hideunitonradar': ('hide_unit_on_radar', 'bool'),
    'rangeindicator': ('range_indicator', 'int'),
    'rangemask': ('range_mask', 'int'),
}

BUILDING_RELATION = {
    'house': ('house_id', 'houses'),
    'group': ('building_group_id', 'building_groups'),
    'armour': ('armour_type_id', 'armour_types'),  # on buildings Armour is always a single value
    'turretattach': ('turret_attach_id', 'turrets'),  # single value on buildings (unlike units)
    'debris': ('debris_id', 'debris_types'),
    'chaoseffect': ('chaos_effect_id', 'explosion_types'),
    'hawkeffect': ('hawk_effect_id', 'explosion_types'),
    'damageeffect': ('damage_effect_id', 'explosion_types'),
    'getunitwhenbuilt': ('get_unit_when_built_id', 'units'),  # resolved in a second pass
}

TURRET_SCALAR = {
    'reloadcount': ('reload_count', 'int'),
    'turretmuzzleflash': ('turret_muzzle_flash', 'text'),
    'turretyrotationangle': ('turret_y_rotation_angle', 'float'),
    'turretminyrotation': ('turret_min_y_rotation', 'float'),
    'turretmaxyrotation': ('turret_max_y_rotation', 'float'),
    'turretminxrotation': ('turret_min_x_rotation', 'float'),
    'turretmaxxrotation': ('turret_max_x_rotation', 'float'),
    'turretxrotationangle': ('turret_x_rotation_angle', 'float'),
    'turretdisableifunitdeployed': ('turret_disable_if_unit_deployed', 'bool'),
    'turretdisableifunitundeployed': ('turret_disable_if_unit_undeployed', 'bool'),
    'turretyacceptableaim': ('turret_y_acceptable_aim', 'float'),
    'turretxacceptableaim': ('turret_x_acceptable_aim', 'float'),
    'turretbulletcount': ('turret_bullet_count', 'int'),
}

TURRET_RELATION = {
    'bullet': ('bullet_id', 'bullets'),
    'turretnextjoint': ('turret_next_joint_id', 'turrets'),  # self-reference, resolved in a second pass
}

BULLET_SCALAR = {
    'damage': ('damage', 'float'),
    'maxrange': ('max_range', 'float'),
    'minrange': ('min_range', 'float'),
    'speed': ('speed', 'float'),
    'blowup': ('blow_up', 'bool'),
    'blastradius': ('blast_radius', 'float'),
    'shot': ('shot', 'bool'),
    'reducedamagewithdistance': ('reduce_damage_with_distance', 'bool'),
    'missiletrail': ('missile_trail', 'int'),
    'missiletrailsize': ('missile_trail_size', 'int'),
    'missiletrailwigglefreq': ('missile_trail_wiggle_freq', 'int'),
    'missiletrailwigglescale': ('missile_trail_wiggle_scale', 'int'),
    'missiletraillength': ('missile_trail_length', 'int'),
    'missiletraildelta': ('missile_trail_delta', 'float'),
    'friendlydamageamount': ('friendly_damage_amount', 'float'),
    'antiaircraft': ('anti_aircraft', 'bool'),
    'antiground': ('anti_ground', 'bool'),
    'homing': ('homing', 'bool'),
    'homingdelay': ('homing_delay', 'float'),
    'turnrate': ('turn_rate', 'float'),
    'continuous': ('continuous', 'bool'),
    'trajectory': ('trajectory', 'bool'),
    'burnt': ('burnt', 'bool'),
    'ignites': ('ignites', 'bool'),
    'gassed': ('gassed', 'bool'),
    'islaser': ('is_laser', 'bool'),
    'leech': ('leech', 'bool'),
    'infantry': ('infantry', 'bool'),
    'health': ('health', 'float'),
    'shieldhealth': ('shield_health', 'float'),
    'damagecolumn': ('damage_column', 'bool'),
    'lingerduration': ('linger_duration', 'float'),
    'lingerdamage': ('linger_damage', 'float'),
    'deviate': ('deviate', 'bool'),
    'beserk': ('beserk', 'bool'),
    'retreat': ('retreat', 'bool'),
    # DamageFriendly collapses into the same column as FriendlyDamageAmount
    # (see schema.sql) — it is handled separately before the main loop.
}

BULLET_RELATION = {
    'warhead': ('warhead_id', 'warheads'),
    'debris': ('debris_id', 'debris_types'),
}

DEBRIS_SCALAR = {
    'missiletrail': ('missile_trail', 'int'),
    'missiletrailsize': ('missile_trail_size', 'int'),
    'missiletrailwigglefreq': ('missile_trail_wiggle_freq', 'int'),
    'missiletrailwigglescale': ('missile_trail_wiggle_scale', 'int'),
    'missiletraillength': ('missile_trail_length', 'int'),
    'missiletraildelta': ('missile_trail_delta', 'float'),
}

CRATE_SCALAR = {
    'size': ('size', 'int'),
    'health': ('health', 'int'),
    'crategiftobject': ('crate_gift_object', 'text'),
    'lifespan': ('lifespan', 'int'),
}

SPLAT_SCALAR = {
    'size': ('size', 'int'),
    'lifespan': ('lifespan', 'int'),
    'homingdelay': ('homing_delay', 'float'),
    'resource': ('resource', 'text'),  # on splats Resource is a single bullet reference, kept as raw text
    'damage': ('damage', 'float'),
}

SPICE_MOUND_SCALAR = {
    'health': ('health', 'int'),
    'size': ('size', 'int'),
    'cost': ('cost', 'int'),
    'blastradius': ('blast_radius', 'float'),
    'spicecapacity': ('spice_capacity', 'int'),
    'resource': ('resource', 'text'),
    'buildtime': ('build_time', 'int'),
    'minrange': ('min_range', 'float'),
    'maxrange': ('max_range', 'float'),
}

HOUSE_SCALAR = {
    'soundfile': ('sound_file', 'text'),
    'subhouse': ('is_sub_house', 'bool'),
}

EXPLOSION_CONFIG_SCALAR = {
    'damagetotile': ('damage_to_tile', 'float'),
    'facecamera': ('face_camera', 'bool'),
}

GENERAL_SCALAR = {
    'version': ('version', 'text'),
    'spicevalue': ('spice_value', 'int'),
    'fogregrowrate': ('fog_regrow_rate', 'int'),
    'repairrate': ('repair_rate', 'int'),
    'rearmrate': ('rearm_rate', 'int'),
    'starportcostupdatedelay': ('starport_cost_update_delay', 'int'),
    'starportcostvariationpercent': ('starport_cost_variation_percent', 'int'),
    'starportstockincreaseprob': ('starport_stock_increase_prob', 'int'),
    'starportstockincreasedelay': ('starport_stock_increase_delay', 'int'),
    'starportmaxdeliverysingle': ('starport_max_delivery_single', 'int'),
    'frigatecountdown': ('frigate_countdown', 'int'),
    'harvreplacementdelay': ('harv_replacement_delay', 'int'),
    'hawkstrikeduration': ('hawk_strike_duration', 'int'),
    'lightningduration': ('lightning_duration', 'int'),
    'deviateduration': ('deviate_duration', 'int'),
    'soundstealthon': ('sound_stealth_on', 'text'),
    'soundstealthoff': ('sound_stealth_off', 'text'),
    'soundshieldon': ('sound_shield_on', 'text'),
    'soundshieldoff': ('sound_shield_off', 'text'),
    'soundradaron': ('sound_radar_on', 'text'),
    'soundradaroff': ('sound_radar_off', 'text'),
    'advcarryallpickupenemydelay': ('adv_carryall_pickup_enemy_delay', 'int'),
    'stealthdelay': ('stealth_delay', 'int'),
    'stealthdelayafterfiring': ('stealth_delay_after_firing', 'int'),
    'guardtilerange': ('guard_tile_range', 'int'),
    'minwormridewaitdelay': ('min_worm_ride_wait_delay', 'int'),
    'maxwormridewaitdelay': ('max_worm_ride_wait_delay', 'int'),
    'frigatetimeout': ('frigate_timeout', 'int'),
    'repairtilerange': ('repair_tile_range', 'int'),
    'wormriderlifespan': ('worm_rider_lifespan', 'int'),
    'maxbuildingplacementtiledist': ('max_building_placement_tile_dist', 'int'),
    'mincarrytiledist': ('min_carry_tile_dist', 'int'),
    'bulletgravity': ('bullet_gravity', 'float'),
    'suppressiondelay': ('suppression_delay', 'int'),
    'suppressionprob': ('suppression_prob', 'int'),
    'infrockrangebonus': ('inf_rock_range_bonus', 'int'),
    'heightrangebonus': ('height_range_bonus', 'int'),
    'infdamagerangebonus': ('inf_damage_range_bonus', 'int'),
    'maximumsurfaceworms': ('maximum_surface_worms', 'int'),
    'chanceofsurfaceworm': ('chance_of_surface_worm', 'int'),
    'chanceofverticalworm': ('chance_of_vertical_worm', 'int'),
    'surfacewromminlife': None,
    'surfacewormminlife': ('surface_worm_min_life', 'int'),
    'surfacewormmaxlife': ('surface_worm_max_life', 'int'),
    'surfacewormdisappearhealth': ('surface_worm_disappear_health', 'int'),
    'minimumtickswormcanappear': ('minimum_ticks_worm_can_appear', 'int'),
    'wormattractionradius': ('worm_attraction_radius', 'int'),
    'unitvalueattacker': ('unit_value_attacker', 'int'),
    'unitvaluedefender': ('unit_value_defender', 'int'),
    'unitvaluereserves': ('unit_value_reserves', 'int'),
    'unitvalueinitialreinforcements': ('unit_value_initial_reinforcements', 'int'),
    'unitvaluesubsequentreinforcements': ('unit_value_subsequent_reinforcements', 'int'),
    'ticksbetweenreinforcements': ('ticks_between_reinforcements', 'int'),
    'ticksbetweenreinforcementsvariation': ('ticks_between_reinforcements_variation', 'int'),
    'ticksbeforereinforcementsformessage': ('ticks_before_reinforcements_for_message', 'int'),
    'stormkillchance': ('storm_kill_chance', 'int'),
    'stormminwait': ('storm_min_wait', 'int'),
    'stormmaxwait': ('storm_max_wait', 'int'),
    'stormmaxlife': ('storm_max_life', 'int'),
    'stormminlife': ('storm_min_life', 'int'),
    'cashdeliverywhennospiceamountmax': ('cash_delivery_when_no_spice_amount_max', 'int'),
    'cashdeliverywhennospiceamountmin': ('cash_delivery_when_no_spice_amount_min', 'int'),
    'cashdeliverywhennospicefrequencymax': ('cash_delivery_when_no_spice_frequency_max', 'int'),
    'cashdeliverywhennospicefrequencymin': ('cash_delivery_when_no_spice_frequency_min', 'int'),
    'campaignattackmoney': ('campaign_attack_money', 'int'),
    'campaigndefendmoney': ('campaign_defend_money', 'int'),
    'replicashouldfire': ('replica_should_fire', 'bool'),
    'replicaflickerchancewhenmoving': ('replica_flicker_chance_when_moving', 'float'),
    'replicaflickerchancewhenstill': ('replica_flicker_chance_when_still', 'float'),
    'replicaprojectiontime': ('replica_projection_time', 'int'),
    'replicavanishtime': ('replica_vanish_time', 'int'),
    'easybuildtime': ('easy_build_time', 'int'),
    'normalbuildtime': ('normal_build_time', 'int'),
    'hardbuildtime': ('hard_build_time', 'int'),
    'easybuildcost': ('easy_build_cost', 'int'),
    'normalbuildcost': ('normal_build_cost', 'int'),
    'hardbuildcost': ('hard_build_cost', 'int'),
}
GENERAL_SCALAR = {k: v for k, v in GENERAL_SCALAR.items() if v is not None}

ART_SCALAR = {
    'icon': ('icon', 'text'),
    'icongrey': ('icon_grey', 'text'),
    'xaf': ('xaf', 'text'),
    'xafconstruction': ('xaf_construction', 'text'),
    'sidebartype': ('sidebar_type', 'text'),
    'clipsphere': ('clip_sphere', 'float'),
    'crapshadowsize': ('crap_shadow_size', 'float'),
}

ART_FLAGS = {
    'loadflagonlypreplaced': 'load_flag_only_preplaced',
}

ART_ENTITY_PRIORITY = [
    ('unit', 'units'),
    ('building', 'buildings'),
    ('bullet', 'bullets'),
    ('explosion_type', 'explosion_types'),
    ('crate_type', 'crate_types'),
    ('debris_type', 'debris_types'),
    ('splat_type', 'splat_types'),
    ('spice_mound_type', 'spice_mound_types'),
]

ART_NAME_ALIASES = {
    # ArtIni.txt: [INGUCyclopsHouse], Rules.txt: INGUCyclopseHouse.
    # Keep the original art_name, but attach it to the live Rules entity.
    'ingucyclopshouse': 'INGUCyclopseHouse',
}

# =============================================================================
# 5. NAME -> ID RESOLVERS (filled in as rows are inserted)
# =============================================================================

class NameRegistry:
    """id caches per lookup/entity table, keyed by lower(name)."""
    def __init__(self):
        self.tables = defaultdict(dict)  # table -> {name.lower(): id}

    def register(self, table, name, id_):
        self.tables[table][name.strip().lower()] = id_

    def resolve(self, table, name):
        if name is None:
            return None
        return self.tables[table].get(name.strip().lower())


# =============================================================================
# 6. COMPOSITE FIELDS — VALUE PARSING
# =============================================================================

COORD_PAIR_RE = re.compile(r'(-?\d+)\s*,\s*(-?\d+)')
ART_CALL_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*;?\s*$')


def parse_terrain_list(value):
    return [t.strip() for t in value.split(',') if t.strip()]


def parse_armour(value):
    """'Medium' -> (armour, None, None)
    'None, 50, InfRock' -> (armour, modifier_percent, terrain)"""
    parts = [p.strip() for p in value.split(',')]
    armour_name = parts[0] if parts else None
    modifier = to_float(parts[1]) if len(parts) > 1 else None
    terrain = parts[2] if len(parts) > 2 else None
    return armour_name, modifier, terrain


def parse_view_range(value):
    """'10' -> (10, None, None)
    '4, 8' -> (4, 8, None)
    '4,14,InfRock' -> (4, 14, 'InfRock')"""
    parts = [p.strip() for p in value.split(',')]
    base = to_float(parts[0]) if len(parts) > 0 else None
    bonus = to_float(parts[1]) if len(parts) > 1 else None
    terrain = parts[2] if len(parts) > 2 else None
    return base, bonus, terrain


def parse_name_list(value):
    return [p.strip() for p in value.split(',') if p.strip()]


def parse_deploy_points(body, used_line_indices):
    """Finds every DeployTile (and the optional DeployAngle following it) in
    body (a list of (line_no, text)). Returns a list of (tile_x, tile_y, angle).
    used_line_indices is the set of already consumed body line indices (so that
    DeployAngle is not handed to general/overflow processing a second time)."""
    points = []
    n = len(body)
    for i, (line_no, text) in enumerate(body):
        if i in used_line_indices:
            continue
        k, _, v = text.partition('=')
        if k.strip().lower() != 'deploytile':
            continue
        used_line_indices.add(i)
        pairs = COORD_PAIR_RE.findall(v)
        angle = None
        if len(pairs) == 1 and i + 1 < n:
            next_line_no, next_text = body[i + 1]
            nk, _, nv = next_text.partition('=')
            if nk.strip().lower() == 'deployangle':
                angle = to_float(nv)
                used_line_indices.add(i + 1)
        for x_str, y_str in pairs:
            points.append((int(x_str), int(y_str), angle))
    return points


def parse_veterancy_blocks(body, used_line_indices):
    """Returns a list of dicts, one per VeterancyLevel block:
    {'score': int, <column>: value, ...}"""
    blocks = []
    n = len(body)
    i = 0
    while i < n:
        line_no, text = body[i]
        if i in used_line_indices:
            i += 1
            continue
        k, _, v = text.partition('=')
        if k.strip().lower() != 'veterancylevel':
            i += 1
            continue
        used_line_indices.add(i)
        block = {'score': to_int(v)}
        j = i + 1
        while j < n:
            jk, _, jv = body[j][1].partition('=')
            jk_low = jk.strip().lower()
            if jk_low not in VETERANCY_FIELD_MAP:
                break
            column, kind = VETERANCY_FIELD_MAP[jk_low]
            block[column] = CONVERTERS[kind](jv)
            used_line_indices.add(j)
            j += 1
        blocks.append(block)
        i = j
    return blocks


def parse_occupy_rows(body, used_line_indices):
    rows = []
    for i, (line_no, text) in enumerate(body):
        if i in used_line_indices:
            continue
        k, _, v = text.partition('=')
        if k.strip().lower() == 'occupy':
            rows.append(v.strip())
            used_line_indices.add(i)
    return rows


def parse_explosion_types_multi(body, used_line_indices, reg=None):
    """Returns the section's ExplosionType names, still a list because the
    schema allows several, but a REPEATED key is an override, not an extra
    entry: the last assignment wins.

    Three sections declare ExplosionType twice — DevPlasma_B
    (ShellHit -> DevImpact), IXInfiltrator (Explosion -> InfiltratorDeath) and
    HKFactory (BigExplosion twice, inert). Reading those as a list was wrong:
    it made DevPlasma_B the only bullet of 72 with two impact effects, and the
    stale first value rendered on top of the real one in game. Rules.txt
    repeats plenty of other scalar keys the same way and every one of them is
    an override (ATAPC Speed 8.0 -> 12.0, ATOutpost Health 100 -> 2500,
    GUWormhead Armour Heavy -> Light). See docs/quirks.md.

    The winner is the last name that actually names an explosion type.
    IXInfiltrator's second value is `InfiltratorDeath`, which is a *bullet*,
    not an explosion type — a plain lexical last-wins would resolve to nothing
    and strip that unit's death explosion, so an unresolvable later value
    leaves the last resolvable one standing.
    """
    names = []
    for i, (line_no, text) in enumerate(body):
        if i in used_line_indices:
            continue
        k, _, v = text.partition('=')
        if k.strip().lower() == 'explosiontype':
            name = v.strip()
            used_line_indices.add(i)
            if names and reg is not None \
                    and reg.resolve('explosion_types', name) is None:
                continue
            names = [name]
    return names


def unquote_art_value(value):
    value = value.strip().rstrip(';').strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def split_art_args(arg_text):
    args = []
    cur = []
    in_quote = False
    escape = False
    for ch in arg_text:
        if escape:
            cur.append(ch)
            escape = False
            continue
        if ch == '\\' and in_quote:
            cur.append(ch)
            escape = True
            continue
        if ch == '"':
            cur.append(ch)
            in_quote = not in_quote
            continue
        if ch == ',' and not in_quote:
            args.append(unquote_art_value(''.join(cur)))
            cur = []
            continue
        cur.append(ch)
    if cur or arg_text.strip():
        args.append(unquote_art_value(''.join(cur)))
    return [arg for arg in args if arg != '']


def parse_art_ini(path):
    """Returns (globals, sections), where globals are the calls before the
    first [Section] and sections is a list of (name, start_line, body). body
    holds ('field', line_no, key, value) and ('flag', line_no, key, None)."""
    with open(path, encoding='latin1') as f:
        raw_lines = f.read().splitlines()

    globals_ = []
    sections = []
    cur_name = None
    cur_start = None
    cur_body = []

    for i, raw in enumerate(raw_lines):
        line = strip_slash_comment(raw).strip()
        if not line:
            continue

        m = SECTION_RE.match(line)
        if m:
            if cur_name is not None:
                sections.append((cur_name, cur_start, cur_body))
            cur_name = m.group(1).strip()
            cur_start = i + 1
            cur_body = []
            continue

        if cur_name is None:
            cm = ART_CALL_RE.match(line)
            if cm:
                globals_.append((i + 1, cm.group(1), split_art_args(cm.group(2))))
            continue

        if '=' in line:
            k, _, v = line.partition('=')
            cur_body.append(('field', i + 1, k.strip(), unquote_art_value(v)))
        else:
            cur_body.append(('flag', i + 1, line.rstrip(';').strip(), None))

    if cur_name is not None:
        sections.append((cur_name, cur_start, cur_body))

    return globals_, sections


# =============================================================================
# 7. APPLYING FIELDS TO A ROW + OVERFLOW
# =============================================================================

def apply_fields(body, used_line_indices, scalar_map, relation_map, registry,
                  entity_type, row, overflow, source_line_key='source_line'):
    """Walks body, fills row from scalar_map/relation_map, and puts
    everything unknown (and not in SPECIAL_KEYS, which is handled separately
    before/after this function is called) into overflow."""
    for i, (line_no, text) in enumerate(body):
        if i in used_line_indices:
            continue
        if '=' not in text:
            continue
        k, _, v = text.partition('=')
        k_raw = k.strip()
        k_low = k_raw.lower()
        v = v.strip()

        if k_low in SPECIAL_KEYS:
            continue  # handled by dedicated functions on the outside

        if k_low in scalar_map:
            column, kind = scalar_map[k_low]
            row[column] = CONVERTERS[kind](v)
            used_line_indices.add(i)
            continue

        if k_low in relation_map:
            column, target_table = relation_map[k_low]
            row[column] = ('__RESOLVE__', target_table, v)  # resolved later (may be a forward ref)
            used_line_indices.add(i)
            continue

        # unknown field -> overflow, nothing gets lost
        overflow.append((entity_type, k_raw, v, line_no))
        used_line_indices.add(i)


def import_art_ini(cur, reg, art_path):
    globals_, sections = parse_art_ini(art_path)
    side_id = None
    art_overflow = []
    unmatched = []

    for line_no, command, args in globals_:
        command_low = command.lower()
        if command_low == 'sidebartypes':
            for seq, name in enumerate(args):
                cur.execute('INSERT OR REPLACE INTO art_sidebar_types (seq, name) VALUES (?,?)',
                            (seq, name))
        elif command_low == 'side':
            side_id = to_int(args[0]) if args else None
        elif command_low == 'recolor':
            if side_id is not None and len(args) >= 3:
                red, green, blue = (to_int(args[0]), to_int(args[1]), to_int(args[2]))
                if red is not None and green is not None and blue is not None:
                    cur.execute(
                        'INSERT OR REPLACE INTO art_side_recolors (side_id, red, green, blue) '
                        'VALUES (?,?,?,?)',
                        (side_id, red, green, blue))
                    side_id = None
                else:
                    art_overflow.append(('art_global', -1, f'{command}(invalid)', ','.join(args), line_no))
            else:
                art_overflow.append(('art_global', -1, f'{command}(orphan)', ','.join(args), line_no))
        else:
            art_overflow.append(('art_global', -1, command, ','.join(args), line_no))

    for art_name, start_line, body in sections:
        entity_type = 'unresolved'
        entity_id = None
        lookup_name = ART_NAME_ALIASES.get(art_name.lower(), art_name)
        for candidate_type, table in ART_ENTITY_PRIORITY:
            resolved = reg.resolve(table, lookup_name)
            if resolved is not None:
                entity_type = candidate_type
                entity_id = resolved
                break

        if entity_id is None:
            unmatched.append((start_line, art_name))

        row = {
            'load_flag_only_preplaced': 0,
        }
        for kind, line_no, key, value in body:
            key_low = key.strip().lower()
            if kind == 'field' and key_low in ART_SCALAR:
                column, value_type = ART_SCALAR[key_low]
                row[column] = CONVERTERS[value_type](value)
            elif kind == 'flag' and key_low in ART_FLAGS:
                row[ART_FLAGS[key_low]] = 1
            else:
                art_overflow.append(('art_config', -1, key, value, line_no))

        columns = ['entity_type', 'entity_id', 'art_name', 'icon', 'icon_grey', 'xaf',
                   'xaf_construction', 'sidebar_type', 'clip_sphere', 'crap_shadow_size',
                   'load_flag_only_preplaced', 'source_line']
        values = [entity_type, entity_id, art_name, row.get('icon'), row.get('icon_grey'),
                  row.get('xaf'), row.get('xaf_construction'), row.get('sidebar_type'),
                  row.get('clip_sphere'), row.get('crap_shadow_size'),
                  row.get('load_flag_only_preplaced', 0), start_line]
        cur.execute(
            f'INSERT INTO art_configs ({", ".join(columns)}) VALUES ({", ".join("?" for _ in columns)})',
            values)

    return {
        'sections': len(sections),
        'unmatched': unmatched,
        'overflow': art_overflow,
    }


# =============================================================================
# 8. MAIN IMPORT
# =============================================================================

def main(rules_path, schema_path, db_path, art_ini_path=None):
    sections = split_sections(rules_path)
    list_secs, data_secs = classify_sections(sections)
    data_secs_lower = build_data_secs_lower(data_secs)
    membership, order, first_line = build_membership(list_secs)

    conn = sqlite3.connect(db_path)
    conn.execute('PRAGMA foreign_keys = OFF')  # turned back on and checked at the end
    conn.executescript(open(schema_path, encoding='utf-8').read())
    cur = conn.cursor()

    reg = NameRegistry()
    overflow = []  # (entity_type, key, value, source_line) -> custom_fields
    resource_links = []  # (entity_type, entity_id, seq, target_name, source_line)
    explosion_links = []  # (entity_type, entity_id, seq, explosion_name)
    deferred_fk = []  # (table, id, column, target_table, name) -> UPDATE in a second pass
    art_report = None

    def resolve_or_defer(table, id_, column, target_table, raw):
        """raw is either a ready value or ('__RESOLVE__', target_table, name)."""
        if isinstance(raw, tuple) and raw and raw[0] == '__RESOLVE__':
            _, tt, name = raw
            resolved = reg.resolve(tt, name)
            if resolved is not None:
                return resolved
            deferred_fk.append((table, id_, column, tt, name))
            return None
        return raw

    def relation_name(raw, target_table):
        if isinstance(raw, tuple) and raw and raw[0] == '__RESOLVE__' and raw[1] == target_table:
            return raw[2]
        return None

    # -------------------------------------------------------------------
    # 8.1 Lookup tables: terrain_types, armour_types, explosion_types,
    #     building_groups, unit_groups, houses
    # -------------------------------------------------------------------

    for idx, tname in enumerate(order.get('TerrainTypes', [])):
        cur.execute('INSERT INTO terrain_types (id, name, sort_order) VALUES (?,?,?)',
                    (idx, tname, idx))
        reg.register('terrain_types', tname, idx)

    for idx, aname in enumerate(order.get('ArmourTypes', [])):
        cur.execute('INSERT INTO armour_types (id, name, sort_order) VALUES (?,?,?)',
                    (idx, aname, idx))
        reg.register('armour_types', aname, idx)

    for idx, ename in enumerate(order.get('ExplosionTypes', [])):
        line_no = first_line.get('ExplosionTypes', {}).get(ename.lower())
        cur.execute('INSERT INTO explosion_types (id, name, source_line) VALUES (?,?,?)',
                    (idx, ename, line_no))
        reg.register('explosion_types', ename, idx)

    for idx, gname in enumerate(order.get('BuildingGroupTypes', [])):
        cur.execute('INSERT INTO building_groups (id, name) VALUES (?,?)', (idx, gname))
        reg.register('building_groups', gname, idx)

    for idx, gname in enumerate(order.get('UnitGroupTypes', [])):
        cur.execute('INSERT INTO unit_groups (id, name) VALUES (?,?)', (idx, gname))
        reg.register('unit_groups', gname, idx)

    for idx, rname in enumerate(sorted(set(ROLE_CANONICAL.values()))):
        cur.execute('INSERT INTO building_roles (id, name) VALUES (?,?)', (idx, rname))
        reg.register('building_roles', rname, idx)

    # explosion_configs (DamageToTile/FaceCamera) for those explosion names
    # that have a section body of their own
    for idx, ename in enumerate(order.get('ExplosionTypes', [])):
        occs = get_all_data_sections_casefold(data_secs, ename)
        if not occs:
            continue
        row = {}
        # Rules.txt may extend one logical explosion in several sections.
        # DHBigExplosion, for example, declares FaceCamera first and
        # DamageToTile later; InkvineExplosion also differs only in casing.
        # Merge every occurrence in source order so the normalized config
        # retains all authored presentation/terrain fields.
        for _start, body in occs:
            used = set()
            occurrence = {}
            apply_fields(
                body, used, EXPLOSION_CONFIG_SCALAR, {}, reg,
                'explosion_config', occurrence, overflow
            )
            row.update(occurrence)
        if row:
            eid = reg.resolve('explosion_types', ename)
            cur.execute(
                'INSERT INTO explosion_configs (explosion_type_id, damage_to_tile, face_camera) VALUES (?,?,?)',
                (eid, row.get('damage_to_tile'), row.get('face_camera')))

    # houses: all the names first (for the sub_house resolve), then the data
    house_names = order.get('HouseTypes', [])
    for idx, hname in enumerate(house_names):
        cur.execute('INSERT INTO houses (id, name, sort_order) VALUES (?,?,?)', (idx, hname, idx))
        reg.register('houses', hname, idx)
    for hname in house_names:
        occs = get_data_section(data_secs, data_secs_lower, hname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        apply_fields(body, used, HOUSE_SCALAR, {}, reg, 'house', row, overflow)
        hid = reg.resolve('houses', hname)
        cur.execute('UPDATE houses SET sound_file=?, is_sub_house=? WHERE id=?',
                    (row.get('sound_file'), row.get('is_sub_house'), hid))

    conn.commit()

    # -------------------------------------------------------------------
    # 8.2 Warheads (+ warhead_armour_damage)
    # -------------------------------------------------------------------

    for idx, wname in enumerate(order.get('WarheadTypes', [])):
        cur.execute('INSERT INTO warheads (id, name) VALUES (?,?)', (idx, wname))
        reg.register('warheads', wname, idx)
    for wname in order.get('WarheadTypes', []):
        occs = get_data_section(data_secs, data_secs_lower, wname)
        if not occs:
            continue
        start, body = occs[0]
        wid = reg.resolve('warheads', wname)
        for line_no, text in body:
            if '=' not in text:
                continue
            k, _, v = text.partition('=')
            armour_id = reg.resolve('armour_types', k.strip())
            dmg = to_float(v)
            if armour_id is not None and dmg is not None:
                cur.execute(
                    'INSERT OR IGNORE INTO warhead_armour_damage (warhead_id, armour_type_id, damage_percent) '
                    'VALUES (?,?,?)', (wid, armour_id, dmg))
            else:
                overflow.append(('warhead', k.strip(), v.strip(), line_no))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.3 Debris
    # -------------------------------------------------------------------

    for idx, dname in enumerate(order.get('DebrisTypes', [])):
        cur.execute('INSERT INTO debris_types (id, name) VALUES (?,?)', (idx, dname))
        reg.register('debris_types', dname, idx)
    for dname in order.get('DebrisTypes', []):
        occs = get_data_section(data_secs, data_secs_lower, dname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        apply_fields(body, used, DEBRIS_SCALAR, {}, reg, 'debris_type', row, overflow)
        did = reg.resolve('debris_types', dname)
        cur.execute(
            'UPDATE debris_types SET missile_trail=?, missile_trail_size=?, missile_trail_wiggle_freq=?, '
            'missile_trail_wiggle_scale=?, missile_trail_length=?, missile_trail_delta=? WHERE id=?',
            (row.get('missile_trail'), row.get('missile_trail_size'), row.get('missile_trail_wiggle_freq'),
             row.get('missile_trail_wiggle_scale'), row.get('missile_trail_length'), row.get('missile_trail_delta'),
             did))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.4 Bullets
    # -------------------------------------------------------------------

    bullet_names = order.get('BulletTypes', [])
    for idx, bname in enumerate(bullet_names):
        cur.execute('INSERT INTO bullets (id, name) VALUES (?,?)', (idx, bname))
        reg.register('bullets', bname, idx)

    for bname in bullet_names:
        occs = get_data_section(data_secs, data_secs_lower, bname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}

        # DamageFriendly -> friendly_damage_amount (0/100) unless FriendlyDamageAmount is set separately
        for i, (line_no, text) in enumerate(body):
            if '=' not in text:
                continue
            k, _, v = text.partition('=')
            if k.strip().lower() == 'damagefriendly':
                b = to_bool(v)
                if b is not None:
                    row['friendly_damage_amount'] = 100.0 if b == 1 else 0.0
                used.add(i)

        explosion_names = parse_explosion_types_multi(body, used, reg)
        if explosion_names:
            row['explosion_type_id'] = ('__RESOLVE__', 'explosion_types', explosion_names[0])
            for seq, ename in enumerate(explosion_names):
                explosion_links.append(('bullet', bname, seq, ename))

        apply_fields(body, used, BULLET_SCALAR, BULLET_RELATION, reg, 'bullet', row, overflow)

        bid = reg.resolve('bullets', bname)
        columns = ['damage', 'max_range', 'min_range', 'warhead_id', 'debris_id', 'speed',
                   'explosion_type_id', 'blow_up', 'blast_radius', 'shot',
                   'reduce_damage_with_distance', 'missile_trail', 'missile_trail_size',
                   'missile_trail_wiggle_freq', 'missile_trail_wiggle_scale', 'missile_trail_length',
                   'missile_trail_delta', 'friendly_damage_amount', 'anti_aircraft', 'anti_ground',
                   'homing', 'homing_delay', 'turn_rate', 'continuous', 'trajectory', 'burnt',
                   'ignites', 'gassed', 'is_laser', 'leech', 'infantry', 'health', 'shield_health',
                   'damage_column', 'linger_duration', 'linger_damage', 'deviate', 'beserk', 'retreat']
        values = [resolve_or_defer('bullets', bid, c, None, row.get(c)) for c in columns]
        cur.execute(f'UPDATE bullets SET {", ".join(c + "=?" for c in columns)} WHERE id=?',
                    (*values, bid))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.5 Turrets
    # -------------------------------------------------------------------

    turret_names = order.get('TurretTypes', [])
    for idx, tname in enumerate(turret_names):
        cur.execute('INSERT INTO turrets (id, name) VALUES (?,?)', (idx, tname))
        reg.register('turrets', tname, idx)

    for tname in turret_names:
        occs = get_data_section(data_secs, data_secs_lower, tname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        apply_fields(body, used, TURRET_SCALAR, TURRET_RELATION, reg, 'turret', row, overflow)
        tid = reg.resolve('turrets', tname)
        columns = ['bullet_id', 'reload_count', 'turret_muzzle_flash', 'turret_y_rotation_angle',
                   'turret_min_y_rotation', 'turret_max_y_rotation', 'turret_min_x_rotation',
                   'turret_max_x_rotation', 'turret_x_rotation_angle', 'turret_next_joint_id',
                   'turret_disable_if_unit_deployed', 'turret_disable_if_unit_undeployed',
                   'turret_y_acceptable_aim', 'turret_x_acceptable_aim', 'turret_bullet_count']
        values = [resolve_or_defer('turrets', tid, c, None, row.get(c)) for c in columns]
        cur.execute(f'UPDATE turrets SET {", ".join(c + "=?" for c in columns)} WHERE id=?',
                    (*values, tid))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.6 Buildings (without get_unit_when_built/object_type_when_gone
    #      pointing at units — those resolve after units are loaded)
    # -------------------------------------------------------------------

    building_names = order.get('BuildingTypes', [])
    for idx, bname in enumerate(building_names):
        cur.execute('INSERT INTO buildings (id, legacy_name, name, source_line) VALUES (?,?,?,?)',
                    (idx, bname, bname,
                     first_line.get('BuildingTypes', {}).get(bname.lower())))
        reg.register('buildings', bname, idx)

    building_deploy = {}       # building_id -> [(x,y,angle), ...]
    building_occupy = {}       # building_id -> [row_pattern, ...]
    building_terrain = {}      # building_id -> [terrain_name, ...]
    building_primary = {}      # building_id -> [building_name, ...]
    building_secondary = {}    # building_id -> [building_name, ...]
    building_roles_found = {}  # building_id -> [role_name, ...]

    for bname in building_names:
        occs = get_data_section(data_secs, data_secs_lower, bname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        bid = reg.resolve('buildings', bname)

        deploy_points = parse_deploy_points(body, used)
        if deploy_points:
            building_deploy[bid] = deploy_points

        occupy_rows = parse_occupy_rows(body, used)
        if occupy_rows:
            building_occupy[bid] = occupy_rows

        explosion_names = parse_explosion_types_multi(body, used, reg)
        if explosion_names:
            row['explosion_type_id'] = ('__RESOLVE__', 'explosion_types', explosion_names[0])
            for seq, ename in enumerate(explosion_names):
                explosion_links.append(('building', bname, seq, ename))

        for i, (line_no, text) in enumerate(body):
            if i in used or '=' not in text:
                continue
            k, _, v = text.partition('=')
            k_low = k.strip().lower()
            if k_low == 'terrain':
                building_terrain[bid] = parse_terrain_list(v)
                used.add(i)
            elif k_low == 'armour':
                # Armour is globally marked as a composite/special field
                # because unit entries may add a terrain modifier. Building
                # entries use the same key but always contain a single armour
                # type, so consume it here before apply_fields skips it.
                armour_name, modifier, terrain = parse_armour(v)
                row['armour_type_id'] = (
                    ('__RESOLVE__', 'armour_types', armour_name)
                    if armour_name else None
                )
                if modifier is not None or terrain is not None:
                    overflow.append((
                        'building',
                        'Armour(modifier)',
                        v.strip(),
                        line_no,
                    ))
                used.add(i)
            elif k_low == 'primarybuilding':
                building_primary[bid] = parse_name_list(v)
                used.add(i)
            elif k_low == 'secondarybuilding':
                building_secondary[bid] = parse_name_list(v)
                used.add(i)
            elif k_low == 'resource':
                for seq, target in enumerate(parse_name_list(v)):
                    resource_links.append(('building', bname, seq, target, line_no))
                used.add(i)
            elif k_low == 'viewrange':
                base, bonus, terr = parse_view_range(v)
                row['view_range_base'] = base
                row['view_range_bonus'] = bonus
                row['view_range_bonus_terrain_id'] = ('__RESOLVE__', 'terrain_types', terr) if terr else None
                used.add(i)
            elif k_low in ROLE_CANONICAL:
                if to_bool(v) == 1:
                    building_roles_found.setdefault(bid, []).append(ROLE_CANONICAL[k_low])
                used.add(i)

        apply_fields(body, used, BUILDING_SCALAR, BUILDING_RELATION, reg, 'building', row, overflow)
        row['name'] = bname

        columns = ['name', 'house_id', 'building_group_id', 'cost', 'build_time', 'health', 'armour_type_id',
                   'tech_level', 'power_used', 'power_generated', 'storm_damage', 'roof_height', 'score',
                   'num_infantry_when_gone', 'can_be_engineered', 'can_be_primary', 'is_con_yard',
                   'ai_exit', 'upgrade_tech_level', 'upgrade_cost', 'ai_manufacturing', 'selectable',
                   'ai_defence', 'ai_critical', 'ai_core', 'ai_resource', 'ai_threat', 'unstealth_range',
                   'turret_attach_id', 'exclude_from_skirmish_lose', 'exclude_from_campaign_lose',
                   'upgraded_primary_required', 'disable_with_low_power', 'disable_if_no_spice_on_map',
                   'hide_unit_on_radar', 'range_indicator', 'range_mask', 'object_type_when_gone',
                   'chaos_effect_id', 'hawk_effect_id', 'damage_effect_id', 'explosion_type_id',
                   'debris_id', 'counts_for_stats', 'view_range_base', 'view_range_bonus',
                   'view_range_bonus_terrain_id', 'gets_height_advantage']
        values = [resolve_or_defer('buildings', bid, c, None, row.get(c)) for c in columns]
        values = [(0 if c == 'is_con_yard' and v is None else v) for c, v in zip(columns, values)]
        cur.execute(f'UPDATE buildings SET {", ".join(c + "=?" for c in columns)} WHERE id=?',
                    (*values, bid))

    for bid, points in building_deploy.items():
        for seq, (x, y, angle) in enumerate(points):
            cur.execute('INSERT INTO building_deploy_points (building_id, seq, tile_x, tile_y, angle) '
                        'VALUES (?,?,?,?,?)', (bid, seq, x, y, angle))
    for bid, rows_ in building_occupy.items():
        for seq, pattern in enumerate(rows_):
            cur.execute('INSERT INTO building_occupy_rows (building_id, row_index, pattern) VALUES (?,?,?)',
                        (bid, seq, pattern))
    for bid, terrains in building_terrain.items():
        for tname in terrains:
            tid = reg.resolve('terrain_types', tname)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO building_terrain (building_id, terrain_type_id) VALUES (?,?)',
                            (bid, tid))
            else:
                overflow.append(('building', 'Terrain(unresolved)', tname, None))

    for bid, roles in building_roles_found.items():
        for rname in roles:
            rid = reg.resolve('building_roles', rname)
            cur.execute('INSERT OR IGNORE INTO building_role_tags (building_id, role_id) VALUES (?,?)',
                        (bid, rid))

    conn.commit()

    # building_requires_primary/secondary — resolved once ALL buildings are
    # inserted (the values reference buildings that may appear later in the
    # file)
    for bid, names in building_primary.items():
        for target in names:
            tid = reg.resolve('buildings', target)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO building_requires_primary (building_id, required_building_id) '
                            'VALUES (?,?)', (bid, tid))
            else:
                overflow.append(('building', 'PrimaryBuilding(unresolved)', target, None))
    for bid, names in building_secondary.items():
        for target in names:
            tid = reg.resolve('buildings', target)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO building_requires_secondary (building_id, required_building_id) '
                            'VALUES (?,?)', (bid, tid))
            else:
                overflow.append(('building', 'SecondaryBuilding(unresolved)', target, None))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.7 Units
    # -------------------------------------------------------------------

    unit_names = order.get('UnitTypes', [])
    for idx, uname in enumerate(unit_names):
        cur.execute('INSERT INTO units (id, legacy_name, name, source_line) VALUES (?,?,?,?)',
                    (idx, uname, uname,
                     first_line.get('UnitTypes', {}).get(uname.lower())))
        reg.register('units', uname, idx)

    unit_turrets = {}      # unit_id -> [turret_name, ...]
    unit_terrain = {}
    unit_primary = {}
    unit_secondary = {}
    unit_veterancy = {}    # unit_id -> [block_dict, ...]

    for uname in unit_names:
        occs = get_data_section(data_secs, data_secs_lower, uname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        uid = reg.resolve('units', uname)

        vet_blocks = parse_veterancy_blocks(body, used)
        if vet_blocks:
            unit_veterancy[uid] = vet_blocks

        explosion_names = parse_explosion_types_multi(body, used, reg)
        if explosion_names:
            row['explosion_type_id'] = ('__RESOLVE__', 'explosion_types', explosion_names[0])
            for seq, ename in enumerate(explosion_names):
                explosion_links.append(('unit', uname, seq, ename))

        for i, (line_no, text) in enumerate(body):
            if i in used or '=' not in text:
                continue
            k, _, v = text.partition('=')
            k_low = k.strip().lower()
            if k_low == 'terrain':
                unit_terrain[uid] = parse_terrain_list(v)
                used.add(i)
            elif k_low == 'armour':
                armour_name, modifier, terr = parse_armour(v)
                row['armour_type_id'] = ('__RESOLVE__', 'armour_types', armour_name) if armour_name else None
                row['armour_modifier_percent'] = modifier
                row['armour_modifier_terrain_id'] = ('__RESOLVE__', 'terrain_types', terr) if terr else None
                used.add(i)
            elif k_low == 'viewrange':
                base, bonus, terr = parse_view_range(v)
                row['view_range_base'] = base
                row['view_range_bonus'] = bonus
                row['view_range_bonus_terrain_id'] = ('__RESOLVE__', 'terrain_types', terr) if terr else None
                used.add(i)
            elif k_low == 'turretattach':
                unit_turrets[uid] = parse_name_list(v)
                used.add(i)
            elif k_low == 'primarybuilding':
                unit_primary[uid] = parse_name_list(v)
                used.add(i)
            elif k_low == 'secondarybuilding':
                unit_secondary[uid] = parse_name_list(v)
                used.add(i)
            elif k_low == 'resource':
                for seq, target in enumerate(parse_name_list(v)):
                    resource_links.append(('unit', uname, seq, target, line_no))
                used.add(i)

        apply_fields(body, used, UNIT_SCALAR, UNIT_RELATION, reg, 'unit', row, overflow)
        row['name'] = uname

        columns = ['name', 'house_id', 'unit_group_id', 'cost', 'build_time', 'size', 'speed', 'turn_rate',
                   'armour_type_id', 'armour_modifier_percent', 'armour_modifier_terrain_id', 'health',
                   'tech_level', 'storm_damage', 'tasty_to_worms', 'worm_attraction', 'ai_threat', 'score',
                   'reinforcement_value', 'debris_id', 'chaos_effect_id', 'hawk_effect_id',
                   'damage_effect_id', 'explosion_type_id', 'can_move_any_direction', 'can_be_deviated',
                   'can_self_repair', 'can_be_repaired', 'infantry', 'crushable', 'crushes', 'starportable',
                   'ai_special', 'ai_tank', 'ai_foot', 'ai_air', 'ai_uncontrolled', 'ai_critical',
                   'gets_height_advantage', 'upgraded_primary_required',
                   'crate_gift', 'view_range_base', 'view_range_bonus', 'view_range_bonus_terrain_id',
                   'height_offset', 'exclude_from_skirmish_lose', 'can_be_engineered',
                   'can_be_suppressed', 'can_fly', 'can_die', 'cant_be_leeched', 'advanced_carryall',
                   'ornithoptor', 'carryall',
                   'projectable', 'circles', 'selectable', 'hit_slow_down_amount', 'hit_slow_down_duration',
                   'special_ground_terrain_id', 'stealthed_when_still', 'roof_height',
                   'missile_trail', 'missile_trail_size', 'missile_trail_wiggle_freq',
                   'missile_trail_wiggle_scale', 'missile_trail_length', 'missile_trail_delta',
                   'shield_health']
        values = [resolve_or_defer('units', uid, c, None, row.get(c)) for c in columns]
        cur.execute(f'UPDATE units SET {", ".join(c + "=?" for c in columns)} WHERE id=?',
                    (*values, uid))
    conn.commit()

    # unit_turrets/unit_terrain/unit_primary/unit_secondary/unit_veterancy —
    # after units and buildings are inserted (they may reference forward in the file)
    for uid, tnames in unit_turrets.items():
        for seq, tname in enumerate(tnames):
            tid = reg.resolve('turrets', tname)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO unit_turrets (unit_id, seq, turret_id) VALUES (?,?,?)',
                            (uid, seq, tid))
            else:
                overflow.append(('unit', 'TurretAttach(unresolved)', tname, None))
    for uid, tnames in unit_terrain.items():
        for tname in tnames:
            tid = reg.resolve('terrain_types', tname)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO unit_terrain (unit_id, terrain_type_id) VALUES (?,?)',
                            (uid, tid))
            else:
                overflow.append(('unit', 'Terrain(unresolved)', tname, None))
    for uid, names in unit_primary.items():
        for target in names:
            bid = reg.resolve('buildings', target)
            if bid is not None:
                cur.execute('INSERT OR IGNORE INTO unit_primary_buildings (unit_id, building_id) VALUES (?,?)',
                            (uid, bid))
            else:
                overflow.append(('unit', 'PrimaryBuilding(unresolved)', target, None))
    for uid, names in unit_secondary.items():
        for target in names:
            bid = reg.resolve('buildings', target)
            if bid is not None:
                cur.execute('INSERT OR IGNORE INTO unit_secondary_buildings (unit_id, building_id) VALUES (?,?)',
                            (uid, bid))
            else:
                overflow.append(('unit', 'SecondaryBuilding(unresolved)', target, None))
    for uid, blocks in unit_veterancy.items():
        for level_order, block in enumerate(blocks, start=1):
            cur.execute(
                'INSERT INTO unit_veterancy_levels (unit_id, level_order, veterancy_score, extra_damage_percent, '
                'extra_armour_percent, extra_range_percent, speed_override, health_override, can_self_repair, '
                'elite, stealthed_when_still) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                (uid, level_order, block.get('score'), block.get('extra_damage_percent'),
                 block.get('extra_armour_percent'), block.get('extra_range_percent'),
                 block.get('speed_override'), block.get('health_override'), block.get('can_self_repair'),
                 block.get('elite'), block.get('stealthed_when_still')))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.8 Crates, Splats, Spice mounds
    # -------------------------------------------------------------------

    crate_names = order.get('CrateTypes', [])
    for idx, cname in enumerate(crate_names):
        cur.execute('INSERT INTO crate_types (id, name) VALUES (?,?)', (idx, cname))
        reg.register('crate_types', cname, idx)
    for cname in crate_names:
        occs = get_data_section(data_secs, data_secs_lower, cname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        terrains = []
        for i, (line_no, text) in enumerate(body):
            if '=' not in text:
                continue
            k, _, v = text.partition('=')
            if k.strip().lower() == 'terrain':
                terrains = parse_terrain_list(v)
                used.add(i)
        apply_fields(body, used, CRATE_SCALAR, {}, reg, 'crate_type', row, overflow)
        cid = reg.resolve('crate_types', cname)
        cur.execute('UPDATE crate_types SET size=?, health=?, crate_gift_object=?, lifespan=? WHERE id=?',
                    (row.get('size'), row.get('health'), row.get('crate_gift_object'), row.get('lifespan'), cid))
        for tname in terrains:
            tid = reg.resolve('terrain_types', tname)
            if tid is not None:
                cur.execute('INSERT OR IGNORE INTO crate_terrain (crate_type_id, terrain_type_id) VALUES (?,?)',
                            (cid, tid))
    conn.commit()

    splat_names = order.get('SplatTypes', [])
    for idx, sname in enumerate(splat_names):
        cur.execute('INSERT INTO splat_types (id, name) VALUES (?,?)', (idx, sname))
        reg.register('splat_types', sname, idx)
    for sname in splat_names:
        occs = get_data_section(data_secs, data_secs_lower, sname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        explosion_names = parse_explosion_types_multi(body, used, reg)
        if explosion_names:
            row['explosion_type_id'] = ('__RESOLVE__', 'explosion_types', explosion_names[0])
        apply_fields(body, used, SPLAT_SCALAR, {}, reg, 'splat_type', row, overflow)
        sid = reg.resolve('splat_types', sname)
        eid = resolve_or_defer('splat_types', sid, 'explosion_type_id', None, row.get('explosion_type_id'))
        cur.execute('UPDATE splat_types SET size=?, lifespan=?, homing_delay=?, resource=?, damage=?, '
                    'explosion_type_id=? WHERE id=?',
                    (row.get('size'), row.get('lifespan'), row.get('homing_delay'), row.get('resource'),
                     row.get('damage'), eid, sid))
    conn.commit()

    spice_names = order.get('SpiceMoundTypes', [])
    for idx, spname in enumerate(spice_names):
        cur.execute('INSERT INTO spice_mound_types (id, name) VALUES (?,?)', (idx, spname))
        reg.register('spice_mound_types', spname, idx)
    for spname in spice_names:
        occs = get_data_section(data_secs, data_secs_lower, spname)
        if not occs:
            continue
        start, body = occs[0]
        used = set()
        row = {}
        explosion_names = parse_explosion_types_multi(body, used, reg)
        if explosion_names:
            row['explosion_type_id'] = ('__RESOLVE__', 'explosion_types', explosion_names[0])
        apply_fields(body, used, SPICE_MOUND_SCALAR, {}, reg, 'spice_mound_type', row, overflow)
        spid = reg.resolve('spice_mound_types', spname)
        eid = resolve_or_defer('spice_mound_types', spid, 'explosion_type_id', None, row.get('explosion_type_id'))
        cur.execute('UPDATE spice_mound_types SET health=?, size=?, cost=?, blast_radius=?, spice_capacity=?, '
                    'explosion_type_id=?, resource=?, build_time=?, min_range=?, max_range=? WHERE id=?',
                    (row.get('health'), row.get('size'), row.get('cost'), row.get('blast_radius'),
                     row.get('spice_capacity'), eid, row.get('resource'), row.get('build_time'),
                     row.get('min_range'), row.get('max_range'), spid))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.9 General (singleton)
    # -------------------------------------------------------------------

    gen_occs = get_data_section(data_secs, data_secs_lower, 'General')
    if gen_occs:
        start, body = gen_occs[0]
        used = set()
        row = {}
        apply_fields(body, used, GENERAL_SCALAR, {}, reg, 'general', row, overflow)
        columns = list(GENERAL_SCALAR[k][0] for k in GENERAL_SCALAR)
        columns = sorted(set(columns))
        placeholders = ', '.join(f'{c}=?' for c in columns)
        cur.execute(f'INSERT INTO general_settings (id) VALUES (1)')
        cur.execute(f'UPDATE general_settings SET {placeholders} WHERE id=1',
                    tuple(row.get(c) for c in columns))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.10 Deferred FKs (buildings.get_unit_when_built_id and similar forward refs)
    # -------------------------------------------------------------------

    for table, id_, column, target_table, name in deferred_fk:
        resolved = reg.resolve(target_table, name)
        if resolved is not None:
            cur.execute(f'UPDATE {table} SET {column}=? WHERE id=?', (resolved, id_))
        else:
            overflow.append((table, f'{column}(unresolved)', name, None))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.11 ArtIni.txt (optional): visual resources and global UI settings
    # -------------------------------------------------------------------

    if art_ini_path:
        art_report = import_art_ini(cur, reg, art_ini_path)
        for entity_type, entity_id, key, value, source_line in art_report['overflow']:
            overflow.append((entity_type, key, value, source_line))
    conn.commit()

    # -------------------------------------------------------------------
    # 8.12 entity_resource_links / entity_explosion_effects / custom_fields
    # -------------------------------------------------------------------

    entity_table_for_type = {
        'unit': 'units', 'building': 'buildings', 'bullet': 'bullets',
        'splat_type': 'splat_types', 'spice_mound_type': 'spice_mound_types',
        'crate_type': 'crate_types', 'turret': 'turrets', 'debris_type': 'debris_types',
        'warhead': 'warheads', 'house': 'houses', 'general': 'general_settings',
        'explosion_config': 'explosion_types',
    }

    for entity_type, entity_name, seq, target_name, source_line in resource_links:
        table = entity_table_for_type[entity_type]
        eid = reg.resolve(table, entity_name)
        cur.execute('INSERT OR IGNORE INTO entity_resource_links '
                    '(entity_type, entity_id, seq, target_name, source_line) VALUES (?,?,?,?,?)',
                    (entity_type, eid, seq, target_name, source_line))

    for entity_type, entity_name, seq, explosion_name in explosion_links:
        table = entity_table_for_type[entity_type]
        eid = reg.resolve(table, entity_name)
        exp_id = reg.resolve('explosion_types', explosion_name)
        if eid is not None and exp_id is not None:
            cur.execute('INSERT OR IGNORE INTO entity_explosion_effects '
                        '(entity_type, entity_id, seq, explosion_type_id) VALUES (?,?,?,?)',
                        (entity_type, eid, seq, exp_id))

    for entity_type, key, value, source_line in overflow:
        # overflow collected before the row was inserted (entity_name is not
        # known by id) — attached with entity_id=NULL replaced by -1 so that no
        # data is lost (for the warhead/explosion_config pair entity_id does not
        # always resolve by name directly at this point).
        cur.execute('INSERT INTO custom_fields (entity_type, entity_id, key, value, source_line) '
                    'VALUES (?, -1, ?, ?, ?)', (entity_type, key, value, source_line))

    conn.commit()

    # -------------------------------------------------------------------
    # 8.12 Final integrity check
    # -------------------------------------------------------------------

    conn.execute('PRAGMA foreign_keys = ON')
    fk_issues = conn.execute('PRAGMA foreign_key_check').fetchall()

    print(f'Sections total: {len(sections)}')
    print(f'  category lists: {len(list_secs)}')
    print(f'  data sections: {len(data_secs)}')
    print(f'Imported: units={len(unit_names)}, buildings={len(building_names)}, '
          f'turrets={len(turret_names)}, bullets={len(bullet_names)}, '
          f'warheads={len(order.get("WarheadTypes", []))}, crates={len(crate_names)}, '
          f'splats={len(splat_names)}, spice_mounds={len(spice_names)}')
    print(f'custom_fields (overflow): {len(overflow)}')
    print(f'entity_resource_links: {len(resource_links)}')
    print(f'entity_explosion_effects: {len(explosion_links)}')
    if art_report:
        print(f'art_configs: {art_report["sections"]}')
        print(f'art_configs unmatched: {len(art_report["unmatched"])}')
        if art_report['unmatched']:
            preview = ', '.join(f'{name}@{line}' for line, name in art_report['unmatched'][:10])
            suffix = '...' if len(art_report['unmatched']) > 10 else ''
            print(f'  unmatched preview: {preview}{suffix}')
    print(f'Unresolved forward references sent to custom_fields: '
          f'{sum(1 for e,k,v,l in overflow if k.endswith("(unresolved)"))}')
    print(f'FK issues: {fk_issues if fk_issues else "none"}')

    conn.close()


if __name__ == '__main__':
    if len(sys.argv) not in (4, 5):
        print('Usage: python3 parse_rules.py Rules.txt schema.sql rules.db [ArtIni.txt]')
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else None)
