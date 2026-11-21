extends GSGameNetLink

## This game's link: the shared skeleton in [GSGameNetLink], plus the names that are its own.

const HsNetLink := preload("hs_net_link.gd")

const CHANNEL := "hs.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"HideSeek"


func _init() -> void:
	channel = CHANNEL


static func attached_to(parent: Node, p_bridge: Node, server: bool) -> HsNetLink:
	var link := HsNetLink.new()
	link.name = NODE_NAME
	link.bridge = p_bridge
	link.is_server = server
	return link
