"""Game-specific player management with limits, timeouts, and lifecycle tracking."""

from __future__ import annotations

import time
from typing import Dict, List, Optional

from players import Player, register_player, set_input_handler, get_registry, InputPayload
from logger import log


# Per-game configuration
GAME_LIMITS = {
    "tetris": 2,  # Max 2 players for Tetris
}

PLAYER_TIMEOUT_SEC = 10  # Mark player as idle if no heartbeat for 10s (matches heartbeat interval)


class GamePlayerManager:
    """Tracks active players per game, enforces limits, and detects disconnects."""

    def __init__(self):
        self._active_by_game: Dict[str, List[str]] = {}  # game -> [player_id, ...]
        self._last_heartbeat: Dict[str, float] = {}  # player_id -> timestamp
        self._player_metadata: Dict[str, dict] = {}  # player_id -> {game, joined_at, ...}

    def can_join(self, game: str) -> bool:
        """Check if a new player can join this game (respects limits)."""
        limit = GAME_LIMITS.get(game)
        if limit is None:
            return True  # No limit
        current_count = len(self._active_by_game.get(game, []))
        return current_count < limit

    def join(self, player_id: str, phone_id: Optional[str] = None, game: str = "tetris", gamemode_selection: int = 0) -> bool:
        """
        Register a new player for a game if the limit allows.
        Returns True if successful, False if game is full.
        """
        if not self.can_join(game):
            log(f"Game {game} is full, rejecting join from {player_id}", level='WARNING', module="GamePlayers")
            return False

        # Register with the shared registry
        register_player(player_id, phone_id=phone_id, game=game)

        # Track in our game-specific manager
        if game not in self._active_by_game:
            self._active_by_game[game] = []
        if player_id not in self._active_by_game[game]:
            self._active_by_game[game].append(player_id)

        self._last_heartbeat[player_id] = time.time()
        self._player_metadata[player_id] = {
            "game": game,
            "joined_at": time.time(),
            "phone_id": phone_id,
            "gamemode_selection": gamemode_selection,
        }

        log(f"Player {phone_id} ({player_id}) joined {game}. Total in game: {len(self._active_by_game[game])}", module="GamePlayers")
        return True

    def leave(self, player_id: str) -> None:
        """Remove a player from all games (called on disconnect/timeout/backout)."""
        registry = get_registry()
        registry.unregister(player_id)

        # Remove from all games
        for game_list in self._active_by_game.values():
            if player_id in game_list:
                game_list.remove(player_id)

        self._last_heartbeat.pop(player_id, None)
        self._player_metadata.pop(player_id, None)

    def heartbeat(self, player_id: str) -> None:
        """Update the last-seen timestamp for a player (called on any input/ping)."""
        self._last_heartbeat[player_id] = time.time()

    def get_idle_players(self, timeout_sec: float = PLAYER_TIMEOUT_SEC) -> List[str]:
        """Return player IDs that have not sent a heartbeat in timeout_sec."""
        now = time.time()
        idle = []
        for player_id, last_ts in self._last_heartbeat.items():
            if (now - last_ts) > timeout_sec:
                idle.append(player_id)
        return idle

    def cleanup_idle(self, timeout_sec: float = PLAYER_TIMEOUT_SEC) -> None:
        """Remove all idle players."""
        for player_id in self.get_idle_players(timeout_sec):
            game = self._player_metadata.get(player_id, {}).get("game", "unknown")
            phone_id = self._player_metadata.get(player_id, {}).get("phone_id", player_id)
            log(f"⏱️  TIMEOUT - Removing idle player: {phone_id} from {game} (no heartbeat for {timeout_sec}s)", module="GamePlayers")
            self.leave(player_id)

    def get_active_players_for_game(self, game: str) -> List[Player]:
        """Return list of Player objects currently in this game."""
        player_ids = self._active_by_game.get(game, [])
        registry = get_registry()
        return [registry._players[pid] for pid in player_ids if pid in registry._players]

    def get_game_for_player(self, player_id: str) -> Optional[str]:
        """Return the game a player is currently in, or None."""
        return self._player_metadata.get(player_id, {}).get("game")

    def is_game_full(self, game: str) -> bool:
        """Check if a game has reached its player limit."""
        return not self.can_join(game)

    def player_count_for_game(self, game: str) -> int:
        """Get current player count for a game."""
        return len(self._active_by_game.get(game, []))


# Module-level singleton
_game_manager = GamePlayerManager()


def get_game_manager() -> GamePlayerManager:
    """Return the shared GamePlayerManager."""
    return _game_manager


def join_game(
    player_id: str, phone_id: Optional[str] = None, game: str = "tetris", gamemode_selection: int = 0
) -> bool:
    """Attempt to join a player into a game. Returns True if successful."""
    return _game_manager.join(player_id, phone_id=phone_id, game=game, gamemode_selection=gamemode_selection)


def leave_game(player_id: str) -> None:
    """Remove a player from their game (on disconnect/timeout/backout)."""
    log(f"leave_game() called for {player_id}", module="GamePlayers")
    _game_manager.leave(player_id)


def heartbeat(player_id: str) -> None:
    """Update last-seen timestamp for a player (call on any input from them)."""
    _game_manager.heartbeat(player_id)


def get_active_players_for_game(game: str) -> List[Player]:
    """Get list of Player objects currently in a game (use by index: [0], [1], etc.)."""
    return _game_manager.get_active_players_for_game(game)


def get_game_for_player(player_id: str) -> Optional[str]:
    """Get the game a player is in, or None if not in any game."""
    return _game_manager.get_game_for_player(player_id)


def is_game_full(game: str) -> bool:
    """Check if a game is at max capacity."""
    return _game_manager.is_game_full(game)


def cleanup_idle_players() -> None:
    """Remove players that haven't sent a heartbeat (call periodically, e.g., every 5 sec)."""
    _game_manager.cleanup_idle()


def player_count_for_game(game: str) -> int:
    """Get current player count for a game."""
    return _game_manager.player_count_for_game(game)


def get_player_data(player_id: str) -> Optional[dict]:
    """
    Get game state data for a player (score, level, lines, etc.).
    Returns the game_state dict stored on the player, or None if player not found.
    """
    registry = get_registry()
    player = registry._players.get(player_id)
    if player:
        return player.game_state
    return None


def set_player_score_data(player_id: str, score: int, level: int = 1, lines: int = 0) -> None:
    """
    Update a player's game score data.
    This should be called from the game (e.g., Tetris) whenever score changes.
    """
    registry = get_registry()
    player = registry._players.get(player_id)
    if player:
        player.game_state['score'] = score
        player.game_state['level'] = level
        player.game_state['lines'] = lines


def get_player_gamemode(player_id: str) -> int:
    """Get the gamemode_selection for a player."""
    return _game_manager._player_metadata.get(player_id, {}).get("gamemode_selection", 0)
