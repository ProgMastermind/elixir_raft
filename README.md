```markdown
# ElixirRaft

A learning implementation of the Raft consensus algorithm in Elixir, designed for understanding distributed consensus mechanisms.

## Overview

ElixirRaft is an educational implementation of the Raft consensus protocol, focusing on clarity and understanding rather than production use. It implements core Raft features including:

- Leader election
- Log replication
- Term management
- Cluster membership
- Persistent state management
- Network communication

## Project Structure

```
lib/
├── consensus/           # Core consensus mechanisms
│   ├── commit_manager.ex    # Manages log commitment
│   ├── message_dispatcher.ex # Handles message routing
│   └── state_machine.ex     # Applies committed entries
├── core/               # Core Raft components
│   ├── cluster_config.ex    # Cluster membership
│   ├── log_entry.ex        # Log entry structure
│   ├── node_id.ex          # Node identification
│   ├── server_state.ex     # Server state management
│   └── term.ex             # Term management
├── network/            # Network layer
│   ├── peer.ex            # Peer connection management
│   ├── tcp_transport.ex   # TCP communication
│   └── transport_behaviour.ex # Transport interface
├── rpc/                # RPC message definitions
│   └── messages.ex         # Protocol messages
├── server/             # Role implementations
│   ├── candidate.ex       # Candidate role
│   ├── follower.ex       # Follower role
│   ├── leader.ex         # Leader role
│   └── role_behaviour.ex # Role interface
└── storage/            # Persistence layer
    ├── log_store.ex       # Log storage
    └── state_store.ex     # State persistence
```

## Implementation Details

### Core Components

#### Server Roles
- **Leader**: Handles log replication and heartbeats
- **Follower**: Responds to leader requests and timeouts
- **Candidate**: Manages election process

#### Consensus
- Term-based leadership
- Log replication with consistency checks
- Commit index management
- State machine application

#### Network
- TCP-based peer communication
- Connection management
- Message serialization

#### Storage
- Persistent log storage
- Atomic state updates
- Crash recovery handling

## Testing

The project includes comprehensive tests:

```
test/
├── consensus/          # Consensus mechanism tests
├── core/              # Core component tests
├── integration/       # Integration tests
├── network/          # Network layer tests
├── rpc/              # Message handling tests
├── server/           # Role implementation tests
└── storage/          # Persistence tests
```

Run tests with:
```bash
mix test
```

## Installation

1. Clone the repository:
```bash
git clone https://github.com/ProgMastermind/elixir_raft.git
```

2. Install dependencies:
```bash
cd elixir_raft
mix deps.get
```

3. Run tests:
```bash
mix test
```

## Usage

```elixir
# Configuration example (config/config.exs)
config :elixir_raft,
  cluster_size: 3,
  peers: %{
    "node1" => {{127, 0, 0, 1}, 9001},
    "node2" => {{127, 0, 0, 1}, 9002},
    "node3" => {{127, 0, 0, 1}, 9003}
  }
```

## Features

- [x] Leader Election
- [x] Log Replication
- [x] Safety Guarantees
- [x] Persistent State
- [x] Network Communication
- [x] Membership Changes
- [ ] Log Compaction
- [ ] Client Interaction Layer
- [ ] Metrics/Monitoring

## Contributing

This is a learning project, but contributions are welcome! Please feel free to:

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Academic Purpose

This implementation is designed for learning and understanding the Raft consensus algorithm. It prioritizes code clarity and educational value over production readiness.

## References

- [Raft Paper](https://raft.github.io/raft.pdf)
- [Raft Visualization](http://thesecretlivesofdata.com/raft/)
- [Raft Website](https://raft.github.io/)

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Acknowledgments

- The Raft authors for the algorithm design
- The Elixir community for the excellent tooling
- All contributors and reviewers

---

🌟 If you find this helpful for learning Raft, please consider giving it a star!
```
