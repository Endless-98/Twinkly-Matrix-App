"""Player registry for multi-phone game input.

Each phone connecting from the Flutter controller should identify itself
with a unique ``player_id`` (for example, a UUID or any device-local token).
The registry keeps track of active players, exposes per-player input
callbacks, and lets game code pull queued inputs when no callback is set.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from threading import Lock
from typing import Any, Callable, Deque, Dict, Iterable, List, Optional
import time

InputPayload = Dict[str, Any]
InputHandler = Callable[["Player", InputPayload], None]

input_received = False


@dataclass
class Player:
    """Represents a single phone/player."""

    player_id: str
    phone_id: str
    game: str = "tetris"
    connected: bool = True
    last_seen: datetime = field(default_factory=datetime.utcnow)
    on_input: Optional[InputHandler] = None
    backlog: Deque[InputPayload] = field(default_factory=deque)
    game_state: Dict[str, Any] = field(default_factory=dict)  # For game-specific data (score, level, etc.)

    def enqueue(self, payload: InputPayload) -> None:
        """Append a payload to this player's backlog and update last_seen."""
        self.backlog.append(payload)
        self.last_seen = datetime.utcnow()

    def has_pending(self) -> bool:
        return bool(self.backlog)


class Players:
    """Registry that tracks active players and routes their inputs.

    This class is thread-safe for concurrent network/game threads.
    """

    def __init__(self) -> None:
        self._players: Dict[str, Player] = {}
        self._lock = Lock()
        self._global_listeners: List[InputHandler] = []
        self._last_hard_drop: Dict[str, float] = {}

    HARD_DROP_COOLDOWN_SEC = 0.75  # prevent repeat hard-drops while held

    def register(
        self,
        player_id: str,
        *,
        phone_id: Optional[str] = None,
        game: str = "tetris",
        on_input: Optional[InputHandler] = None,
    ) -> Player:
        """Add or refresh a player entry.

        - ``player_id``: stable identifier coming from the phone (recommended: UUID).
        - ``phone_id``: optional human-readable label; defaults to ``player_id``.
        - ``game``: current game namespace (defaults to "tetris").
        - ``on_input``: optional callback invoked for each incoming payload for this player.
        """
        with self._lock:
            existing = self._players.get(player_id)
            if existing:
                existing.connected = True
                existing.game = game or existing.game
                existing.last_seen = datetime.utcnow()
                if on_input:
                    existing.on_input = on_input
                return existing

            player = Player(
                player_id=player_id,
                phone_id=phone_id or player_id,
                game=game,
                on_input=on_input,
            )
            self._players[player_id] = player
            return player

    def unregister(self, player_id: str) -> None:
        """Remove a player completely (e.g., phone left the game page)."""
        with self._lock:
            self._players.pop(player_id, None)

    def mark_disconnected(self, player_id: str) -> None:
        """Mark a player as offline without deleting its backlog."""
        with self._lock:
            player = self._players.get(player_id)
            if player:
                player.connected = False
                player.last_seen = datetime.utcnow()

    def set_input_handler(self, player_id: str, handler: InputHandler) -> None:
        """Attach/replace the per-player callback."""
        with self._lock:
            player = self._players.get(player_id)
            if not player:
                player = self.register(player_id)
            player.on_input = handler

    def add_global_listener(self, handler: InputHandler) -> None:
        """Subscribe to every input for every player (e.g., logging/metrics)."""
        with self._lock:
            self._global_listeners.append(handler)

    def handle_input(self, player_id: str, payload: InputPayload) -> None:
        """Route an incoming payload to the proper player.

        - Ensures the player exists (auto-registers if needed).
        - Updates last_seen.
        - Enqueues the payload.
        - Invokes global callbacks immediately (logging/metrics).
        - Per-player handlers are invoked on the game thread by draining the queue.
        """
        listeners: List[InputHandler]
        player: Player

        with self._lock:
            player = self._players.get(player_id) or self.register(player_id)

            # Drop repeated HARD_DROP while the button is held (cooldown-based)
            cmd = str(payload.get("cmd", "")).upper()
            now = time.monotonic()
            if cmd == "HARD_DROP":
                last_ts = self._last_hard_drop.get(player_id, 0.0)
                if (now - last_ts) < self.HARD_DROP_COOLDOWN_SEC:
                    # Ignore this repeat hard drop
                    return
                self._last_hard_drop[player_id] = now
            else:
                # Any other command clears the cooldown marker
                self._last_hard_drop.pop(player_id, None)

            player.enqueue(payload)
            listeners = list(self._global_listeners)

        for listener in listeners:
            listener(player, payload)

        global input_received
        input_received = True

    def next_input(self, player_id: str) -> Optional[InputPayload]:
        """Pop the oldest queued payload for a player, if any."""
        with self._lock:
            player = self._players.get(player_id)
            if not player or not player.backlog:
                return None
            return player.backlog.popleft()

    def drain_inputs(self, player_id: str) -> Iterable[InputPayload]:
        """Yield and clear all queued payloads for a player."""
        while True:
            payload = self.next_input(player_id)
            if payload is None:
                break
            yield payload

    def active_players(self) -> List[Player]:
        """Snapshot of all players (connected flag may be False)."""
        with self._lock:
            return list(self._players.values())

    def has_player(self, player_id: str) -> bool:
        with self._lock:
            return player_id in self._players

    def clear_all(self) -> None:
        with self._lock:
            self._players.clear()
            self._global_listeners.clear()


# Module-level singleton and helpers so callers don't manage registry wiring
_registry = Players()


def get_registry() -> Players:
    """Return the shared Players registry."""
    return _registry


def register_player(
    player_id: str,
    *,
    phone_id: Optional[str] = None,
    game: str = "tetris",
    on_input: Optional[InputHandler] = None,
) -> Player:
    """Convenience wrapper to register/refresh a player on the shared registry."""
    return _registry.register(player_id, phone_id=phone_id, game=game, on_input=on_input)


def handle_input(player_id: str, payload: InputPayload) -> None:
    """Push an incoming payload into the shared registry (auto-registers player)."""
    _registry.handle_input(player_id, payload)


def set_input_handler(player_id: str, handler: InputHandler) -> None:
    """Attach/replace a per-player handler on the shared registry."""
    _registry.set_input_handler(player_id, handler)


def active_players() -> List[Player]:
    """Snapshot of active players from the shared registry."""
    return _registry.active_players()


def next_input(player_id: str) -> Optional[InputPayload]:
    """Pop the oldest queued payload for a player, if any."""
    return _registry.next_input(player_id)
