
from enum import IntEnum

class Gamemode(IntEnum):
    CLASSIC = 0 # NES style. Locks after one drop interval. Uses simple random style.
    MODERN = 1 # Tetris Worlds Marathon style. More forgiving down-timer. Uses 7-Bag randomizer.

class TetrominoColors(IntEnum):
    pass # TODO : Fill this in and use it

class TetrominoType(IntEnum):
    pass
    # I_PIECE = 0
    # I_PIECE = 2