from __future__ import annotations

from enum import Enum, IntEnum
from .constants import ( TETROMINO_I_GRID_SHAPE, TETROMINO_J_GRID_SHAPE, TETROMINO_L_GRID_SHAPE, 
                        TETROMINO_O_GRID_SHAPE, TETROMINO_S_GRID_SHAPE, TETROMINO_Z_GRID_SHAPE,
                        TETROMINO_T_GRID_SHAPE, TETROMINO_I_GRID_SIZE, TETROMINO_J_GRID_SIZE, TETROMINO_L_GRID_SIZE,
                        TETROMINO_O_GRID_SIZE, TETROMINO_S_GRID_SIZE, TETROMINO_Z_GRID_SIZE, TETROMINO_T_GRID_SIZE,
                        TETROMINO_COLORS )

class Gamemode(Enum):
    CLASSIC = 0 # NES style. Locks after one drop interval. Uses simple random style.
    MODERN = 1 # Tetris Worlds Marathon style. More forgiving down-timer. Uses 7-Bag randomizer.

class TetrominoColors(Enum):
    pass # TODO : Fill this in and use it

class RandomStyle(Enum):
    SIMPLE = 0
    BAG = 1

class TetrominoType(IntEnum):
    I_PIECE = 1
    J_PIECE = 2
    L_PIECE = 3
    O_PIECE = 4
    S_PIECE = 5
    Z_PIECE = 6
    T_PIECE = 7

    @property
    def shape(self) -> TetrominoType:# TODO : Switch to list
        match self:
            case TetrominoType.I_PIECE:
                return TETROMINO_I_GRID_SHAPE
            case TetrominoType.J_PIECE:
                return TETROMINO_J_GRID_SHAPE
            case TetrominoType.L_PIECE:
                return TETROMINO_L_GRID_SHAPE
            case TetrominoType.O_PIECE:
                return TETROMINO_O_GRID_SHAPE
            case TetrominoType.S_PIECE:
                return TETROMINO_S_GRID_SHAPE
            case TetrominoType.Z_PIECE:
                return TETROMINO_Z_GRID_SHAPE
            case TetrominoType.T_PIECE:
                return TETROMINO_T_GRID_SHAPE
            case _:
                raise ValueError
                pass

    @property
    def size(self):  # TODO : Switch to list
        match self:
            case TetrominoType.I_PIECE:
                return TETROMINO_I_GRID_SIZE
            case TetrominoType.J_PIECE:
                return TETROMINO_J_GRID_SIZE
            case TetrominoType.L_PIECE:
                return TETROMINO_L_GRID_SIZE
            case TetrominoType.O_PIECE:
                return TETROMINO_O_GRID_SIZE
            case TetrominoType.S_PIECE:
                return TETROMINO_S_GRID_SIZE
            case TetrominoType.Z_PIECE:
                return TETROMINO_Z_GRID_SIZE
            case TetrominoType.T_PIECE:
                return TETROMINO_T_GRID_SIZE

    @property     
    def color(self): # TODO : Switch to list
        return TETROMINO_COLORS[self.value]