# All code in this file must be handwritten! No AI allowed!
import random
from .enums import TetrominoType, RandomStyle
import copy

class Tetromino:
    def __init__(self, type : TetrominoType, grid_position = (0,0), rotation = 0):
        self.grid_position = grid_position
        self.rotation = 0 # TODO : Make this an enum 0: Up 1: Down
        self.type = TetrominoType(type)
        self.shape_instance = copy.copy(type.shape)


class RandomBag:
    def __init__(self, random_style):
        self.random_style = random_style
        self.contents = []
        self.next_piece = None
        self.current_piece = None
    
    def pull_piece(self) -> TetrominoType | None:
        match self.random_style:
            case RandomStyle.SIMPLE:
                new_piece = self.simple_random()
                return new_piece
            case RandomStyle.BAG:
                if len(self.contents) <= 0:
                    self.refill_bag()

                new_piece = self.next_piece
                self.next_piece = self.contents.pop()
                
                return new_piece

        return None # TODO : Add error checking

    def simple_random(self) -> TetrominoType:
        if self.next_piece is None: # Only happens the first time
            self.next_piece = random.choice(list(TetrominoType))

        new_piece = random.choice(list(TetrominoType))
        if new_piece == self.next_piece: # Reroll once
            new_piece = random.choice(list(TetrominoType))

        self.current_piece = self.next_piece
        self.next_piece = new_piece
        return self.current_piece
            
    def refill_bag(self):
        new_bag = list(TetrominoType)
        random.shuffle(new_bag)
        self.contents = new_bag
        
        if self.next_piece is None: # Should happen only on the first bag fill 
            self.next_piece = self.contents.pop()