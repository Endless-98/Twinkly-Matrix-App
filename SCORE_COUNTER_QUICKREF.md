# 🎮 Score Counter Quick Reference

## One-Line Summary
The Flutter app now displays a **real-time score counter** at the top of the Tetris screen. Data flows from Python → API → Flutter (every 200ms).

---

## 📍 Files Modified/Created

| File | Purpose |
|------|---------|
| [led_matrix_controller/lib/widgets/score_counter.dart](../led_matrix_controller/lib/widgets/score_counter.dart) | ✨ New score display widget |
| [led_matrix_controller/lib/providers/game_state.dart](../led_matrix_controller/lib/providers/game_state.dart) | ✨ New state management provider |
| [led_matrix_controller/lib/pages/tetris_controller_page.dart](../led_matrix_controller/lib/pages/tetris_controller_page.dart) | 📝 Updated to show score counter + fetch data |
| [TwinklyWall/api_server.py](../TwinklyWall/api_server.py) | 📝 Added `/api/game/state` endpoint |
| [TwinklyWall/game_players.py](../TwinklyWall/game_players.py) | 📝 Added `get_player_data()` and `set_player_score_data()` |
| [TwinklyWall/players.py](../TwinklyWall/players.py) | 📝 Added `game_state` field to `Player` class |

---

## 🔌 How to Call Score Updates in Tetris

### Import
```python
from game_players import set_player_score_data, get_active_players_for_game
```

### Call whenever score changes
```python
# Inside your Tetris game logic (e.g., after clearing lines):
players = get_active_players_for_game('tetris')
for player in players:
    set_player_score_data(
        player.player_id,
        score=1250,      # Your current score
        level=2,         # Your current level
        lines=4          # Lines cleared
    )
```

### Or per-player (if tracking individual scores):
```python
set_player_score_data(player_id, self.score, self.level, self.lines_cleared)
```

---

## 📊 API Endpoint

**GET** `/api/game/state?game=tetris&player_id=<uuid>`

**Response:**
```json
{
  "status": "ok",
  "player_id": "550e8400-e29b-41d4-a716-446655440000",
  "game": "tetris",
  "score": 1250,
  "level": 2,
  "lines": 4
}
```

---

## 🎨 Display Location & Style

- **Position:** Top center of Tetris controller screen
- **Style:** Cyan border with glow effect, dark background
- **Updates:** Every 200ms automatically
- **Shows:** SCORE (cyan) | LEVEL (amber) | LINES (lime)

---

## ⚡ Quick Integration Example

```python
class Tetris:
    def __init__(self, ...):
        self.score = 0
        self.level = 1
        self.lines_cleared = 0
        
    def clear_lines(self, num_lines):
        points = [0, 100, 300, 500, 800][min(num_lines, 4)]
        self.score += points * self.level
        self.lines_cleared += num_lines
        self.level = 1 + (self.lines_cleared // 10)
        
        # ✅ Update all players' scores
        from game_players import get_active_players_for_game, set_player_score_data
        players = get_active_players_for_game('tetris')
        for player in players:
            set_player_score_data(
                player.player_id, 
                self.score, 
                self.level, 
                self.lines_cleared
            )
```

---

## 🧪 Testing

```python
# From Python console or test script
from game_players import get_active_players_for_game, set_player_score_data

players = get_active_players_for_game('tetris')
if players:
    player = players[0]
    set_player_score_data(player.player_id, 9999, 10, 100)
    # Check Flutter app - should update in ~200ms!
```

---

## ❓ FAQs

**Q: How often does the Flutter app fetch score?**
A: Every 200ms (5 times per second) - smooth enough for real-time display.

**Q: Can multiple players have different scores?**
A: Yes! Each player's score is stored independently on their `Player.game_state` dict.

**Q: What if I don't call `set_player_score_data()`?**
A: The score will display as 0 (or whatever was last set).

**Q: Does the score counter affect gameplay?**
A: No, it's purely a display widget - it doesn't interfere with game logic.

**Q: Can I customize the colors/style?**
A: Yes! Edit [score_counter.dart](../led_matrix_controller/lib/widgets/score_counter.dart) - look for the color definitions in the `ScoreCounter` and `_ScoreStat` classes.
