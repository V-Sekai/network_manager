extends Node
tool

const LOG_SENT_DATA = false
var sent_data_file = File.new()

const ref_pool_const = preload("res://addons/gdutil/ref_pool.gd")

var internal_timer = 0.0

# Network latency simulation
var simulate_network_conditions: bool = false
var min_latency: float = 0.0
var max_latency: float = 0.0
var drop_rate: float = 0.0
var dup_rate: float = 0.0


class PendingPacket:
	extends Reference
	var id: int = -1
	var ref_pool: Reference = null

	func _init(p_id: int, p_ref_pool: Reference) -> void:
		id = p_id
		ref_pool = p_ref_pool


class PendingPacketTimed:
	extends PendingPacket
	var time: float = 0.0

	func _init(p_id: int, p_ref_pool: Reference, p_time: float).(p_id, p_ref_pool) -> void:
		time = p_time


var unreliable_packet_queue: Array = []
var unreliable_ordered_packet_queue: Array = []
var reliable_packet_queue: Array = []

# For network simulation
var unreliable_packet_queue_time_sorted: Array = []
var unreliable_ordered_packet_queue_time_sorted: Array = []
var reliable_packet_queue_time_sorted: Array = []

var packet_peer_target: Dictionary = {}

static func save_packet_data(
	p_file: File,
	p_sender_peer_id: int,
	p_target_peer_id: int,
	p_transfer_mode: int,
	p_packet: PoolByteArray
) -> void:
	if LOG_SENT_DATA:
		var transfer_mode_string: String = "?"
		match p_transfer_mode:
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
				transfer_mode_string = "Unreliable"
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
				transfer_mode_string = "Unreliable Ordered"
			NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE:
				transfer_mode_string = "Reliable Ordered"

		var send_data_report: String = (
			"From: %s - Packet sent to: %s - Transfer Mode: %s - Data: %s"
			% [
				str(p_sender_peer_id),
				str(p_target_peer_id),
				transfer_mode_string,
				str(p_packet.hex_encode())
			]
		)
		p_file.store_line(send_data_report)


func queue_packet_for_send(p_ref_pool: ref_pool_const, p_id: int, p_transfer_mode: int) -> void:
	match p_transfer_mode:
		NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
			unreliable_packet_queue.push_back(PendingPacket.new(p_id, p_ref_pool))
		NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
			unreliable_ordered_packet_queue.push_back(PendingPacket.new(p_id, p_ref_pool))
		NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE:
			reliable_packet_queue.push_back(PendingPacket.new(p_id, p_ref_pool))
		_:
			NetworkLogger.error("Attempted to queue packet with invalid transfer mode!")


func send_packet_queue(p_packet_queue: Array, p_transfer_mode: int):
	if get_tree().multiplayer.get_network_peer():
		get_tree().multiplayer.get_network_peer().set_transfer_mode(p_transfer_mode)
		for packet in p_packet_queue:
			if (
				packet.id == NetworkManager.network_constants_const.ALL_PEERS
				or packet.id == NetworkManager.network_constants_const.SERVER_MASTER_PEER_ID
				or NetworkManager.peer_is_connected(packet.id)
			):
				var send_bytes_result: int = get_tree().multiplayer.send_bytes(
					packet.ref_pool.pool_byte_array, packet.id, p_transfer_mode
				)
				if send_bytes_result != OK:
					NetworkLogger.error(
						"Send bytes error: {send_bytes_result}".format(
							{"send_bytes_result": str(send_bytes_result)}
						)
					)
				else:
					if LOG_SENT_DATA:
						save_packet_data(
							sent_data_file,
							NetworkManager.get_current_peer_id(),
							packet.id,
							p_transfer_mode,
							packet.ref_pool.pool_byte_array
						)


func ordered_inserted(p_packet: Reference, p_time_sorted_queue: Array, p_packet_time: float):
	if p_time_sorted_queue.size():
		var packet_inserted: bool = false
		for i in range(0, p_time_sorted_queue.size()):
			if p_packet_time < p_time_sorted_queue[i].time:
				p_time_sorted_queue.insert(i, p_packet)
				packet_inserted = true
				break

		# If the packet was not inserted, put it in the end of the queue
		if ! packet_inserted:
			p_time_sorted_queue.append(p_packet)
	else:
		p_time_sorted_queue.append(p_packet)


func setup_and_send_ordered_queue(
	p_time: float, p_queue: Array, p_time_sorted_queue: Array, p_transfer_mode: int
) -> Array:
	for packet in p_queue:
		if p_transfer_mode != NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE:
			if randf() < drop_rate:
				continue

		var first_packet_time: float = p_time + min_latency + randf() * (max_latency - min_latency)
		match p_transfer_mode:
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
				var new_packet: Reference = PendingPacketTimed.new(
					packet.id, packet.ref_pool, first_packet_time
				)
				ordered_inserted(new_packet, p_time_sorted_queue, first_packet_time)
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
				var latest_time: float = 0.0
				if p_time_sorted_queue.size() > 0:
					latest_time = p_time_sorted_queue.back().time
				if first_packet_time >= latest_time:
					p_time_sorted_queue.append(
						PendingPacketTimed.new(packet.id, packet.ref_pool, first_packet_time)
					)
			NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE:
				var latest_time: float = 0.0
				if p_time_sorted_queue.size() > 0:
					latest_time = p_time_sorted_queue.back().time
				p_time_sorted_queue.append(
					PendingPacketTimed.new(
						packet.id, packet.ref_pool, max(latest_time, first_packet_time)
					)
				)

		while randf() < dup_rate:
			var dup_packet_time: float = (
				p_time
				+ min_latency
				+ randf() * (max_latency - min_latency)
			)
			match p_transfer_mode:
				NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
					var new_packet: Reference = PendingPacketTimed.new(
						packet.id, packet.ref_pool, dup_packet_time
					)
					ordered_inserted(new_packet, p_time_sorted_queue, dup_packet_time)
				NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
					var latest_time: float = 0.0
					if p_time_sorted_queue.size() > 0:
						latest_time = p_time_sorted_queue.back().time
					if dup_packet_time >= latest_time:
						p_time_sorted_queue.append(
							PendingPacketTimed.new(packet.id, packet.ref_pool, dup_packet_time)
						)

	var current_queue: Array = p_time_sorted_queue.duplicate()
	for packet in current_queue:
		if p_time >= packet.time:
			var index: int = p_time_sorted_queue.find(packet)
			assert(index >= 0)
			if (
				packet.id == NetworkManager.network_constants_const.ALL_PEERS
				or packet.id == NetworkManager.network_constants_const.SERVER_MASTER_PEER_ID
				or NetworkManager.peer_is_connected(packet.id)
			):
				var send_bytes_result: int = get_tree().multiplayer.send_bytes(
					packet.ref_pool.pool_byte_array, packet.id, p_transfer_mode
				)
				if send_bytes_result != OK:
					NetworkLogger.error(
						"Send bytes error: {send_bytes_result}".format(
							{"send_bytes_result": str(send_bytes_result)}
						)
					)
				else:
					if LOG_SENT_DATA:
						save_packet_data(
							sent_data_file,
							NetworkManager.get_current_peer_id(),
							packet.id,
							p_transfer_mode,
							packet.ref_pool.pool_byte_array
						)

			p_time_sorted_queue.remove(index)

	return p_time_sorted_queue


func process_network_packets(p_delta: float) -> void:
	internal_timer += p_delta

	if simulate_network_conditions:
		reliable_packet_queue_time_sorted = setup_and_send_ordered_queue(
			internal_timer,
			reliable_packet_queue,
			reliable_packet_queue_time_sorted,
			NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE
		)
		unreliable_packet_queue_time_sorted = setup_and_send_ordered_queue(
			internal_timer,
			unreliable_packet_queue,
			unreliable_packet_queue_time_sorted,
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		)
		unreliable_ordered_packet_queue_time_sorted = setup_and_send_ordered_queue(
			internal_timer,
			unreliable_ordered_packet_queue,
			unreliable_ordered_packet_queue_time_sorted,
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		)
	else:
		send_packet_queue(reliable_packet_queue, NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE)
		send_packet_queue(
			unreliable_packet_queue, NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		)
		send_packet_queue(
			unreliable_ordered_packet_queue,
			NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		)

	clear_packet_queues()


func clear_packet_queues() -> void:
	unreliable_packet_queue = []
	unreliable_ordered_packet_queue = []
	reliable_packet_queue = []


func clear_time_sorted_packet_queues() -> void:
	unreliable_packet_queue_time_sorted = []
	unreliable_ordered_packet_queue_time_sorted = []
	reliable_packet_queue_time_sorted = []


func reset():
	internal_timer = 0.0
	clear_packet_queues()
	clear_time_sorted_packet_queues()


func _ready() -> void:
	if LOG_SENT_DATA:
		sent_data_file = File.new()
		var datetime: Dictionary = OS.get_datetime(true)

		sent_data_file.open(
			(
				"user://sent_data_file_%s_%s_%s_%s_%s_%s"
				% [
					str(datetime.year),
					str(datetime.month),
					str(datetime.day),
					str(datetime.hour),
					str(datetime.minute),
					str(datetime.second)
				]
			),
			File.WRITE
		)
