# All code in this file must be handwritten! No AI allowed!

import numpy
import random

class Tetromino:
    #### [piece_group(0: I piece, 1: JLSZT )] [direction(0: clockwise, 1: counterclockwise)] [Desired rotation] [Try number]
    kick_offsets = [
        ### Piece_group 0: I piece
        [
        # Counter-clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-1,0),
                    (2,0),
                    (-1,2),
                    (2,-1),
                ],
                [
                    (2,0),
                    (-1,0),
                    (2,1),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (-2,0),
                    (1,-2),
                    (-2,1),
                ],
                [
                    (-2,0),
                    (1,0),
                    (-2,-1),
                    (1,2),
                ],
            ],
            # Clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-2,0),
                    (1,0),
                    (-2,-1),
                    (1,2),
                ],
                [
                    (-1,0),
                    (2,0),
                    (-1,2),
                    (2,-1),
                ],
                [
                    (2,0),
                    (-1,0),
                    (2,1),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (-2,0),
                    (1,-2),
                    (-2,1),
                ],
            ],
        ],
        ### Piece_group 1
        [
            
        # Counter-clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (1,0),
                    (1,1),
                    (0,-2),
                    (1,-2),
                ],
                [
                    (1,0),
                    (1,-1),
                    (0,2),
                    (1,2),
                ],
                [
                    (-1,0),
                    (-1,1),
                    (0,-2),
                    (-1,-2),
                ],
                [
                    (-1,0),
                    (-1,-1),
                    (0,2),
                    (-1,2),
                ],
            ],
            # Clockwise
            [
                # Desired rotation
                [
                    #Try number
                    (-1,0),
                    (-1,1),
                    (0,-2),
                    (-1,-2),
                ],
                [
                    (1,0),
                    (1,-1),
                    (0,2),
                    (1,2),
                ],
                [
                    (1,0),
                    (1,1),
                    (0,-2),
                    (1,-2),
                ],
                [
                    (-1,0),
                    (-1,-1),
                    (0,2),
                    (-1,2),
                ],
            ],
        ],
    ]
    shapes = [ [], # Empty piece (0)
                # I piece (1)
                [[0,0,0,0],
                [0,0,0,0],
                [1,1,1,1],
                [0,0,0,0]],
                # J piece (2)
                [[2,0,0],
                 [2,2,2],
                 [0,0,0]],
                # L piece (3)
                [[0,0,3],
                 [3,3,3],
                 [0,0,0]],
                # O piece (4)
                [[0,0,0,0],
                 [0,4,4,0],
                 [0,4,4,0],
                 [0,0,0,0]],
                # S piece (5)
                [[0,5,5],
                 [5,5,0],
                 [0,0,0],],
                # Z piece (6)
                [[6,6,0],
                 [0,6,6],
                 [0,0,0],],
                # T piece (7)
                [[0,7,0],
                 [7,7,7],
                 [0,0,0]], ]
    def __init__(self, type_index : int, grid_position = (0,0), rotation = 0):
        self.grid_position = grid_position
        self.precise_height = 0.0 # Won't fall on the grid, but we snap to grid.
        self.ghost_opacity = 0.2
        self.type_index = type_index
        self.shape = self.shapes[type_index]
        self.rotation = 0 # Multiply by 90 for degrees

from enum import IntEnum
class RandomBag:
    bag_size = 7
    class RandomStyle(IntEnum):
        SIMPLE = 0
        BAG = 1
    
    def __init__(self, random_style_index):
        self.random_style = self.RandomStyle(random_style_index)
        self.contents = []
        self.distribution = {1:0, 2:0, 3:0, 4:0, 5:0, 6:0, 7:0} # For debugging
        self.next_piece = None
        self.current_piece = None
    
    def pull_piece(self) -> int:
        if self.random_style == 0:
            new_piece = self.simple_random()
            self.distribution[new_piece] += 1
            # print(self.distribution)
            return new_piece
        elif self.random_style != 1: # Safegaurd
            return 0

        if len(self.contents) <= 0:
            self.refill_bag()

        new_piece = self.next_piece
        self.next_piece = self.contents.pop()
        
        self.distribution[new_piece] += 1
        return new_piece

    def simple_random(self) -> int:
        rand = (1, len(Tetromino.shapes))
        if self.next_piece == None: # Only happens the first time
            self.next_piece = random.randrange(rand[0], rand[1])

        num = random.randrange(rand[0], rand[1])
        if num == self.next_piece: # Reroll once
            # print(f"num {num} == next: {self.next_piece}. Rerolling to ", end="")
            num = random.randrange(rand[0], rand[1])
            # print(num)


        self.current_piece = self.next_piece
        self.next_piece = num
        return self.current_piece
            
    def refill_bag(self):
        new_bag = [i for i in range(1,self.bag_size + 1)]
        random.shuffle(new_bag)
        self.contents = new_bag
        if self.next_piece == None: # Should happen only on the first bag fill 
            self.next_piece = self.contents.pop()