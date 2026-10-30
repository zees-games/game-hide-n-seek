extends RefCounted

## Where this game's own files are, wherever this copy of it happens to live.
## A delivered pack mounts at [code]res://dot_cloud/<id>/<version>/[/code], not where its content was authored, so an absolute `res://` reference to its OWN files resolves against the HOST root. A script knows where it is (`resource_path`), so the root is this directory minus `game/`. Built in, [method rebase] returns what it was passed.
## Anything holding one of these paths is a `static var`, not a `const`: a constant is folded at parse time, before [method root] is knowable.

const _SELF := preload("hs_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]. Anything else comes back untouched; format specifiers survive, since only the prefix is replaced.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered.
## So the mounted case can be TESTED from a build: built in, every `res://` path is already under the root, so a suite asserting rebase's properties passes whatever the body says (breaking idempotence still passed 101 of 101).
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher rewrites every `res://` string in a `.tscn`, `.tres` and `.import` onto the mount prefix, but not those inside a `.gd`, so a game holds both kinds. Rebasing an already-rebased path doubles the prefix, which fails to load with a path long enough that the doubling is easy to miss.
	# Built in, [param here] is `res://` so this returns its argument unchanged. Delivery bugs of this family: ../dot-server-deploy/docs/delivery-constraint.md.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
