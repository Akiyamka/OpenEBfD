extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatGroundDecalScript := preload("res://scripts/combat/combat_ground_decal.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const LaserBeamScript := preload("res://scripts/combat/fx/laser_beam.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const ShotPayloadScript := preload("res://scripts/combat/shot_payload.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const Assertions := preload("res://tests/combat/support/combat_assertions.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATSniperModelScene := preload(
	"res://assets/converted/models/AT_Sniper_H0/AT_Sniper_H0.scn"
)
const ATTrikeModelScene := preload(
	"res://assets/converted/models/AT_Trike_H0/AT_Trike_H0.scn"
)
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const ORMortarModelScene := preload(
	"res://assets/converted/models/OR_Mortar_H0/OR_Mortar_H0.scn"
)
const HKMissileModelScene := preload(
	"res://assets/converted/models/HK_missile_H0/HK_missile_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const HKInkVineModelScene := preload(
	"res://assets/converted/models/HK_Inkvine_H0/HK_Inkvine_H0.scn"
)
const HKFlamerModelScene := preload(
	"res://assets/converted/models/HK_Flamer_H0/HK_Flamer_H0.scn"
)
const HKFlameModelScene := preload(
	"res://assets/converted/models/HK_flame_H0/HK_flame_H0.scn"
)
const ORChemicalModelScene := preload(
	"res://assets/converted/models/OR_Chemical_H0/OR_Chemical_H0.scn"
)
const HKTrooperModelScene := preload(
	"res://assets/converted/models/HK_Trooper_H0/HK_Trooper_H0.scn"
)
const HKAssaultModelScene := preload(
	"res://assets/converted/models/HK_assault_H0/HK_assault_H0.scn"
)
const ORAATrooperModelScene := preload(
	"res://assets/converted/models/OR_AATrooper_H0/OR_AATrooper_H0.scn"
)
const ORAPCModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const ORLaserTankModelScene := preload(
	"res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn"
)
const IMAdvSardaukarModelScene := preload(
	"res://assets/converted/models/IM_ADVSardaukar_H0/IM_ADVSardaukar_H0.scn"
)
const ATKindjalModelScene := preload(
	"res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn"
)
const ORKobraModelScene := preload(
	"res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn"
)
const HKGunTurretScene := preload(
	"res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn"
)
const HKStarportScene := preload(
	"res://assets/converted/buildings/HKStarport/HKStarport.scn"
)
const ATWallScene := preload(
	"res://assets/converted/buildings/ATWall/ATWall.scn"
)

## Stands in for a cliff face or rock shoulder: static geometry on the terrain
## collision layer between a shooter and its target.

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_finish("Combat tests")
