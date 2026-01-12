# 📋 Score Update - Copy-Paste Code

## For Your Tetris Game

### Step 1: Add imports at the top of `tetris.py`
```python
from game_players import set_player_score_data, get_active_players_for_game
```

### Step 2: Create a helper method in your Tetris class
```python
def update_scores_on_all_players(self):
    """Sync current score state to all connected players"""
    players = get_active_players_for_game('tetris')
    for player in players:
        set_player_score_data(
            player.player_id,
            self.score,
            self.level,
            self.lines_cleared  # or whatever your lines counter is called
        )
```

### Step 3: Call this method whenever score changes
For example, in your line-clearing logic:
```python
def clear_completed_lines(self):
    # ... your existing line-clearing logic ...
    lines_cleared = 0
    
    # (detect and remove completed lines)
    for row in self.completed_rows:
        self.dead_grid.pop(row)
        self.dead_grid.insert(0, [0] * self.blocks_width)
        lines_cleared += 1
    
    # Calculate points
    if lines_cleared > 0:
        self.lines_cleared += lines_cleared
        points = [0, 100, 300, 500, 800][min(lines_cleared, 4)]
        self.score += points * self.level
        self.level = 1 + (self.lines_cleared // 10)
        
        # ✅ Update all players
        self.update_scores_on_all_players()
```

### Step 4: Call update at game start/reset
```python
def reset_game(self):
    self.score = 0
    self.level = 1
    self.lines_cleared = 0
    # ... other reset logic ...
    self.update_scores_on_all_players()
```

---

## Complete Real-World Example

Here's how it might look in context with your existing Tetris code:

```python
# At the top of tetris.py
import sys
import os
import pygame
import numpy
import random
from .tetromino import Tetromino, Random_Bag
from logger import log
from game_players import get_active_players_for_game, set_player_score_data  # ← ADD THIS
from players import set_input_handler
import copy
import time

class Tetris:
    def __init__(self, canvas, HEADLESS, level):
        ### Settings ###
        self.headless = HEADLESS
        self.blocks_width = 10
        self.blocks_height = 25
        self.block_size = 3
        self.score = 0
        self.level = 1
        self.lines_cleared = 0
        # ... rest of init ...
        
    def update_scores_on_all_players(self):
        """Sync current score state to all connected players"""
        players = get_active_players_for_game('tetris')
        for player in players:
            set_player_score_data(
                player.player_id,
                self.score,
                self.level,
                self.lines_cleared
            )
    
    def update(self, delta_time):
        # ... your existing game loop ...
        
        # When you detect completed lines:
        completed = self.find_completed_lines()
        if completed:
            # Score calculation
            num_lines = len(completed)
            points = [0, 100, 300, 500, 800][min(num_lines, 4)]
            self.score += points * self.level
            self.lines_cleared += num_lines
            self.level = 1 + (self.lines_cleared // 10)
            
            # ✅ Send to Flutter
            self.update_scores_on_all_players()
            
            # Remove the lines
            for row in sorted(completed, reverse=True):
                self.dead_grid.pop(row)
                self.dead_grid.insert(0, [0] * self.blocks_width)
```

---

## Minimal 3-Line Integration

If you want the absolute bare minimum, just add this whenever score changes:

```python
from game_players import set_player_score_data, get_active_players_for_game

# When score updates:
for player in get_active_players_for_game('tetris'):
    set_player_score_data(player.player_id, self.score, self.level, self.lines_cleared)
```

---

## Data Flow Visualization

```
Your Tetris Class
    ↓ self.score = 1250
    ↓ self.level = 2  
    ↓ self.lines_cleared = 4
    ↓
    └─→ update_scores_on_all_players()
         ↓
         └─→ set_player_score_data(player_id, 1250, 2, 4)
              ↓
              └─→ Player.game_state = {'score': 1250, 'level': 2, 'lines': 4}
                   ↓
                   └─→ Flutter polls GET /api/game/state every 200ms
                        ↓
                        └─→ gameScoreProvider updates
                             ↓
                             └─→ ScoreCounter widget refreshes
                                  ↓
                                  └─→ 📊 Display: SCORE: 1250 | LEVEL: 2 | LINES: 4
```

---

## Variables Reference

| Variable | Type | Example | Purpose |
|----------|------|---------|---------|
| `self.score` | `int` | `1250` | Total points earned |
| `self.level` | `int` | `2` | Current difficulty level |
| `self.lines_cleared` | `int` | `4` | Total lines cleared in game |
| `player.player_id` | `str` | `"550e8400-..."` | Unique ID of connected player |

---

## That's It! 🎉

Once you add these lines to your tetris.py, the score will automatically appear on the Flutter app screen and update in real-time!
