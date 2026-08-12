#!/usr/bin/env python3
"""Generate transitional Godot UnitDefinition resources and their path manifest.

The normalized local rules.db remains the input during migration. Generated
.tres files are deliberately ordinary Godot resources: once Rules is retired,
the generator can be removed and those resources become authored game data.
"""

from __future__ import annotations

import argparse
import math
import re
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "assets/converted/rules.db"
DEFINITION_DIR = ROOT / "resources/units/definitions"
MANIFEST_PATH = ROOT / "resources/units/generated_unit_manifest.gd"
SCENE_DIR = ROOT / "scenes/units"
MODEL_DIR = ROOT / "assets/converted/models"
VETERANCY_DIR = ROOT / "resources/units/veterancy"
VOICE_PROFILE_DIR = ROOT / "resources/audio/voices"
VOICE_HOUSE_PREFIXES = {
    "Atreides": "AT",
    "Ordos": "OR",
    "Harkonnen": "HK",
    "Ix": "IX",
    "Imperial": "IM",
    "Fremen": "FR",
    "Guild": "GU",
    "Tleilaxu": "TL",
    "Incidental": "IN",
}
COMBAT_DIR = ROOT / "resources/combat"
TURRET_DIR = COMBAT_DIR / "turrets"
BULLET_DIR = COMBAT_DIR / "bullets"
WARHEAD_DIR = COMBAT_DIR / "warheads"
COMBAT_MANIFEST_PATH = COMBAT_DIR / "generated_combat_manifest.gd"
COMBAT_SETTINGS_PATH = COMBAT_DIR / "combat_settings.tres"
BUILDING_DEFINITION_DIR = ROOT / "resources/buildings/definitions"
BUILDING_MANIFEST_PATH = ROOT / "resources/buildings/generated_building_manifest.gd"
BUILDING_SCENE_DIR = ROOT / "scenes/buildings"
CONVERTED_BUILDING_DIR = ROOT / "assets/converted/buildings"
GAME_SETTINGS_PATH = ROOT / "resources/rules/game_settings.tres"
SPICE_DEFINITION_PATH = ROOT / "resources/world/spice_mound.tres"
SFX_SOURCE_DIR = ROOT / "assets/raw_original_content/SFX"
SFX_WAV_DIR = ROOT / "assets/converted/audio/sfx"
SFX_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:;.*)?$")
SFX_PROPERTY_RE = re.compile(r"^\s*([^=;]+?)\s*=\s*(.*?)\s*$")
CONFIG_RE = re.compile(r'^config_id = &"([^"]+)"$', re.MULTILINE)
MODEL_RE = re.compile(r'path="(res://assets/converted/models/[^"]+\.(?:scn|tscn))"')
BURST_CONFIGS = {
    # Model animation tracks do not encode these launcher events. Values are
    # authored in 20 Hz rule ticks.
    "HKMissileTankBarrage": (6, 6.0),
    "ORAPCBase": (2, 5.0),
    "HKDevastatorGun": (2, 0.0),
    "HKDevastatorMissile": (3, 7.5),
}
# Rules.txt gives a bullet only MaxRange, which the original engine uses both as
# the turret's firing range and as the projectile's flight budget. That works
# for straight shots but starves homing missiles: steering after a moving (and
# especially a retreating) target makes the flown path longer than the straight
# line that was range-checked at launch, so the missile burns out mid-air
# against a target that was comfortably in range. Homing bullets therefore get a
# flight budget larger than their firing range. See docs/quirks.md.
HOMING_FLIGHT_RANGE_SCALE = 1.5
# Per-bullet exceptions to HOMING_FLIGHT_RANGE_SCALE, keyed by bullet name.
FLIGHT_RANGE_SCALE_OVERRIDES: dict[str, float] = {}
# Rules.txt Speed for bullets whose own section leaves it out, keyed by bullet
# name. A section with no Speed and no Trajectory describes neither a flying
# shot nor a conceptual (Speed=-1) instant one, so the projectile has no way to
# leave the muzzle. See docs/quirks.md "Howitzer_B has no Speed".
BULLET_SPEED_OVERRIDES: dict[str, float] = {
    # ORKobraUndeployedGun's fixed forward gun, whose section is marked
    # "//not used" and whose Trajectory line is commented out. Direct-fire
    # tank shell speed, shared by HEAT_B/Rocket_B, which use the same
    # shell.xaf projectile.
    "Howitzer_B": 28.0,
}
# IMADVSardaukar has no deploy ability; its knife is range-selected melee, not a
# deployed-mode weapon. See docs/quirks.md "Advanced Sardaukar knife is flagged
# as a deployed-only weapon".
TURRET_DEPLOY_GATE_OVERRIDES = {
    "IMADVSardaukarKnife": {"disabled_when_undeployed": False},
    "IMADVSardaukarGun": {"disabled_when_deployed": False},
}
# Turret config_id -> original SFX section name, for the turrets whose fire
# sound cannot be found by an exact (case-insensitive) match of the section
# name against their own config_id. Each entry is backed by an explicit
# source-file comment or an unambiguous bullet/sample-name correspondence
# checked by hand; turrets with no such evidence are left with no fire sound
# rather than guessed. See docs/quirks.md.
# Turrets that opt out of TurretDefinition.fire_sound_exclusive — the default
# "one fire-sound voice per weapon, next shot retires the previous one" rule.
# Only for a weapon whose sample is genuinely meant to layer over itself; a
# weapon that simply fires slower than its sample is long needs no entry, since
# there is never a previous sound left to retire. Kept here rather than
# hand-edited into the .tres, which this generator rewrites wholesale.
TURRET_FIRE_SOUND_NON_EXCLUSIVE: set[str] = {
    # Salvo launchers. Their shots are separate rockets/shells leaving separate
    # muzzles, spaced by the authored fire animation or by BURST_CONFIGS rather
    # than by the reload, so the overlap is the intended sound of a salvo, not
    # a burst of one gun. Retiring the previous shot here would clip each rocket
    # to the gap before the next one.
    "ATRocketTurretGun",
    "ATMinotaurusGun",
    "ORAPCBase",
    "HKMissileTankBarrage",
}
# Units whose `config_id` is not the Rules section name the original engine
# synthesised `<RulesSectionName>MoveFxStart` from, because this project split
# one source unit into several. Rules.txt has a single `[MCV]`; the convert
# stage splits it per house (see docs/quirks.md), so `ATMCVMoveFxStart` and its
# siblings do not exist and all three MCVs would fall silent -- their engine
# sound is `[mcvmovefxstart]` (`mcv_a_motor_1`), one section for all of them,
# exactly as the source has it.
#
# The plain Carryall is the mirror-image case: one house-shared unit here, three
# sections in the source. They carry no audible difference to choose between --
# [ATCarryallMoveFxStart], [hkcarryallmovefxstart] and [orcarryallmovefxstart]
# all name the same `adv_carryall_takeoff_1` at Volume=70, Limit=1 (as do the
# three ADVCarryall sections), so the house is picked arbitrarily rather than
# carried around in a by-house dictionary that would resolve to one sample
# anyway. Only Atreides's copy adds `Control = loop decay`; the Ordos one is
# taken because it is the plain variant.
UNIT_MOVE_START_RULES_SECTIONS: dict[str, str] = {
    "ATMCV": "MCV",
    "HKMCV": "MCV",
    "ORMCV": "MCV",
    "Carryall": "ORCarryall",
}
# Fire sounds that no SFX section can express, because the sample is a
# hand-authored asset under assets/reworked/ rather than a converted original.
# Kept here for the same reason as every other table in this file: the .tres is
# rewritten wholesale on every run, so a hand edit to it does not survive.
TURRET_FIRE_SOUND_PATH_OVERRIDES: dict[str, list[str]] = {
    # The original [HKGunTurretGun] samples are a single tank-cannon shot, but
    # the turret fires a burst; hk_assault_tank_1a repeated at burst rate reads
    # as one stuttering shot instead of a burst, so a burst was authored from
    # the same source material. The section's authored Volume still applies.
    "HKGunTurretGun": ["res://assets/reworked/HKGunTurretBurst.wav"],
}
# Turrets that do not exist in the original data: a unit the source points at
# some other unit's shared turret, and which this project has since given its
# own weapon voice. The derived turret copies every field of its `source`
# turret except the fire sound (and the exclusivity rule, which usually differs
# because the source is a salvo launcher and the derived one is not).
# UNIT_TURRET_OVERRIDES then repoints the owning unit onto it.
DERIVED_TURRETS: dict[str, dict] = {
    # The Smuggler Quad shared ORAPCBase, whose APCAttack rocket sound has
    # nothing to do with the Quad's gun. GeneralSFX.txt's
    # [atsmallcannonsingleshot] (KindjalGun1..3, ";dko this looks like the gun
    # attack sound for the IX Projector") is the small-cannon family this
    # weapon belongs to. Unlike ORAPCBase's salvo it is one gun, so it takes
    # the ordinary one-voice rule back.
    "SMQuadGun": {
        "source": "ORAPCBase",
        "fire_sound_section": "atsmallcannonsingleshot",
        "fire_sound_exclusive": True,
        # The section itself authors Volume = 80; 70 is the level the turret
        # was tuned to by ear when it was first hand-written (the same level
        # ORAPCBase plays at). Kept explicit so it is a choice, not a drift.
        "fire_sound_volume": 70,
    },
}
UNIT_TURRET_OVERRIDES: dict[str, list[str]] = {
    "SMQuad": ["SMQuadGun"],
}
TURRET_FIRE_SOUND_SECTION_OVERRIDES: dict[str, str] = {
    # AtreidesSFX.txt: ";dko added 4/24/01 used for both the ATPillbox and AT
    # Trike" over [ATMedMG-Shortburst], and the comment above the neighbouring
    # [MedMG-Shortburst] repeats it ("These samples are also being called by the
    # Atreides Pillbox"). Both sections carry the same `Sounds =
    # sand_trike_gun_1` at Volume=70 as [ATTrikeGun] itself, so the pillbox and
    # the trike share one gun sound. ATPillboxGun has no section of its own.
    "ATPillboxGun": "ATMedMG-Shortburst",
    # ORDOSSFX.TXT: "[KobraAttack] ;dko kobra fires big weapon <good>". Both
    # the deployed (howitzer) and undeployed Kobra joints fire this weapon.
    "ORKobraDeployedGun": "KobraAttack",
    "ORKobraUndeployedGun": "KobraAttack",
    # ORDOSSFX.TXT: "[orlaser1] ;dko <good> This is being called for the
    # laser tank as well as the IM Elite Sardukar 4/12/01". ORLaserTankBase
    # fires directly (bullet Laser_B, no next_joint_id); IMADVSardaukarGun's
    # bullet is InfLaser_B, matching "the IM Elite Sardukar" in the comment.
    "ORLaserTankBase": "orlaser1",
    "IMADVSardaukarGun": "orlaser1",
    # HarkonnenSFX.txt / GeneralSFX.txt / AtreidesSFX.txt all define
    # [saheavymg-longburst1|2] and [MedMG-Longburst] with the identical
    # `Sounds = sardukar_mgun_1 sardukar_mgun_2`, the only "sa"/"Sardukar"
    # prefixed weapon-fire samples in the SFX data. IMSardaukarGun (the
    # regular, non-Elite Sardaukar's HMG_B gun) is the only unresolved
    # Sardaukar-armed turret left, so it is the intended target.
    "IMSardaukarGun": "saheavymg-longburst1",
    # ORDOSSFX.TXT: "[ORApcGun] ;dko added 4/18/01 suggested new hook be
    # made. Sounds = APCAttack". ORAPCBase fires directly (bullet
    # HEATAPC_B, no next_joint_id) so it is this turret's own joint.
    "ORAPCBase": "ORApcGun",
    # HarkonnenSFX.txt: "[hkcannonsingleloudshot] ;dko[HarkAssaultTank] also
    # is used for the HK Gun Turret / dko 5/2/01 let's set this aside for the
    # hk assault tank only". HKAssaultTankBase fires directly (bullet mm80_B,
    # no next_joint_id, no separate "...Gun" turret exists for it).
    "HKAssaultTankBase": "hkcannonsingleloudshot",
    # HarkonnenSFX.txt: "[hkmedmg-shortburst] ;dko[HarkBuzzsawAttack]". Both
    # buzzsaw blades are the same weapon (bullet MMG_B) mirrored left/right.
    "HKBuzzsawLeft": "hkmedmg-shortburst",
    "HKBuzzsawRight": "hkmedmg-shortburst",
    # HarkonnenSFX.txt: "[Catapult] Sounds=hk_inkvine_shot_1b" — the Inkvine
    # launcher's own comment block, right above [InkvineSplat] (its impact
    # sound, see BULLET_HIT_SOUND_SECTION_OVERRIDES).
    "HKInkVineGun": "Catapult",
    # GeneralSFX.txt: "[TLLeechGun] Sounds=leech_suck_1..4" is the vehicle
    # drain/capture sound, not the weapon fire. The actual fire hook is
    # documented two sections earlier: "; SpittingSpore is the projectile
    # fired by TL Leech - sort of organic firing noise", [SpittingSpore]
    # Sounds = tx_leech_attack_6 tx_leech_attack_7. An exact-name match on
    # "TLLeechGun" itself picks up the wrong (drain) sound, so it must be
    # overridden here despite the name looking like a direct hit.
    "TLLeechGun": "SpittingSpore",
    # AtreidesSFX.txt: "[atheavymg-shortburst] ;this is the ADP fire gun
    # sound / Sounds=mongoose_rocket_1" — an explicit source comment
    # confirming the (otherwise odd-looking, rocket-named) sample is in fact
    # the Atreides ADP turret's own weapon fire.
    "ATADPGun": "atheavymg-shortburst",
    # HarkonnenSFX.txt: "[hkheavymg-longburst] Sounds = adp_gun_1 adp_gun_2"
    # is the Harkonnen ADP turret's fire hook, distinct from [HKGunshipGun]'s
    # own "Sounds=hk_adp_gun_1" (a different, gunship-specific sample despite
    # the similar name) — they must not be conflated.
    "HKADPGun": "hkheavymg-longburst",
    # No SFX section documents a dedicated Flame Tank weapon-fire sound (only
    # its move-loop, [hkflamemovefxstart]). The two other Harkonnen flame
    # weapons split into "large" (Flame Tower, [HKFlameTowerBase]) and
    # "medium" (infantry, [HKFlamerGun]) categories; the Flame Tank's turret
    # (FlameTank_B) is the vehicle-mounted large-format flamer, so it reuses
    # the Flame Tower's large-flame sample rather than staying silent.
    "HKFlameTankLeft": "HKFlameTowerBase",
    "HKFlameTankRight": "HKFlameTowerBase",
    # AtreidesSFX.txt: the exact-name match, "[ATOrnithopterGun] Sounds =
    # ORNITHOPTER_ROCKET_1", is not actually the launch sound — that's
    # "[atrocketlaunch] ;dko ornithopter rocket launch / Sounds=
    # ornithopter_rocket_2", a separate, explicitly-commented section a few
    # lines below. User-confirmed in-game.
    "ATOrnithopterGun": "atrocketlaunch",
    # User-confirmed in-game: these three rocket-armed turrets should share
    # the ornithopter rocket launch sample rather than their previous
    # (per-source-data) sounds.
    "HKGunshipGun": "atrocketlaunch",
    "HKDevastatorMissile": "atrocketlaunch",
    "HKMissileTankBarrage": "atrocketlaunch",
}
# Bullet config_id -> original SFX section name, for the rare non-explosive
# bullets that carry a distinct impact/splat sound in the source SFX files.
# Most bullets have no entry here: an exploding warhead's impact is already
# covered by the explosion/death sound systems, and the original data has no
# generic "bullet hit" concept to fall back on. See docs/quirks.md.
BULLET_HIT_SOUND_SECTION_OVERRIDES: dict[str, str] = {
    # HarkonnenSFX.txt: "[InkvineSplat] ;InkvineSplat - as HK Inkvine
    # projectile splats onto ground. Sounds=hk_inkvine_hit_1".
    "InkVine_B": "InkvineSplat",
}
# GeneralSFX.txt: "[ShellDetonation] ; ShellDet1-3 samples called when a shell
# impacts off the ground (from an Atreides Minotaurus) - as shell hits ground
# (not a full on explosion). Sounds=shell_dud_1" and the separate
# "[RocketDetonation] ; as rocket explodes on ground (not a full on
# explosion), being called by rocket impacts from the AT Rocket Turret and
# the Harkonnen Gunship. Sounds=shell_dud_1" — both resolve to the same
# sample. User-confirmed in-game rule, generalized from a hand-picked bullet
# list to a data-driven one after the hand-picked version wrongly included
# machine-gun caliber bullets: a bullet gets this sound exactly when its own
# resolved impact effect is a real explosion visual, not just a hit flash.
# `assets/converted/impact_effects/{shellhit,missilehit}/*.scn` both contain
# a "_bigbing_"-named mesh (an actual explosion burst with "_bing1..4" debris
# pieces); `mghit.scn`/`sniperhit.scn` do not — mghit's own node is named
# "_flashtest_0", and sniperhit's original XBF node is literally named
# "_MGHit_0" (it reuses the machine-gun hit visual verbatim), i.e. neither MG
# nor sniper fire ever produces a real explosion at impact, only a flash.
# EXPLOSIVE_IMPACT_EFFECT_IDS records that finding as data instead of
# re-deriving it from scene contents at generate time. See docs/quirks.md.
# DevImpact is here on the same "is it a real explosion" test rather than by
# scene shape: it is a marker-only FX rig with no burst mesh to inspect, but
# the bullet carrying it (DevPlasma_B, the Devastator's plasma cannon) is 813
# damage with BlastRadius=32 and BlowUp=TRUE. It used to inherit the sound via
# a stale duplicate ExplosionType=ShellHit line that the parser mistook for a
# second effect; dropping that artifact must not silently mute the impact.
EXPLOSIVE_IMPACT_EFFECT_IDS = frozenset({"ShellHit", "MissileHit", "DevImpact"})
BUILDING_ID_PREFIXES = sorted([
    "GPSFX", "AKIN", "ATIN", "CNIN", "GPIN", "HKIN", "HLIN", "INFR",
    "INGU", "INIM", "INIX", "INTL", "ORIN", "TLIN",
    "AT", "FR", "GU", "HK", "IM", "IN", "IX", "OR", "SM", "TL",
], key=len, reverse=True)
# These two compatibility values were authored when rally-point command
# eligibility moved from AiExit to AiManufacturing. They are not present in
# the normalized source column, so keep them explicit until that data is
# reconciled with Rules.txt.
BUILDING_AI_MANUFACTURING_OVERRIDES = {"HKSmWindtrap", "ORSmWindtrap"}


def godot_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def string_name(value: str | None) -> str:
    return "&" + godot_string(value or "")


def bool_text(value: object) -> str:
    return "true" if bool(value) else "false"


def array_text(values: list[str]) -> str:
    return "[" + ", ".join(string_name(value) for value in values) + "]"


def string_array_text(values: list[str]) -> str:
    return "[" + ", ".join(godot_string(value) for value in values) + "]"


def dictionary_text(values: dict[str, object]) -> str:
    entries = []
    for key in sorted(values):
        value = values[key]
        rendered = bool_text(value) if isinstance(value, bool) else f"{float(value):.6g}"
        entries.append(f"{godot_string(key)}: {rendered}")
    return "{" + ", ".join(entries) + "}"


def string_dictionary_text(values: dict[str, str]) -> str:
    return "{" + ", ".join(
        f"{string_name(key)}: {godot_string(values[key])}" for key in sorted(values)
    ) + "}"


def voice_profile_path(profile_id: str) -> str:
    path = VOICE_PROFILE_DIR / f"{profile_id}.tres"
    return "res://" + path.relative_to(ROOT).as_posix() if path.exists() else ""


def voice_house_paths(config_id: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for house_id, prefix in VOICE_HOUSE_PREFIXES.items():
        path = voice_profile_path(prefix + config_id)
        if path:
            result[house_id] = path
    return result


def resource_text(script_class: str, script_path: str, properties: list[str]) -> str:
    return "\n".join([
        f'[gd_resource type="Resource" script_class="{script_class}" load_steps=2 format=3]',
        "",
        f'[ext_resource type="Script" path="{script_path}" id="1_definition"]',
        "",
        "[resource]",
        'script = ExtResource("1_definition")',
        *properties,
        "",
    ])


def snake_case(value: str) -> str:
    return re.sub(
        r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])",
        "_",
        value,
    ).lower()


def building_scene_stem(config_id: str) -> str:
    folded = config_id.casefold()
    for prefix in BUILDING_ID_PREFIXES:
        if folded.startswith(prefix.casefold()) and len(config_id) > len(prefix):
            suffix = snake_case(config_id[len(prefix):]).lstrip("_")
            return f"{prefix.lower()}_{suffix}"
    return snake_case(config_id)


def building_scene_text(config_id: str, converted_scene_path: str) -> str:
    return "\n".join([
        "[gd_scene load_steps=2 format=3]",
        "",
        f'[ext_resource type="PackedScene" path="{converted_scene_path}" id="1_building"]',
        "",
        f'[node name="{config_id}" instance=ExtResource("1_building")]',
        f"config_id = {string_name(config_id)}",
        "",
    ])


def parse_sfx_sections() -> dict[str, tuple[list[str], int]]:
    """Parse every `[Section]` / `Sounds = ...` / `Volume = ...` block in the
    original SFX definition files into section name (casefold) -> (ordered
    list of raw sample names, authored Volume, 0-100, default 100 when
    absent). Mirrors the section format parsed by
    generate_voice_feedback.py's parse_sources(), trimmed down to just what
    fire/hit sound resolution needs: the sample list, with `$`-prefixed
    (localized, never converted to a real wav) samples dropped.

    A later file redefining a section with only such `$`-prefixed samples
    does not clobber an earlier definition that had real ones — e.g.
    HarkonnenSFX.txt's real "[InkvineSplat] Sounds=hk_inkvine_hit_1" must
    survive ImportedSfx.txt's later, alphabetically-last-wins
    "[INKVINESPLAT] Sounds = $InkvineSplat" stub. This mirrors
    SHADOW_PROOF_EVENT_IDS in generate_voice_feedback.py, but applied
    generically instead of via a hand-picked id whitelist, since this parser
    has no fixed set of ids to special-case. See docs/quirks.md.
    """
    sections: dict[str, tuple[list[str], int]] = {}
    for path in sorted(SFX_SOURCE_DIR.iterdir(), key=lambda item: item.name.casefold()):
        if path.suffix.casefold() != ".txt" or path.name.casefold() == "sfx.txt":
            continue
        current: str | None = None
        pending_samples: dict[str, list[str]] = {}
        pending_volume: dict[str, int] = {}
        for raw_line in path.read_text(encoding="cp1252").splitlines():
            if raw_line.lstrip().startswith(";"):
                continue
            section = SFX_SECTION_RE.match(raw_line)
            if section:
                name = section.group(1).strip()
                current = name if name.casefold() != "localdefaults" else None
                if current is not None:
                    pending_samples.setdefault(current, [])
                    pending_volume.setdefault(current, 100)
                continue
            prop = SFX_PROPERTY_RE.match(raw_line)
            if prop is None or current is None:
                continue
            key = prop.group(1).strip().casefold()
            value = prop.group(2)
            semicolon = value.find(";")
            if semicolon != -1:
                value = value[:semicolon]
            if key == "sounds":
                for token in re.findall(r'"[^"]*"|\S+', value):
                    sample = token.strip('"')
                    if sample and not sample.startswith("$"):
                        pending_samples[current].append(sample)
            elif key == "volume":
                try:
                    pending_volume[current] = int(float(value.strip()))
                except ValueError:
                    pass
        for name, samples in pending_samples.items():
            key = name.casefold()
            if key in sections and sections[key][0] and not samples:
                continue
            sections[key] = (samples, pending_volume.get(name, 100))
    return sections


def sfx_wav_lookup() -> dict[str, Path]:
    return {path.stem.casefold(): path for path in SFX_WAV_DIR.glob("*.wav")}


def resolve_sfx_paths(samples: list[str], wavs: dict[str, Path]) -> list[str]:
    paths: list[str] = []
    for sample in samples:
        wav = wavs.get(sample.casefold())
        if wav is None:
            continue
        path = "res://" + wav.relative_to(ROOT).as_posix()
        if path not in paths:
            paths.append(path)
    return paths


def fire_sound_paths_for(
    config_id: str, sfx_sections: dict[str, tuple[list[str], int]], wavs: dict[str, Path],
    section_override: str = "",
) -> tuple[list[str], int]:
    section_name = section_override or TURRET_FIRE_SOUND_SECTION_OVERRIDES.get(
        config_id, config_id
    )
    samples, volume = sfx_sections.get(section_name.casefold(), ([], 100))
    paths = TURRET_FIRE_SOUND_PATH_OVERRIDES.get(config_id)
    if paths is None:
        paths = resolve_sfx_paths(samples, wavs)
    return paths, volume


def move_start_sound_id_for(
    config_id: str, sfx_sections: dict[str, tuple[list[str], int]], wavs: dict[str, Path]
) -> str:
    """The section the original engine synthesised from the unit's own Rules
    section name plus "MoveFxStart" -- there is no MoveSound/EngineSound key in
    Rules.txt to read, the name is the mapping. Resolved here, at convert time,
    so "which units have one" is a checked artifact: 19 of 102 units do.

    Returns the casefolded section name (the key SfxSectionCatalog looks up), or
    "" when no such section exists or all of its samples are localized stubs
    that never made it into the WAV archive.
    """
    source_name = UNIT_MOVE_START_RULES_SECTIONS.get(config_id, config_id)
    section_name = f"{source_name}MoveFxStart"
    samples, _volume = sfx_sections.get(section_name.casefold(), ([], 100))
    return section_name.casefold() if resolve_sfx_paths(samples, wavs) else ""


def fire_sound_exclusive_for(config_id: str) -> bool:
    return config_id not in TURRET_FIRE_SOUND_NON_EXCLUSIVE


def hit_sound_paths_for(
    config_id: str, effects: list[str], is_laser: bool, continuous: bool,
    sfx_sections: dict[str, tuple[list[str], int]], wavs: dict[str, Path]
) -> tuple[list[str], int]:
    section_name = BULLET_HIT_SOUND_SECTION_OVERRIDES.get(config_id)
    if section_name is None and not is_laser and not continuous and any(
        effect in EXPLOSIVE_IMPACT_EFFECT_IDS for effect in effects
    ):
        section_name = "ShellDetonation"
    if section_name is None:
        return [], 100
    samples, volume = sfx_sections.get(section_name.casefold(), ([], 100))
    return resolve_sfx_paths(samples, wavs), volume


def discover_scenes() -> tuple[dict[str, str], dict[str, str]]:
    scenes: dict[str, str] = {}
    models: dict[str, str] = {}
    for path in sorted(SCENE_DIR.glob("*.tscn")):
        text = path.read_text(encoding="utf-8")
        config = CONFIG_RE.search(text)
        if config is None:
            continue
        config_id = config.group(1)
        relative = path.relative_to(ROOT).as_posix()
        # unit.tscn is the prepared ATInfantry scene as well as the fallback.
        scenes[config_id] = f"res://{relative}"
        model = MODEL_RE.search(text)
        if model is not None:
            models[config_id] = model.group(1)
    return scenes, models


def model_paths_by_xaf() -> dict[str, str]:
    result: dict[str, str] = {}
    for directory in sorted(path for path in MODEL_DIR.iterdir() if path.is_dir()):
        scene = directory / f"{directory.name}.scn"
        if scene.exists():
            result[directory.name.casefold()] = "res://" + scene.relative_to(ROOT).as_posix()
    return result


def rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    connection.row_factory = sqlite3.Row
    return connection.execute(
        """
        SELECT u.*, h.name AS house_name, ug.name AS unit_group_name,
               armour.name AS armour_name, art.xaf AS xaf, art.icon AS icon,
               art.icon_grey AS icon_grey, art.sidebar_type AS sidebar_type,
               chaos.name AS chaos_effect_name, hawk.name AS hawk_effect_name,
               damage_fx.name AS damage_effect_name, explosion.name AS explosion_type_name
          FROM units AS u
          LEFT JOIN houses AS h ON h.id = u.house_id
          LEFT JOIN unit_groups AS ug ON ug.id = u.unit_group_id
          LEFT JOIN armour_types AS armour ON armour.id = u.armour_type_id
          LEFT JOIN art_configs AS art
            ON art.entity_type = 'unit' AND art.entity_id = u.id
          LEFT JOIN explosion_types AS chaos ON chaos.id = u.chaos_effect_id
          LEFT JOIN explosion_types AS hawk ON hawk.id = u.hawk_effect_id
          LEFT JOIN explosion_types AS damage_fx ON damage_fx.id = u.damage_effect_id
          LEFT JOIN explosion_types AS explosion ON explosion.id = u.explosion_type_id
         ORDER BY u.id
        """
    ).fetchall()


def linked_names(connection: sqlite3.Connection, table: str, unit_id: int) -> list[str]:
    return [
        row[0]
        for row in connection.execute(
            f"SELECT b.name FROM {table} AS link JOIN buildings AS b ON b.id = link.building_id WHERE link.unit_id = ? ORDER BY link.rowid",
            (unit_id,),
        )
    ]


def turret_names(connection: sqlite3.Connection, unit_id: int, config_id: str = "") -> list[str]:
    if config_id in UNIT_TURRET_OVERRIDES:
        return list(UNIT_TURRET_OVERRIDES[config_id])
    return [
        row[0]
        for row in connection.execute(
            "SELECT t.name FROM unit_turrets AS link JOIN turrets AS t ON t.id = link.turret_id WHERE link.unit_id = ? ORDER BY link.seq",
            (unit_id,),
        )
    ]


def unit_list(connection: sqlite3.Connection, query: str, unit_id: int) -> list[str]:
    return [row[0] for row in connection.execute(query, (unit_id,))]


def visual_path(xaf: str | None, output_root: str) -> str:
    if not xaf:
        return ""
    name = Path(str(xaf).replace("\\", "/")).stem.lower()
    relative = ROOT / output_root / name / f"{name}.scn"
    return "res://" + relative.relative_to(ROOT).as_posix() if relative.exists() else ""


def definition_text(row: sqlite3.Row, scene_path: str, model_path: str,
                    direct_voice_profile_path: str, house_voice_profile_paths: dict[str, str],
                    move_start_sound_id: str,
                    primary: list[str], secondary: list[str], turrets: list[str],
                    terrain: list[str], resources: list[str], effects: list[str],
                    veterancy_paths: list[str], explosion_paths: dict[str, str]) -> str:
    properties = [
        f"config_id = {string_name(row['name'])}",
        f"legacy_name = {string_name(row['legacy_name'])}",
        f"house_id = {string_name(row['house_name'])}",
        f"unit_group_id = {string_name(row['unit_group_name'])}",
        f"scene_path = {godot_string(scene_path)}",
        f"model_scene_path = {godot_string(model_path)}",
        f"icon_path = {godot_string(str(row['icon'] or ''))}",
        f"icon_grey_path = {godot_string(str(row['icon_grey'] or ''))}",
        f"sidebar_type = {string_name(row['sidebar_type'])}",
        f"voice_profile_path = {godot_string(direct_voice_profile_path)}",
        f"voice_profile_paths_by_house = {string_dictionary_text(house_voice_profile_paths)}",
        f"move_start_sound_id = {string_name(move_start_sound_id)}",
        f"cost = {int(row['cost'] or 0)}",
        f"build_time_ticks = {int(row['build_time'] or 0)}",
        f"tech_level = {int(row['tech_level'] or 0)}",
        f"upgraded_primary_required = {bool_text(row['upgraded_primary_required'])}",
        f"primary_building_ids = {array_text(primary)}",
        f"secondary_building_ids = {array_text(secondary)}",
        f"size = {int(row['size'] or 0)}",
        f"health = {int(row['health'] or 0)}",
        f"shield_health = {float(row['shield_health'] or 0.0):.6g}",
        f"armour_type = {string_name(row['armour_name'])}",
        f"speed = {float(row['speed'] or 0.0):.6g}",
        f"mech_speed = {float(row['mech_speed'] or 0.0):.6g}",
        f"mech = {bool_text(row['mech'])}",
        f"turn_rate = {float(row['turn_rate'] or 0.0):.6g}",
        f"infantry = {bool_text(row['infantry'])}",
        f"can_fly = {bool_text(row['can_fly'])}",
        f"circles = {bool_text(row['circles'])}",
        f"ornithoptor = {bool_text(row['ornithoptor'])}",
        f"carryall = {bool_text(row['carryall'])}",
        f"advanced_carryall = {bool_text(row['advanced_carryall'])}",
        f"can_move_any_direction = {bool_text(row['can_move_any_direction'])}",
        f"terrain_ids = {array_text(terrain)}",
        f"can_be_deviated = {bool_text(row['can_be_deviated'])}",
        f"can_self_repair = {bool_text(row['can_self_repair'])}",
        f"can_be_repaired = {bool_text(row['can_be_repaired'])}",
        f"crushable = {bool_text(row['crushable'])}",
        f"crushes = {bool_text(row['crushes'])}",
        f"starportable = {bool_text(row['starportable'])}",
        f"tasty_to_worms = {bool_text(row['tasty_to_worms'])}",
        f"worm_attraction = {int(row['worm_attraction'] or 0)}",
        f"can_be_suppressed = {bool_text(row['can_be_suppressed'])}",
        f"can_die = {bool_text(row['can_die'])}",
        f"cant_be_leeched = {bool_text(row['cant_be_leeched'])}",
        f"selectable = {bool_text(row['selectable'])}",
        f"stealthed_when_still = {bool_text(row['stealthed_when_still'])}",
        f"height_offset = {float(row['height_offset'] or 0.0):.6g}",
        f"roof_height = {int(row['roof_height'] or 0)}",
        # These two Harvester fields are present in the local Rules.txt but the
        # normalized schema currently has no unit columns for them. Keep the
        # explicit, source-checked compatibility values until schema migration.
        f"spice_capacity = {700 if row['name'] == 'Harvester' else 0}",
        f"unload_rate = {2 if row['name'] == 'Harvester' else 0}",
        f"resource_ids = {array_text(resources)}",
        f"explosion_effect_ids = {array_text(effects)}",
        f"chaos_effect_id = {string_name(row['chaos_effect_name'])}",
        f"hawk_effect_id = {string_name(row['hawk_effect_name'])}",
        f"damage_effect_id = {string_name(row['damage_effect_name'])}",
        f"explosion_type_id = {string_name(row['explosion_type_name'])}",
        "explosion_scene_paths = " + "{" + ", ".join(
            f"{string_name(key)}: {godot_string(explosion_paths[key])}" for key in sorted(explosion_paths)
        ) + "}",
        f"veterancy_level_paths = {string_array_text(veterancy_paths)}",
        f"turret_ids = {array_text(turrets)}",
    ]
    return resource_text("UnitDefinition", "res://scripts/units/unit_definition.gd", properties)


def veterancy_text(row: sqlite3.Row) -> str:
    properties = [
        f"level = {int(row['level_order'])}",
        f"score = {int(row['veterancy_score'])}",
        f"extra_damage_percent = {float(row['extra_damage_percent'] or 0.0):.6g}",
        f"extra_armour_percent = {float(row['extra_armour_percent'] or 0.0):.6g}",
        f"extra_range_percent = {float(row['extra_range_percent'] or 0.0):.6g}",
        f"can_self_repair = {bool_text(row['can_self_repair'])}",
        f"elite = {bool_text(row['elite'])}",
        f"stealthed_when_still = {bool_text(row['stealthed_when_still'])}",
    ]
    if row["speed_override"] is not None:
        properties.append(f"speed_override = {float(row['speed_override']):.6g}")
    if row["health_override"] is not None:
        properties.append(f"health_override = {int(row['health_override'])}")
    return resource_text(
        "UnitVeterancyDefinition",
        "res://scripts/units/unit_veterancy_definition.gd",
        properties,
    )


def art_xaf(connection: sqlite3.Connection, art_name: str | None) -> str:
    if not art_name:
        return ""
    row = connection.execute(
        "SELECT xaf FROM art_configs WHERE lower(art_name)=lower(?) ORDER BY id LIMIT 1",
        (art_name,),
    ).fetchone()
    return str(row[0] or "") if row else ""


## `config_id` differs from `row["name"]` only for a DERIVED_TURRETS entry: the
## resource takes the derived name, while every table keyed by turret name
## (burst, deploy gates, exclusivity) still answers for the source turret the
## row came from, which is what the derived one is a copy of.
def turret_text(
    row: sqlite3.Row, muzzle_scene_path: str, fire_sound_paths: list[str], fire_sound_volume: int,
    config_id: str = "", fire_sound_exclusive: bool | None = None
) -> str:
    if fire_sound_exclusive is None:
        fire_sound_exclusive = fire_sound_exclusive_for(str(row["name"]))
    properties = [
        f"config_id = {string_name(config_id or str(row['name']))}",
        f"bullet_id = {string_name(row['bullet_name'])}",
        f"next_joint_id = {string_name(row['next_joint_name'])}",
        f"reload_count = {float(row['reload_count'] or 0.0):.6g}",
        f"muzzle_flash_id = {string_name(row['turret_muzzle_flash'])}",
        f"muzzle_flash_scene_path = {godot_string(muzzle_scene_path)}",
        f"fire_sound_paths = {string_array_text(fire_sound_paths)}",
        *(
            [f"fire_sound_volume = {float(fire_sound_volume):.6g}"]
            if fire_sound_paths and fire_sound_volume != 100 else []
        ),
        # Omitted when true: that is TurretDefinition's own default.
        *([] if fire_sound_exclusive else ["fire_sound_exclusive = false"]),
        # Legacy turret angles are degrees while Unit TurnRate and Godot are
        # radians. The generated resources are the clean boundary: every
        # angular value below is normalized to radians.
        f"yaw_speed = {math.radians(float(row['turret_y_rotation_angle'] or 0.0)):.9g}",
        f"pitch_speed = {math.radians(float(row['turret_x_rotation_angle'] or 0.0)):.9g}",
        f"acceptable_yaw = {math.radians(float(row['turret_y_acceptable_aim'] or 1.0)):.9g}",
        f"acceptable_pitch = {math.radians(float(row['turret_x_acceptable_aim'] or 1.0)):.9g}",
        f"bullet_count = {int(row['turret_bullet_count'] or 1)}",
    ]
    gate_overrides = TURRET_DEPLOY_GATE_OVERRIDES.get(str(row["name"]), {})
    disabled_when_deployed = gate_overrides.get(
        "disabled_when_deployed", bool(row["turret_disable_if_unit_deployed"])
    )
    disabled_when_undeployed = gate_overrides.get(
        "disabled_when_undeployed", bool(row["turret_disable_if_unit_undeployed"])
    )
    properties.extend([
        f"disabled_when_deployed = {bool_text(disabled_when_deployed)}",
        f"disabled_when_undeployed = {bool_text(disabled_when_undeployed)}",
    ])
    burst_config = BURST_CONFIGS.get(str(row["name"]))
    if burst_config is not None:
        properties.extend([
            f"burst_shot_count = {burst_config[0]}",
            f"burst_interval_ticks = {burst_config[1]:.6g}",
        ])
    for prop, column in [
        ("minimum_yaw", "turret_min_y_rotation"),
        ("maximum_yaw", "turret_max_y_rotation"),
        ("minimum_pitch", "turret_min_x_rotation"),
        ("maximum_pitch", "turret_max_x_rotation"),
    ]:
        if row[column] is not None:
            properties.append(f"{prop} = {math.radians(float(row[column])):.9g}")
    return resource_text("TurretDefinition", "res://scripts/combat/turret_definition.gd", properties)


def flight_range_scale_for(row: sqlite3.Row) -> float:
    name = str(row["name"])
    if name in FLIGHT_RANGE_SCALE_OVERRIDES:
        return FLIGHT_RANGE_SCALE_OVERRIDES[name]
    return HOMING_FLIGHT_RANGE_SCALE if row["homing"] else 1.0


def speed_for(row: sqlite3.Row) -> float:
    return BULLET_SPEED_OVERRIDES.get(str(row["name"]), float(row["speed"] or 0.0))


def bullet_text(row: sqlite3.Row, effects: list[str], projectile_path: str,
                impact_paths: dict[str, str], hit_sound_paths: list[str],
                hit_sound_volume: int) -> str:
    flight_range_scale = flight_range_scale_for(row)
    properties = [
        f"config_id = {string_name(row['name'])}",
        f"warhead_id = {string_name(row['warhead_name'])}",
        f"damage = {float(row['damage'] or 0.0):.6g}",
        f"maximum_range = {float(row['max_range'] or 0.0):.6g}",
        f"minimum_range = {float(row['min_range'] or 0.0):.6g}",
        *(
            [f"flight_range_scale = {flight_range_scale:.6g}"]
            if flight_range_scale != 1.0 else []
        ),
        f"speed = {speed_for(row):.6g}",
        f"blast_radius = {float(row['blast_radius'] or 0.0):.6g}",
        f"friendly_damage_amount = {float(row['friendly_damage_amount'] or 0.0):.6g}",
        f"reduce_damage_with_distance = {bool_text(row['reduce_damage_with_distance'] != 0)}",
        f"anti_aircraft = {bool_text(row['anti_aircraft'])}",
        f"anti_ground = {bool_text(row['anti_ground'] != 0)}",
        f"homing = {bool_text(row['homing'])}",
        f"homing_delay = {float(row['homing_delay'] or 0.0):.6g}",
        f"turn_rate = {float(row['turn_rate'] or 0.0):.6g}",
        f"continuous = {bool_text(row['continuous'])}",
        f"trajectory = {bool_text(row['trajectory'])}",
        f"is_laser = {bool_text(row['is_laser'])}",
        f"missile_trail_present = {bool_text(row['missile_trail'] is not None)}",
        f"missile_trail = {int(row['missile_trail'] or 0)}",
        f"missile_trail_size = {float(row['missile_trail_size'] or 0.0):.6g}",
        f"missile_trail_wiggle_frequency = {float(row['missile_trail_wiggle_freq'] or 0.0):.6g}",
        f"missile_trail_wiggle_scale = {float(row['missile_trail_wiggle_scale'] or 0.0):.6g}",
        f"missile_trail_length = {int(row['missile_trail_length'] or 0)}",
        f"missile_trail_delta = {float(row['missile_trail_delta'] or 0.0):.6g}",
        *[f"{field} = {bool_text(row[field])}" for field in [
            "burnt", "ignites", "gassed", "leech", "infantry", "damage_column",
            "deviate", "beserk", "retreat", "blow_up", "shot",
        ]],
        f"effect_health = {float(row['health'] or 0.0):.6g}",
        f"effect_damage_per_tick = {float(row['shield_health'] or 0.0):.6g}",
        f"linger_duration = {float(row['linger_duration'] or 0.0):.6g}",
        f"linger_damage = {float(row['linger_damage'] or 0.0):.6g}",
        f"explosion_type_id = {string_name(row['explosion_name'])}",
        f"explosion_effect_ids = {array_text(effects)}",
        *(
            [f"damage_to_tile = {float(row['damage_to_tile']):.6g}"]
            if float(row["damage_to_tile"] or 0.0) > 0.0 else []
        ),
        f"projectile_scene_path = {godot_string(projectile_path)}",
        "impact_scene_paths = " + "{" + ", ".join(
            f"{string_name(key)}: {godot_string(impact_paths[key])}" for key in sorted(impact_paths)
        ) + "}",
        f"hit_sound_paths = {string_array_text(hit_sound_paths)}",
        *(
            [f"hit_sound_volume = {float(hit_sound_volume):.6g}"]
            if hit_sound_paths and hit_sound_volume != 100 else []
        ),
    ]
    return resource_text("BulletDefinition", "res://scripts/combat/bullet_definition.gd", properties)


def warhead_text(config_id: str, matrix: dict[str, float]) -> str:
    return resource_text("WarheadDefinition", "res://scripts/combat/warhead_definition.gd", [
        f"config_id = {string_name(config_id)}",
        f"armour_damage = {dictionary_text(matrix)}",
    ])


def combat_manifest_text(turrets: dict[str, str], bullets: dict[str, str],
                         warheads: dict[str, str]) -> str:
    def dictionary(name: str, entries: dict[str, str]) -> list[str]:
        return [f"const {name}: Dictionary = {{"] + [
            f"\t{string_name(key)}: {godot_string(entries[key])}," for key in sorted(entries)
        ] + ["}"]
    return "\n".join([
        "# Generated by tools/generate_unit_definitions.py; do not hand-edit during migration.",
        "extends RefCounted", "",
        *dictionary("TURRET_PATHS", turrets), "",
        *dictionary("BULLET_PATHS", bullets), "",
        *dictionary("WARHEAD_PATHS", warheads), "",
        f"const SETTINGS_PATH := {godot_string('res://' + COMBAT_SETTINGS_PATH.relative_to(ROOT).as_posix())}", "",
    ])


def deploy_points_text(points: list[sqlite3.Row]) -> str:
    return "[" + ", ".join(
        "{" + f'"tile_x": {int(point["tile_x"])}, "tile_y": {int(point["tile_y"])}, '
        + f'"angle": {float(point["angle"] or 0.0):.6g}' + "}"
        for point in points
    ) + "]"


def building_definition_text(row: sqlite3.Row, occupy_rows: list[str], links: list[str],
                             primary: list[str], secondary: list[str], roles: list[str],
                             deploy_points: list[sqlite3.Row], explosion_effects: list[str],
                             explosion_paths: dict[str, str]) -> str:
    return resource_text(
        "BuildingDefinition",
        "res://scripts/buildings/building_definition.gd",
        [
            f"config_id = {string_name(row['name'])}",
            f"legacy_name = {string_name(row['legacy_name'])}",
            f"house_id = {string_name(row['house_name'])}",
            f"building_group_id = {string_name(row['building_group_name'])}",
            f"cost = {int(row['cost'] or 0)}",
            f"build_time_ticks = {float(row['build_time'] or 0.0):.6g}",
            f"health = {float(row['health'] or 0.0):.6g}",
            "shield_health = 0",
            f"armour_type = {string_name(row['armour_name'])}",
            f"tech_level = {int(row['tech_level'] or 0)}",
            f"power_used = {int(row['power_used'] or 0)}",
            f"power_generated = {int(row['power_generated'] or 0)}",
            f"can_be_primary = {bool_text(row['can_be_primary'])}",
            *(["ai_exit = true"] if bool(row["ai_exit"]) else []),
            *(
                ["ai_manufacturing = true"]
                if bool(row["ai_manufacturing"])
                or str(row["name"]) in BUILDING_AI_MANUFACTURING_OVERRIDES
                else []
            ),
            f"is_construction_yard = {bool_text(row['is_con_yard'])}",
            f"upgraded_primary_required = {bool_text(row['upgraded_primary_required'])}",
            f"primary_building_ids = {array_text(primary)}",
            f"secondary_building_ids = {array_text(secondary)}",
            f"roles = {array_text(roles)}",
            f"occupy_rows = {string_array_text(occupy_rows)}",
            f"deploy_points = {deploy_points_text(deploy_points)}",
            f"linked_unit_ids = {array_text(links)}",
            f"survivor_count = {int(row['num_infantry_when_gone'] or 0)}",
            f"turret_id = {string_name(row['turret_name'])}",
            f"upgrade_tech_level = {int(row['upgrade_tech_level'] or 0)}",
            f"upgrade_cost = {int(row['upgrade_cost'] or 0)}",
            f"upgrade_build_time_ticks = {720 if row['building_group_name'] == 'RefineryDock' else 0}",
            f"model_name = {godot_string(str(row['xaf'] or ''))}",
            f"icon_path = {godot_string(str(row['icon'] or ''))}",
            f"icon_grey_path = {godot_string(str(row['icon_grey'] or ''))}",
            f"sidebar_type = {string_name(row['sidebar_type'])}",
            f"explosion_effect_ids = {array_text(explosion_effects)}",
            f"explosion_type_id = {string_name(row['explosion_type_name'])}",
            "explosion_scene_paths = " + "{" + ", ".join(
                f"{string_name(key)}: {godot_string(explosion_paths[key])}" for key in sorted(explosion_paths)
            ) + "}",
        ],
    )


def spice_definition_text(row: sqlite3.Row) -> str:
    return resource_text("SpiceMoundDefinition", "res://scripts/world/map/spice_mound_definition.gd", [
        f"config_id = {string_name(row['name'])}",
        f"health = {int(row['health'] or 0)}",
        f"maturity_minimum_ticks = {float(row['size'] or 0.0):.6g}",
        f"maturity_random_ticks = {float(row['cost'] or 0.0):.6g}",
        f"blast_radius = {float(row['blast_radius'] or 0.0):.6g}",
        f"spice_capacity = {int(row['spice_capacity'] or 0)}",
        f"build_time_ticks = {float(row['build_time'] or 0.0):.6g}",
        f"explosion_type_id = {string_name(row['explosion_name'])}",
        f"resource_id = {string_name(row['resource'])}",
    ])


def manifest_text(definition_paths: dict[str, str], scene_paths: dict[str, str]) -> str:
    def dictionary(name: str, entries: dict[str, str]) -> list[str]:
        lines = [f"const {name}: Dictionary = {{"]
        for key in sorted(entries):
            lines.append(f"\t{string_name(key)}: {godot_string(entries[key])},")
        lines.append("}")
        return lines

    return "\n".join([
        "# Generated by tools/generate_unit_definitions.py; do not hand-edit during migration.",
        "extends RefCounted",
        "",
        *dictionary("DEFINITION_PATHS", definition_paths),
        "",
        *dictionary("SCENE_PATHS", scene_paths),
        "",
    ])


def write_or_check(path: Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        return True
    if check:
        print(f"out of date: {path.relative_to(ROOT)}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    scene_paths, scene_models = discover_scenes()
    xaf_models = model_paths_by_xaf()
    sfx_sections = parse_sfx_sections()
    sfx_wavs = sfx_wav_lookup()
    definition_paths: dict[str, str] = {}
    expected_files: set[Path] = set()
    expected_veterancy: set[Path] = set()
    ok = True
    with sqlite3.connect(args.db) as connection:
        for row in rows(connection):
            config_id = str(row["name"])
            output = DEFINITION_DIR / f"{config_id}.tres"
            expected_files.add(output)
            definition_paths[config_id] = "res://" + output.relative_to(ROOT).as_posix()
            xaf = str(row["xaf"] or "")
            model_path = scene_models.get(config_id, xaf_models.get(f"{xaf}_h0".casefold(), ""))
            veterancy_paths: list[str] = []
            for level in connection.execute(
                "SELECT * FROM unit_veterancy_levels WHERE unit_id=? ORDER BY level_order",
                (int(row["id"]),),
            ):
                level_path = VETERANCY_DIR / f"{config_id}_{int(level['level_order'])}.tres"
                expected_veterancy.add(level_path)
                veterancy_paths.append("res://" + level_path.relative_to(ROOT).as_posix())
                ok = write_or_check(level_path, veterancy_text(level), args.check) and ok
            explosion_effects = unit_list(connection, "SELECT e.name FROM entity_explosion_effects link JOIN explosion_types e ON e.id=link.explosion_type_id WHERE link.entity_type='unit' AND link.entity_id=? ORDER BY link.seq", int(row["id"]))
            # Mirrors CombatBullet.explosion_effect_ids()'s runtime fallback: a
            # unit with no explicit effect list still explodes using its single
            # ExplosionType, so the scene-path dict must cover that id too.
            explosion_lookup_effects = explosion_effects
            if not explosion_lookup_effects and row["explosion_type_name"]:
                explosion_lookup_effects = [str(row["explosion_type_name"])]
            explosion_paths = {
                effect: path for effect in explosion_lookup_effects
                if (path := visual_path(art_xaf(connection, effect), "assets/converted/impact_effects"))
            }
            content = definition_text(
                row,
                scene_paths.get(config_id, ""),
                model_path,
                voice_profile_path(config_id),
                voice_house_paths(config_id),
                move_start_sound_id_for(config_id, sfx_sections, sfx_wavs),
                linked_names(connection, "unit_primary_buildings", int(row["id"])),
                linked_names(connection, "unit_secondary_buildings", int(row["id"])),
                turret_names(connection, int(row["id"]), config_id),
                unit_list(connection, "SELECT t.name FROM unit_terrain link JOIN terrain_types t ON t.id=link.terrain_type_id WHERE link.unit_id=? ORDER BY t.sort_order", int(row["id"])),
                unit_list(connection, "SELECT target_name FROM entity_resource_links WHERE entity_type='unit' AND entity_id=? ORDER BY seq", int(row["id"])),
                explosion_effects,
                veterancy_paths,
                explosion_paths,
            )
            ok = write_or_check(output, content, args.check) and ok

        turret_paths: dict[str, str] = {}
        turret_rows: dict[str, sqlite3.Row] = {}
        for row in connection.execute("""
            SELECT t.*, b.name AS bullet_name, next.name AS next_joint_name
              FROM turrets t LEFT JOIN bullets b ON b.id=t.bullet_id
              LEFT JOIN turrets next ON next.id=t.turret_next_joint_id ORDER BY t.id
        """):
            turret_rows[str(row["name"])] = row
            output = TURRET_DIR / f"{row['name']}.tres"
            turret_paths[str(row["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            muzzle = visual_path(art_xaf(connection, row["turret_muzzle_flash"]), "assets/converted/muzzle_flashes")
            fire_sounds, fire_volume = fire_sound_paths_for(str(row["name"]), sfx_sections, sfx_wavs)
            ok = write_or_check(
                output, turret_text(row, muzzle, fire_sounds, fire_volume), args.check
            ) and ok

        for derived_id, derived in sorted(DERIVED_TURRETS.items()):
            source_row = turret_rows.get(str(derived["source"]))
            if source_row is None:
                print(f"error: derived turret {derived_id} has no source turret")
                ok = False
                continue
            output = TURRET_DIR / f"{derived_id}.tres"
            turret_paths[derived_id] = "res://" + output.relative_to(ROOT).as_posix()
            muzzle = visual_path(
                art_xaf(connection, source_row["turret_muzzle_flash"]),
                "assets/converted/muzzle_flashes",
            )
            fire_sounds, fire_volume = fire_sound_paths_for(
                derived_id, sfx_sections, sfx_wavs, str(derived.get("fire_sound_section", ""))
            )
            fire_volume = int(derived.get("fire_sound_volume", fire_volume))
            ok = write_or_check(
                output,
                turret_text(
                    source_row, muzzle, fire_sounds, fire_volume,
                    config_id=derived_id,
                    fire_sound_exclusive=bool(derived.get("fire_sound_exclusive", True)),
                ),
                args.check,
            ) and ok

        bullet_paths: dict[str, str] = {}
        for row in connection.execute("""
            SELECT b.*, w.name AS warhead_name, e.name AS explosion_name,
                   explosion.damage_to_tile, art.xaf AS xaf
              FROM bullets b LEFT JOIN warheads w ON w.id=b.warhead_id
              LEFT JOIN explosion_types e ON e.id=b.explosion_type_id
              LEFT JOIN explosion_configs explosion
                ON explosion.explosion_type_id=e.id
              LEFT JOIN art_configs art ON art.entity_type='bullet' AND art.entity_id=b.id
             ORDER BY b.id
        """):
            output = BULLET_DIR / f"{row['name']}.tres"
            bullet_paths[str(row["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            effects = unit_list(connection, "SELECT e.name FROM entity_explosion_effects link JOIN explosion_types e ON e.id=link.explosion_type_id WHERE link.entity_type='bullet' AND link.entity_id=? ORDER BY link.seq", int(row["id"]))
            if not effects and row["explosion_name"]:
                effects = [str(row["explosion_name"])]
            impacts = {
                effect: path for effect in effects
                if (path := visual_path(art_xaf(connection, effect), "assets/converted/impact_effects"))
            }
            hit_sounds, hit_volume = hit_sound_paths_for(
                str(row["name"]), effects, bool(row["is_laser"]), bool(row["continuous"]),
                sfx_sections, sfx_wavs,
            )
            ok = write_or_check(output, bullet_text(
                row, effects,
                visual_path(str(row["xaf"] or ""), "assets/converted/projectiles"),
                impacts, hit_sounds, hit_volume,
            ), args.check) and ok

        warhead_paths: dict[str, str] = {}
        for warhead in connection.execute("SELECT id,name FROM warheads ORDER BY id"):
            output = WARHEAD_DIR / f"{warhead['name']}.tres"
            warhead_paths[str(warhead["name"])] = "res://" + output.relative_to(ROOT).as_posix()
            matrix = {str(item[0]): float(item[1]) for item in connection.execute(
                "SELECT a.name, d.damage_percent FROM warhead_armour_damage d JOIN armour_types a ON a.id=d.armour_type_id WHERE d.warhead_id=? ORDER BY a.sort_order",
                (int(warhead["id"]),),
            )}
            ok = write_or_check(output, warhead_text(str(warhead["name"]), matrix), args.check) and ok

        gravity = connection.execute("SELECT bullet_gravity FROM general_settings WHERE id=1").fetchone()[0]
        ok = write_or_check(COMBAT_SETTINGS_PATH, resource_text(
            "CombatSettings", "res://scripts/combat/combat_settings.gd",
            [f"bullet_gravity = {float(gravity or 1.0):.6g}"],
        ), args.check) and ok
        ok = write_or_check(
            COMBAT_MANIFEST_PATH,
            combat_manifest_text(turret_paths, bullet_paths, warhead_paths),
            args.check,
        ) and ok

        building_paths: dict[str, str] = {}
        building_scene_paths: dict[str, str] = {}
        building_scene_outputs: dict[str, str] = {}
        for building in connection.execute("""
            SELECT b.*, t.name AS turret_name, h.name AS house_name,
                   bg.name AS building_group_name, armour.name AS armour_name,
                   art.xaf AS xaf, art.icon AS icon, art.icon_grey AS icon_grey,
                   art.sidebar_type AS sidebar_type,
                   explosion.name AS explosion_type_name
              FROM buildings b
              LEFT JOIN turrets t ON t.id=b.turret_attach_id
              LEFT JOIN houses h ON h.id=b.house_id
              LEFT JOIN building_groups bg ON bg.id=b.building_group_id
              LEFT JOIN armour_types armour ON armour.id=b.armour_type_id
              LEFT JOIN art_configs art ON art.entity_type='building' AND art.entity_id=b.id
              LEFT JOIN explosion_types explosion ON explosion.id=b.explosion_type_id
             ORDER BY b.id
        """):
            building_id = str(building["name"])
            output = BUILDING_DEFINITION_DIR / f"{building_id}.tres"
            building_paths[building_id] = "res://" + output.relative_to(ROOT).as_posix()
            converted = (
                CONVERTED_BUILDING_DIR / building_id / f"{building_id}.scn"
            )
            if converted.exists():
                scene_output = (
                    BUILDING_SCENE_DIR / f"{building_scene_stem(building_id)}.tscn"
                )
                previous_id = building_scene_outputs.get(scene_output.name)
                if previous_id is not None:
                    raise ValueError(
                        f"building scene filename collision: {previous_id} and "
                        f"{building_id} both map to {scene_output.name}"
                    )
                building_scene_outputs[scene_output.name] = building_id
                converted_path = "res://" + converted.relative_to(ROOT).as_posix()
                building_scene_paths[building_id] = (
                    "res://" + scene_output.relative_to(ROOT).as_posix()
                )
                ok = write_or_check(
                    scene_output,
                    building_scene_text(building_id, converted_path),
                    args.check,
                ) and ok
            occupy = unit_list(connection, "SELECT pattern FROM building_occupy_rows WHERE building_id=? ORDER BY row_index", int(building["id"]))
            # Converted models negate source Z when moving from Emperor's
            # left-handed space to Godot. Runtime footprint row 0 points toward
            # -Z, so mirror the source matrix to keep its skirt/apron on the
            # model's converted +Z side.
            occupy.reverse()
            # Converted building assets are horizontally mirrored relative to
            # the source Occupy notation.
            occupy = [row[::-1] for row in occupy]
            links = unit_list(connection, "SELECT target_name FROM entity_resource_links WHERE entity_type='building' AND entity_id=? ORDER BY seq", int(building["id"]))
            primary = unit_list(connection, "SELECT b.name FROM building_requires_primary link JOIN buildings b ON b.id=link.required_building_id WHERE link.building_id=? ORDER BY link.rowid", int(building["id"]))
            secondary = unit_list(connection, "SELECT b.name FROM building_requires_secondary link JOIN buildings b ON b.id=link.required_building_id WHERE link.building_id=? ORDER BY link.rowid", int(building["id"]))
            roles = unit_list(connection, "SELECT r.name FROM building_role_tags link JOIN building_roles r ON r.id=link.role_id WHERE link.building_id=? ORDER BY r.id", int(building["id"]))
            deploy_points = list(connection.execute("SELECT tile_x,tile_y,angle FROM building_deploy_points WHERE building_id=? ORDER BY seq", (int(building["id"]),)))
            explosion_effects = unit_list(connection, "SELECT e.name FROM entity_explosion_effects link JOIN explosion_types e ON e.id=link.explosion_type_id WHERE link.entity_type='building' AND link.entity_id=? ORDER BY link.seq", int(building["id"]))
            # Mirrors the unit loop's runtime fallback (CombatBullet.explosion_effect_ids()):
            # a building with no explicit effect list still explodes using its
            # single ExplosionType, so the scene-path dict must cover that id too.
            explosion_lookup_effects = explosion_effects
            if not explosion_lookup_effects and building["explosion_type_name"]:
                explosion_lookup_effects = [str(building["explosion_type_name"])]
            explosion_paths = {
                effect: path for effect in explosion_lookup_effects
                if (path := visual_path(art_xaf(connection, effect), "assets/converted/impact_effects"))
            }
            ok = write_or_check(output, building_definition_text(building, occupy, links, primary, secondary, roles, deploy_points, explosion_effects, explosion_paths), args.check) and ok
        ok = write_or_check(
            BUILDING_MANIFEST_PATH,
            manifest_text(building_paths, building_scene_paths),
            args.check,
        ) and ok

        settings = connection.execute(
            "SELECT max_building_placement_tile_dist, repair_rate FROM general_settings WHERE id=1"
        ).fetchone()
        placement_distance = settings[0] if settings is not None else 6
        repair_rate = settings[1] if settings is not None else 12
        ok = write_or_check(GAME_SETTINGS_PATH, resource_text(
            "GameSettings", "res://scripts/rules/game_settings.gd",
            [
                f"max_building_placement_tile_dist = {int(placement_distance or 6)}",
                f"building_repair_rate = {float(repair_rate or 12):.1f}",
                "maximum_ground_decals = 256",
            ],
        ), args.check) and ok
        spice = connection.execute("""
            SELECT s.*, e.name AS explosion_name FROM spice_mound_types s
              LEFT JOIN explosion_types e ON e.id=s.explosion_type_id
             WHERE s.name='SpiceMound' LIMIT 1
        """).fetchone()
        if spice is not None:
            ok = write_or_check(SPICE_DEFINITION_PATH, spice_definition_text(spice), args.check) and ok

    if not args.check and DEFINITION_DIR.exists():
        for stale in DEFINITION_DIR.glob("*.tres"):
            if stale not in expected_files:
                stale.unlink()
    if not args.check and VETERANCY_DIR.exists():
        for stale in VETERANCY_DIR.glob("*.tres"):
            if stale not in expected_veterancy:
                stale.unlink()
    ok = write_or_check(MANIFEST_PATH, manifest_text(definition_paths, scene_paths), args.check) and ok
    if not args.check:
        print(
            f"generated {len(definition_paths)} units, {len(turret_paths)} turrets, "
            f"{len(bullet_paths)} bullets, {len(warhead_paths)} warheads and "
            f"{len(scene_paths)} unit scenes, {len(building_paths)} buildings and "
            f"{len(building_scene_paths)} building scenes"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
