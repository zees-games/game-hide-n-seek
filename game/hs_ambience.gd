extends RefCounted

## What the house's ambience is: the cvar defaults shared by the simulation (binds `hs_ambient*`) and the client's director (plays them).

const PREFIX := "hs"
## Hiding is listening: the layer is felt, not heard, and the one-shots are rare so a step still stands out.
const LEVEL := 0.15
const RATE := 0.4
const DEFAULT_MOOD := &"interior_horror"

## By map id prefix; the practice house and any map not listed take the default.
const PREFIX_MOODS := {
	"hs_warehouse": &"industrial", "hs_castle": &"interior_horror", "hs_camp": &"outdoor_night",
	"hs_park": &"outdoor_night", "hs_village": &"outdoor_night", "hs_frontyard": &"outdoor_night",
	"hs_ship": &"snow_wind",
}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r


## The cvars a workbench set offers: name -> profile type.
static func cvar_types() -> Dictionary:
	var rules := make_rules()
	var out := {}
	for key: String in DotAmbienceRules.VARS:
		var row: Array = DotAmbienceRules.VARS[key]
		out[rules.cvar_of(row)] = "string" if row[2] == null else "float"
	return out
