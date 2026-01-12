# Score Counter Integration Guide

## Overview

A neat score counter widget has been added to the Tetris controller screen. It displays **SCORE**, **LEVEL**, and **LINES** in real-time. The Flutter app polls the server every 200ms to fetch the current game state.

## Components Created

### 1. Flutter Score Counter Widget
**File:** [led_matrix_controller/lib/widgets/score_counter.dart](../led_matrix_controller/lib/widgets/score_counter.dart)

A custom widget that displays the score in a stylish cyan-bordered container with three stats:
- **SCORE** (cyan text, large monospace font)
- **LEVEL** (amber text)
- **LINES** (lime text)

### 2. Game State Provider
**File:** [led_matrix_controller/lib/providers/game_state.dart](../led_matrix_controller/lib/providers/game_state.dart)

Uses `flutter_riverpod` to manage game state:
- `GameScore` class: holds score, level, and lines
- `GameScoreNotifier`: state notifier for updates
- `gameScoreProvider`: riverpod provider for reactive updates

### 3. Updated Tetris Controller Page
**File:** [led_matrix_controller/lib/pages/tetris_controller_page.dart](../led_matrix_controller/lib/pages/tetris_controller_page.dart)

- Imports the score counter widget and game state provider
- Adds a `_scoreUpdateTimer` that fetches game state every 200ms
- Displays the score counter at the top of the screen
- Watches `gameScoreProvider` to update UI reactively

### 4. API Endpoint
**File:** [TwinklyWall/api_server.py](../TwinklyWall/api_server.py)

New endpoint: **`GET /api/game/state`**
- Query parameters: `?game=tetris&player_id=<uuid>`
- Returns JSON with: `score`, `level`, `lines`
- Example response:
  ```json
  {
    "status": "ok",
    "player_id": "uuid-123",
    "game": "tetris",
    "score": 1250,
    "level": 2,
    "lines": 4
  }
  ```

## How to Update Score from Tetris

### Step 1: Import the helper function
In your `tetris.py` file, add this import:
```python
from game_players import set_player_score_data
```

### Step 2: Call the update function whenever score changes
In your Tetris game class, whenever you update the score, call:
```python
# Example: after clearing lines
def clear_lines(self, player_index):
    # ... your line clearing logic ...
    self.score = 1250
    self.level = 2
    self.lines = 4
    
    # Get the player_id for this player
    player = self.players[player_index]  # or however you access the player
    player_id = player.player_id
    
    # Update the score on the server
    set_player_score_data(player_id, self.score, self.level, self.lines)
```

### Step 3: Make sure each player has a player_id
The `Player` object (from the game_players system) should have a `player_id` attribute. When the Flutter app joins the game, the API returns the `player_id` - this is what you need to pass to `set_player_score_data()`.

## Example Integration in Tetris

```python
# At the top of tetris.py
from game_players import get_active_players_for_game, set_player_score_data

class Tetris:
    def __init__(self, canvas, HEADLESS, level):
        # ... existing init code ...
        self.score = 0
        self.level = 1
        self.lines_cleared = 0
        
    def on_line_clear(self, num_lines_cleared):
        """Called when lines are cleared"""
        # Calculate new score
        base_points = [0, 100, 300, 500, 800]  # points per 1-4 lines
        points = base_points[min(num_lines_cleared, 4)]
        self.score += points * self.level
        self.lines_cleared += num_lines_cleared
        
        # Update level based on lines
        self.level = 1 + (self.lines_cleared // 10)
        
        # Sync score to all active players
        players = get_active_players_for_game('tetris')
        for player in players:
            set_player_score_data(player.player_id, self.score, self.level, self.lines_cleared)
```

## Flow Diagram

```
Tetris Game (Python)
    ↓
    ├─ Updates self.score, self.level, self.lines_cleared
    ↓
    └─ Calls: set_player_score_data(player_id, score, level, lines)
         ↓
         └─ Stores in Player.game_state dict
              ↓
              └─ GET /api/game/state fetches it
                   ↓
                   └─ Flutter app polls every 200ms
                        ↓
                        └─ Updates gameScoreProvider
                             ↓
                             └─ ScoreCounter widget rebuilds
                                  ↓
                                  └─ Display updates in real-time!
```

## Score Display Appearance

The score counter appears at the **top center** of the Tetris controller screen with:
- Cyan border with glow effect
- Three columns: SCORE | LEVEL | LINES
- Dark background for contrast
- Proportionally-spaced monospace font for numbers

## Notes

- The Flutter app fetches score every **200ms** - this is fast enough for smooth updates
- If the Tetris backend is not calling `set_player_score_data()`, the UI will show **0** 
- The score counter is separate from the game grid and doesn't affect gameplay
- Multiple players can play simultaneously; each has their own score display on their phone

## Testing

To test the integration:
1. Launch Tetris from the Flutter app (it joins the game)
2. Manually call the score update in Python:
   ```python
   from game_players import get_active_players_for_game, set_player_score_data
   players = get_active_players_for_game('tetris')
   if players:
       set_player_score_data(players[0].player_id, 5000, 5, 50)
   ```
3. Check if the score counter on your phone updates within 200ms
