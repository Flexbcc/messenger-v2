from shared.transport.link_sequence import LinkSequenceStore


def test_sequence_replay_and_reorder_are_rejected_across_restart(tmp_path):
    path = str(tmp_path / "sequence.db")
    store = LinkSequenceStore(path)
    assert store.accept(peer_node_id="home-a", connection_id="connection-1", sequence=1)
    assert store.accept(peer_node_id="home-a", connection_id="connection-1", sequence=2)
    assert not store.accept(peer_node_id="home-a", connection_id="connection-1", sequence=2)

    restored = LinkSequenceStore(path)
    assert not restored.accept(peer_node_id="home-a", connection_id="connection-1", sequence=1)
    assert restored.accept(peer_node_id="home-a", connection_id="connection-1", sequence=3)


def test_connection_ids_have_independent_sequences(tmp_path):
    store = LinkSequenceStore(str(tmp_path / "sequence.db"))
    assert store.accept(peer_node_id="home-a", connection_id="connection-1", sequence=7)
    assert store.accept(peer_node_id="home-a", connection_id="connection-2", sequence=1)
